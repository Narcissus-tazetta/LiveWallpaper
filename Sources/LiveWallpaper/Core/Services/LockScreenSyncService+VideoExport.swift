@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import VideoToolbox

/// ロック画面用動画の変換と、変換後アセットの妥当性検証。
///
/// The lock screen's Aerial player slows the video down when the screen unlocks and
/// reads HEVC temporal layer information (temporal level and sub-layer access) of
/// each sample to do it. Without that information the read fails, and the player
/// stays on its last frame for every later lock. Apple's Aerials are 240 fps HEVC
/// with temporal layers, so every video is re-encoded that way: a plain remux or an
/// AVAssetExportSession export carries no temporal layers.
struct AerialVideoExporter {
    static let frameRate: Int32 = 240
    /// The frame rate of the lowest temporal layer; the encoder layers the rest above it.
    static let baseLayerFrameRate = 15

    /// Whether this Mac's HEVC encoder can make temporal layers. The software encoder
    /// (Macs without HEVC hardware, and x86_64 under Rosetta) cannot; videos are then
    /// encoded without them rather than failing, and the lock screen may stop after
    /// an unlock.
    static let supportsTemporalLayers: Bool = {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: 1920, height: 1080, codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            return false
        }
        defer { VTCompressionSessionInvalidate(session) }
        let result = VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_BaseLayerFrameRate, value: baseLayerFrameRate as CFNumber
        )
        if result != noErr {
            AppLog.lockScreenSync.info("HEVC encoder has no temporal layers: \(result, privacy: .public)")
        }
        return result == noErr
    }()

    private static let encodeQueue = DispatchQueue(
        label: "com.sakana.livewallpaper.aerial-encode",
        qos: .utility
    )

    /// Bump when the encoding changes, so videos encoded the old way are made again.
    private static let encodingVersion = 2

    private let fileManager: FileManager
    /// false only in tests, whose placeholder files are not videos: they are copied as is.
    private let encodesVideo: Bool
    /// Keeps the last encoded video: a long 4K video takes over an hour to encode, and
    /// every launch without "keep after quit" syncs again. nil keeps nothing.
    private let cacheDirectory: URL?

    init(fileManager: FileManager, encodesVideo: Bool, cacheDirectory: URL?) {
        self.fileManager = fileManager
        self.encodesVideo = encodesVideo
        self.cacheDirectory = cacheDirectory
    }

    /// `start` is the source time the video begins at; nil picks it automatically.
    /// `progress` gets the encoded fraction, 0...1, from a background thread.
    func prepareVideo(
        from sourceURL: URL,
        to destinationURL: URL,
        start: Double? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        guard encodesVideo else {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return
        }
        let cachedURL = try cacheDirectory.map { directory in
            try directory.appendingPathComponent(cacheKey(for: sourceURL, start: start))
                .appendingPathExtension("mov")
        }
        if let cachedURL, fileManager.fileExists(atPath: cachedURL.path) {
            do {
                try await validatePreparedVideo(at: cachedURL)
                // A clone on APFS, so even a large video is ready at once.
                try fileManager.copyItem(at: cachedURL, to: destinationURL)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.lockScreenSync.error(
                    "cached lock screen video unusable, encoding again: \(error.localizedDescription, privacy: .public)"
                )
                try? fileManager.removeItem(at: cachedURL)
            }
        }
        let encodedURL = cachedURL.map {
            $0.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mov")
        } ?? destinationURL
        do {
            if let cacheDirectory {
                try fileManager.createDirectory(
                    at: cacheDirectory,
                    withIntermediateDirectories: true
                )
            }
            try await encode(AVURLAsset(url: sourceURL), to: encodedURL, start: start, progress: progress)
            try await validatePreparedVideo(at: encodedURL)
            if let cachedURL {
                try keepOnly(encodedURL, as: cachedURL)
                try fileManager.copyItem(at: cachedURL, to: destinationURL)
            }
        } catch {
            for url in [encodedURL, destinationURL] where fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
            throw error
        }
    }

    private func cacheKey(for sourceURL: URL, start: Double?) throws -> String {
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let startKey = start.map { String($0) } ?? "auto"
        let identity = "\(sourceURL.standardizedFileURL.path)|\(size)|\(modified)|\(Self.encodingVersion)|\(startKey)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Moves the new video into the cache under its key and removes the older ones.
    private func keepOnly(_ encodedURL: URL, as cachedURL: URL) throws {
        let directory = cachedURL.deletingLastPathComponent()
        for name in try fileManager.contentsOfDirectory(atPath: directory.path)
            where name.hasSuffix(".mov") && !name.hasPrefix(".") && name != cachedURL
            .lastPathComponent
        {
            try fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        try fileManager.moveItem(at: encodedURL, to: cachedURL)
    }

    // MARK: - Encoding

    private func encode(
        _ asset: AVURLAsset,
        to destinationURL: URL,
        start requestedStart: Double?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let track: AVAssetTrack
        let duration: CMTime
        let isHDR: Bool
        let formatDescription: CMFormatDescription?
        let dataRate: Float
        let size: CGSize
        do {
            guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw LockScreenSyncError.invalidVideo(NSLocalizedString(
                    "ロック画面用の動画に映像トラックがありません。",
                    comment: ""
                ))
            }
            track = videoTrack
            duration = try await asset.load(.duration)
            isHDR = try await HDRVideo.containsHDR(asset)
            formatDescription = try await track.load(.formatDescriptions).first
            dataRate = try await track.load(.estimatedDataRate)
            size = try await track.load(.naturalSize)
        } catch let error as LockScreenSyncError {
            throw error
        } catch {
            throw Self.unreadable(error)
        }
        guard duration.seconds.isFinite, duration.seconds >= 1.0 else {
            throw LockScreenSyncError.invalidVideo(NSLocalizedString(
                "ロック画面用の動画が短すぎるか、長さを読み取れませんでした。",
                comment: ""
            ))
        }

        let pixelFormat = isHDR
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        func makeSource(_ range: CMTimeRange) throws -> FrameSource {
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = range
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
            ])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            return FrameSource(reader: reader, output: output, range: range)
        }
        // Without the app, the desktop shows the lock screen video's still frame where
        // it last stopped, and the first frame after a login or a WallpaperAgent restart.
        // A video that fades in from black would leave a black desktop, so the video
        // starts at its first visible frame (or the one the user picked) and the part
        // before it plays at the end. The loop stays seamless: the end runs straight
        // into the opening.
        let start = try requestedStart.map {
            // A start at the very end would leave nothing for the first part.
            CMTimeMinimum(
                CMTime(seconds: max($0, 0), preferredTimescale: 600),
                duration - CMTime(value: 1, timescale: 10)
            )
        } ?? Self.firstVisibleFrameTime(
            in: makeSource(CMTimeRange(
                start: .zero,
                end: CMTimeMinimum(
                    CMTimeMultiplyByRatio(duration, multiplier: 1, divisor: 2),
                    CMTime(value: 10, timescale: 1)
                )
            ))
        )
        AppLog.lockScreenSync.info(
            "lock screen video starts at \(start.seconds, format: .fixed(precision: 3), privacy: .public)s"
        )
        let sources = try (start <= .zero
            ? [CMTimeRange(start: .zero, end: duration)]
            : [CMTimeRange(start: start, end: duration), CMTimeRange(start: .zero, end: start)])
            .map(makeSource)
        let encoder = try LayeredHEVCEncoder(
            width: Int32(size.width.rounded()), height: Int32(size.height.rounded()),
            isHDR: isHDR, sourceFormat: formatDescription,
            // Repeated frames cost little, so the source's rate is enough; the floor
            // keeps a heavily compressed source from losing more detail.
            bitRate: Int(min(max(dataRate, 8_000_000), 80_000_000))
        )
        defer { encoder.invalidate() }
        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mov)
        let job = EncodeJob(
            sources: sources, encoder: encoder, writer: writer, duration: duration,
            progress: progress
        )

        // Minutes of blocking reads and appends: a queue of its own keeps them off
        // Swift's cooperative threads.
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
                    Void,
                    Error
                >) in
                    Self.encodeQueue.async {
                        continuation.resume(with: Result { try job.run() })
                    }
                }
            } onCancel: {
                job.cancel()
            }
        } catch {
            if writer.status == .writing {
                writer.cancelWriting()
            }
            throw error
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw LockScreenSyncError.exportFailed(
                writer.error?.localizedDescription ?? NSLocalizedString(
                    "動画の mov 変換が完了しませんでした。",
                    comment: ""
                )
            )
        }
    }

    fileprivate static func unreadable(_ error: Error?) -> LockScreenSyncError {
        .invalidVideo(String(
            format: NSLocalizedString("ロック画面用の動画を読み込めませんでした: %@", comment: ""),
            error?.localizedDescription ?? ""
        ))
    }

    /// Zero when the first frame is not close to black. Otherwise the first frame at
    /// half the brightest frame's level, which skips a fade-in rather than starting
    /// on its dim middle; zero when every frame is close to black.
    private static func firstVisibleFrameTime(in source: FrameSource) throws -> CMTime {
        let visible = 0.05
        guard source.reader.startReading() else {
            throw unreadable(source.reader.error)
        }
        defer { source.reader.cancelReading() }
        var frames: [(time: CMTime, luma: Double)] = []
        while let frame = source.nextFrame() {
            let luma = meanLuma(of: frame.buffer)
            if frames.isEmpty, luma >= visible {
                return .zero
            }
            frames.append((frame.time, luma))
        }
        if source.reader.status == .failed {
            throw unreadable(source.reader.error)
        }
        let brightest = frames.map(\.luma).max() ?? 0
        let threshold = max(visible, brightest / 2)
        return frames.first { $0.luma >= threshold }?.time ?? .zero
    }

    /// The mean of a sparse grid of the luma plane, 0 for video black and 1 for white.
    private static func meanLuma(of buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
            return 0
        }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let isTenBit = CVPixelBufferGetPixelFormatType(buffer)
            == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        // Video range: black is 16 and white 235 in 8 bits; 10 bits sit in the high
        // bits of 16-bit samples.
        let (black, white): (Double, Double) = isTenBit ? (64 * 64, 940 * 64) : (16, 235)
        var sum = 0.0
        var count = 0
        for y in stride(from: 0, to: height, by: 8) {
            let row = base + y * bytesPerRow
            for x in stride(from: 0, to: width, by: 8) {
                sum += isTenBit
                    ? Double(row.load(fromByteOffset: x * 2, as: UInt16.self))
                    : Double(row.load(fromByteOffset: x, as: UInt8.self))
                count += 1
            }
        }
        guard count > 0 else {
            return 0
        }
        return (sum / Double(count) - black) / (white - black)
    }

    // MARK: - Validation

    private func validatePreparedVideo(at url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        let isPlayable: Bool
        let videoTracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            isPlayable = try await asset.load(.isPlayable)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw Self.unreadable(error)
        }

        guard isPlayable else {
            throw LockScreenSyncError.invalidVideo(NSLocalizedString(
                "ロック画面用の動画を再生可能として読み込めませんでした。",
                comment: ""
            ))
        }
        guard duration.seconds.isFinite, duration.seconds >= 1.0 else {
            throw LockScreenSyncError.invalidVideo(NSLocalizedString(
                "ロック画面用の動画が短すぎるか、長さを読み取れませんでした。",
                comment: ""
            ))
        }
        guard let track = videoTracks.first else {
            throw LockScreenSyncError.invalidVideo(NSLocalizedString(
                "ロック画面用の動画に映像トラックがありません。",
                comment: ""
            ))
        }
        // An encoder that supports layers can still leave them out silently, and the
        // lock screen then freezes after the first unlock: fail here instead.
        guard try !Self.supportsTemporalLayers || Self.hasTemporalLayers(asset: asset, track: track) else {
            throw LockScreenSyncError.exportFailed(
                NSLocalizedString("ロック画面用の動画に時間階層の情報を付けられませんでした。", comment: "")
            )
        }
    }

    /// Whether the first second of samples carries HEVC temporal layer information.
    static func hasTemporalLayers(asset: AVAsset, track: AVAssetTrack) throws -> Bool {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else {
            return false
        }
        defer { reader.cancelReading() }
        var checked = 0
        while checked < Int(frameRate), let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else {
                continue
            }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample,
                createIfNecessary: false
            ) as? [[CFString: Any]]
            guard attachments?.first?[kCMSampleAttachmentKey_HEVCTemporalLevelInfo] != nil else {
                return false
            }
            checked += 1
        }
        return checked > 0
    }
}

/// Decoded frames of one stretch of the source.
private struct FrameSource {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let range: CMTimeRange

    func nextFrame() -> (buffer: CVPixelBuffer, time: CMTime)? {
        while let sample = output.copyNextSampleBuffer() {
            if let buffer = CMSampleBufferGetImageBuffer(sample) {
                return (buffer, CMSampleBufferGetPresentationTimeStamp(sample))
            }
        }
        return nil
    }
}

/// Reads the sources one after another and encodes them at 240 fps on one thread;
/// `cancel` may come from any.
private final class EncodeJob: @unchecked Sendable {
    private let sources: [FrameSource]
    private let encoder: LayeredHEVCEncoder
    private let writer: AVAssetWriter
    private let duration: CMTime
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var isCancelled = false

    init(
        sources: [FrameSource],
        encoder: LayeredHEVCEncoder,
        writer: AVAssetWriter,
        duration: CMTime,
        progress: @escaping @Sendable (Double) -> Void
    ) {
        self.sources = sources
        self.encoder = encoder
        self.writer = writer
        self.duration = duration
        self.progress = progress
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    func run() throws {
        let rate = AerialVideoExporter.frameRate
        let tick = CMTime(value: 1, timescale: rate)
        // Each 1/240 s tick shows the latest source frame, whatever the source's rate.
        let total = max(Double(duration.seconds) * Double(rate), 1)
        var index: Int64 = 0
        var offset = CMTime.zero
        for source in sources {
            guard source.reader.startReading() else {
                throw AerialVideoExporter.unreadable(source.reader.error)
            }
            defer { source.reader.cancelReading() }
            let end = offset + source.range.duration
            // The reader may hand over the frame that is showing at the range's start,
            // which begins before it.
            func outputTime(_ time: CMTime) -> CMTime {
                CMTimeMinimum(CMTimeMaximum(time, source.range.start) - source.range.start + offset, end)
            }
            var current: CVPixelBuffer?
            while true {
                try checkCancellation()
                let next = source.nextFrame()
                let until = next.map { outputTime($0.time) } ?? end
                if let current {
                    while CMTime(value: index, timescale: rate) < until {
                        try encoder.encode(
                            current,
                            at: CMTime(value: index, timescale: rate),
                            duration: tick
                        )
                        try encoder.drain(into: writer)
                        index += 1
                        if index % 24 == 0 {
                            progress(min(Double(index) / total, 1))
                        }
                    }
                }
                guard let next else {
                    break
                }
                current = next.buffer
            }
            if source.reader.status == .failed {
                throw AerialVideoExporter.unreadable(source.reader.error)
            }
            offset = end
        }
        try encoder.finish(into: writer)
    }

    private func checkCancellation() throws {
        lock.lock()
        defer { lock.unlock() }
        if isCancelled {
            throw CancellationError()
        }
    }
}

/// HEVC with temporal layers, which AVAssetWriter's compression settings cannot ask
/// for (it rejects the base layer properties for hvc1).
private final class LayeredHEVCEncoder: @unchecked Sendable {
    private let session: VTCompressionSession
    private let lock = NSLock()
    private var pending: [CMSampleBuffer] = []
    private var failure: OSStatus = noErr
    private var input: AVAssetWriterInput?

    init(
        width: Int32,
        height: Int32,
        isHDR: Bool,
        sourceFormat: CMFormatDescription?,
        bitRate: Int
    ) throws {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            throw LockScreenSyncError.exportFailed(Self.message(status))
        }
        session = created
        var properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: false,
            kVTCompressionPropertyKey_ExpectedFrameRate: AerialVideoExporter.frameRate,
            kVTCompressionPropertyKey_AverageBitRate: bitRate,
            kVTCompressionPropertyKey_ProfileLevel: isHDR
                ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
        ]
        if AerialVideoExporter.supportsTemporalLayers {
            properties[kVTCompressionPropertyKey_BaseLayerFrameRate] = AerialVideoExporter.baseLayerFrameRate
        }
        // The colour description, and for HDR its mastering data, comes from the source.
        let extensions = sourceFormat
            .flatMap { CMFormatDescriptionGetExtensions($0) as? [CFString: Any] } ?? [:]
        let colourKeys: [(CFString, CFString)] = [
            (
                kCMFormatDescriptionExtension_ColorPrimaries,
                kVTCompressionPropertyKey_ColorPrimaries
            ),
            (
                kCMFormatDescriptionExtension_TransferFunction,
                kVTCompressionPropertyKey_TransferFunction
            ),
            (kCMFormatDescriptionExtension_YCbCrMatrix, kVTCompressionPropertyKey_YCbCrMatrix),
            (
                kCMFormatDescriptionExtension_MasteringDisplayColorVolume,
                kVTCompressionPropertyKey_MasteringDisplayColorVolume
            ),
            (
                kCMFormatDescriptionExtension_ContentLightLevelInfo,
                kVTCompressionPropertyKey_ContentLightLevelInfo
            )
        ]
        for (source, destination) in colourKeys {
            if let value = extensions[source] {
                properties[destination] = value
            }
        }
        for (key, value) in properties {
            let result = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            guard result == noErr else {
                VTCompressionSessionInvalidate(session)
                throw LockScreenSyncError.exportFailed("\(key): \(Self.message(result))")
            }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(_ buffer: CVPixelBuffer, at time: CMTime, duration: CMTime) throws {
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: time, duration: duration,
            frameProperties: nil, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard let self else {
                return
            }
            lock.lock()
            if status != noErr {
                failure = status
            } else if let sample {
                pending.append(sample)
            }
            lock.unlock()
        }
        guard status == noErr else {
            throw LockScreenSyncError.exportFailed(Self.message(status))
        }
    }

    /// Writes the frames encoded so far. The writer starts with the first one, whose
    /// format description the writer input needs.
    func drain(into writer: AVAssetWriter) throws {
        lock.lock()
        let samples = pending
        pending.removeAll()
        let failure = failure
        lock.unlock()
        guard failure == noErr else {
            throw LockScreenSyncError.exportFailed(Self.message(failure))
        }
        for sample in samples {
            let input = try writerInput(for: sample, writer: writer)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else {
                    throw LockScreenSyncError.exportFailed(writer.error?.localizedDescription ?? "")
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
            guard input.append(sample) else {
                throw LockScreenSyncError.exportFailed(writer.error?.localizedDescription ?? "")
            }
        }
    }

    func finish(into writer: AVAssetWriter) throws {
        let status = VTCompressionSessionCompleteFrames(
            session,
            untilPresentationTimeStamp: .invalid
        )
        guard status == noErr else {
            throw LockScreenSyncError.exportFailed(Self.message(status))
        }
        try drain(into: writer)
        guard let input else {
            throw LockScreenSyncError.exportFailed(NSLocalizedString(
                "動画の mov 変換が完了しませんでした。",
                comment: ""
            ))
        }
        input.markAsFinished()
    }

    func invalidate() {
        VTCompressionSessionInvalidate(session)
    }

    private func writerInput(
        for sample: CMSampleBuffer,
        writer: AVAssetWriter
    ) throws -> AVAssetWriterInput {
        if let input {
            return input
        }
        let input = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil,
            sourceFormatHint: CMSampleBufferGetFormatDescription(sample)
        )
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard writer.startWriting() else {
            throw LockScreenSyncError.exportFailed(writer.error?.localizedDescription ?? "")
        }
        writer.startSession(atSourceTime: .zero)
        self.input = input
        return input
    }

    private static func message(_ status: OSStatus) -> String {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status)).localizedDescription
    }
}

@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import Metal
import VideoToolbox

/// Renders one loop of an animated scene into a video. Every effect repeats a whole
/// number of times per loop, so frame N (= frame 0) is left out and the video loops
/// without a seam.
enum SceneVideoBaker {
    enum BakeError: LocalizedError {
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case let .writerFailed(message):
                return message
            }
        }
    }

    /// A 60 s loop at 4K bakes in about a minute and ~100 MB (measured on M5).
    static let framesPerSecond = 60

    /// Reduced framerate for scenes with gentle motion (clouds, slow sway).
    static let reducedFramesPerSecond = 30

    /// A 30 fps video shows every odd 60 Hz tick as a repeat of the even frame before
    /// it, so the visible error is "odd frame vs previous even frame" (hold), not an
    /// interpolation. Measured on raw frames: scenes judged gentle reach avg >=50 dB and
    /// <=0.5% changed pixels; the next scene up measured avg 41.5 dB / 0.8%, particle
    /// and multi-layer scenes avg <=40 dB / >=2.1%. All three must pass.
    static let holdPSNRAverageThreshold: Double = 45.0
    static let holdPSNRMinimumThreshold: Double = 42.0
    /// Small fast elements barely move the average PSNR, so the share of visibly
    /// changed pixels (any channel differs by more than `changedPixelDelta`) is capped too.
    static let changedPixelDelta = 8
    static let changedFractionMaximum: Double = 0.006

    /// Longest edge of the baked video; the lock screen does not need more.
    static let maxEdge = 3840

    struct Statistics {
        let holdStats: HoldStats
        let reducedDisqualifiedAtFrame: Int?
    }

    /// The links see `timeOfDay` (by default the part of the day now) and the cursor
    /// at the centre, as on the lock screen.
    @discardableResult
    static func bake(
        document: SceneDocument,
        videoPath: String,
        timeOfDay: SceneTimeOfDay? = nil,
        userProperties: [String: WebPropertyValue]? = nil,
        stillOnly: Bool = false,
        quality: Double = BakeQuality.high.compressionQuality,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Statistics? {
        let timeOfDay = timeOfDay ?? document.timeOfDay(at: Date())
        let task = Task.detached(priority: .utility) { () async throws -> Statistics? in
            try Task.checkCancellation()
            if document.isAnimated, !stillOnly {
                return try await render(
                    document: document, videoPath: videoPath, timeOfDay: timeOfDay,
                    userProperties: userProperties, quality: quality, outputURL: outputURL,
                    progress: progress
                )
            } else {
                try await renderStill(
                    document: document,
                    videoPath: videoPath,
                    timeOfDay: timeOfDay,
                    userProperties: userProperties,
                    outputURL: outputURL
                )
                return nil
            }
        }
        return try await withTaskCancellationHandler {
            do {
                let statistics = try await task.value
                try Task.checkCancellation()
                return statistics
            } catch {
                // The still-image transcoder uses its own cancellation error.
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            task.cancel()
        }
    }

    private static func renderStill(
        document: SceneDocument, videoPath: String, timeOfDay: SceneTimeOfDay,
        userProperties: [String: WebPropertyValue]?, outputURL: URL
    ) async throws {
        let renderer = try SceneRenderer(document: document, videoPath: videoPath)
        renderer.timeOfDay = timeOfDay
        let image = try renderer.renderStill(input: SceneFrameInput(userProperties: userProperties))
        let temporaryBase = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".scene-\(UUID().uuidString)")
        let stillURL = temporaryBase.appendingPathExtension("png")
        let videoURL = temporaryBase.appendingPathExtension("mp4")
        defer {
            removeIfPresent(stillURL)
            removeIfPresent(videoURL)
        }
        guard let destination = CGImageDestinationCreateWithURL(
            stillURL as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw SceneStore.StoreError.unreadableImage(stillURL.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SceneStore.StoreError.unreadableImage(stillURL.lastPathComponent)
        }
        try Task.checkCancellation()
        try await AnimatedImageTranscoder.transcode(imageURL: stillURL, to: videoURL)
        try Task.checkCancellation()
        try installVideo(videoURL, at: outputURL)
    }

    private static func render(
        document: SceneDocument,
        videoPath: String,
        timeOfDay: SceneTimeOfDay,
        userProperties: [String: WebPropertyValue]?,
        quality: Double,
        outputURL: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> Statistics {
        let frameCount = max(document.loopSeconds, 1) * framesPerSecond
        let tmpURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp.mp4")
        let tmp30URL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(outputURL.lastPathComponent).\(UUID().uuidString).30fps.tmp.mp4"
            )
        defer {
            removeIfPresent(tmpURL)
            removeIfPresent(tmp30URL)
        }
        // The encoder, not the rendering, sets the pace (measured on M5: 3.3 ms of a
        // 20.8 ms frame when both rates were encoded at once). Most scenes pass at 30 fps,
        // so that video is encoded first, alone; every frame is still rendered to judge
        // it. A scene that needs 60 fps fails on its first fast motion and is rendered
        // again, from the start, into a 60 fps video.
        let reducedPass = try await encodePass(
            document: document, videoPath: videoPath, timeOfDay: timeOfDay,
            userProperties: userProperties, quality: quality, url: tmp30URL,
            fps: reducedFramesPerSecond
        ) { progress($0) }
        let stats = reducedPass.stats
        var chosen = reducedPass.sink
        if let failedAt = reducedPass.disqualifiedAtFrame {
            let done = Double(failedAt) / Double(frameCount)
            chosen = try await encodePass(
                document: document, videoPath: videoPath, timeOfDay: timeOfDay,
                userProperties: userProperties, quality: quality, url: tmpURL,
                fps: framesPerSecond
            ) { progress(done + (1 - done) * $0) }.sink
        }
        try Task.checkCancellation()
        try installVideo(chosen.url, at: outputURL)
        AppLog.windowRefresh
            .notice(
                "[bake] Selected \(chosen.fps, privacy: .public)fps, quality=\(quality, privacy: .public) for \(outputURL.lastPathComponent, privacy: .public) (hold PSNR avg: \(stats.averagePSNR, privacy: .public) dB, min: \(stats.minimumPSNR, privacy: .public) dB, changed max: \(stats.maximumChangedFraction * 100, privacy: .public)%)"
            )
        return Statistics(
            holdStats: stats,
            reducedDisqualifiedAtFrame: reducedPass.disqualifiedAtFrame
        )
    }

    private struct Pass {
        let sink: Sink
        let stats: HoldStats
        /// The 60 fps frame at which 30 fps was found not to be enough; nil when it was,
        /// or when the pass encoded at 60 fps.
        let disqualifiedAtFrame: Int?
    }

    /// Renders the loop at 60 fps from a fresh renderer and encodes every frame (60 fps)
    /// or every even one (30 fps). A 30 fps pass compares each odd frame with the even
    /// frame shown in its place and stops, its video discarded, as soon as the
    /// difference rules 30 fps out.
    private static func encodePass(
        document: SceneDocument,
        videoPath: String,
        timeOfDay: SceneTimeOfDay,
        userProperties: [String: WebPropertyValue]?,
        quality: Double,
        url: URL,
        fps: Int,
        progress: (Double) -> Void
    ) async throws -> Pass {
        let frameCount = max(document.loopSeconds, 1) * framesPerSecond
        let renderer = try SceneRenderer(document: document, videoPath: videoPath)
        renderer.timeOfDay = timeOfDay
        try await renderer.prepareVideos()
        // Its own queue: on the shared one, every live preview frame waited behind a
        // full-resolution bake frame and stalled the main thread in nextDrawable.
        guard let commandQueue = renderer.device.makeCommandQueue() else {
            throw BakeError.writerFailed("Cannot create a command queue")
        }
        let (width, height) = SceneRenderer.outputSize(for: document, maxEdge: maxEdge)
        let renderFPS = framesPerSecond
        let judges = fps < renderFPS
        let totalOddFrames = frameCount / 2
        // Simulated particles cannot loop; starting with them already spread out
        // keeps the video from opening on an empty sky.
        renderer.warmUpParticles(seconds: renderer.particleWarmUpSeconds, fps: renderFPS)
        let sink = try makeSink(url: url, width: width, height: height, fps: fps, quality: quality)

        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, renderer.device, nil, &textureCache)
        var stats = HoldStats()
        do {
            guard let textureCache, let pool = sink.adaptor.pixelBufferPool else {
                throw BakeError.writerFailed("No pixel buffer pool")
            }
            var previousEven: CVPixelBuffer?
            for frame in 0 ..< frameCount {
                try Task.checkCancellation()
                let isEncoded = !judges || frame % 2 == 0
                while isEncoded, !sink.input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                var pixelBuffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
                var metalTexture: CVMetalTexture?
                if let pixelBuffer {
                    CVMetalTextureCacheCreateTextureFromImage(
                        nil, textureCache, pixelBuffer, nil, .bgra8Unorm, width, height, 0,
                        &metalTexture
                    )
                }
                guard let pixelBuffer, let metalTexture,
                      let texture = CVMetalTextureGetTexture(metalTexture),
                      let commandBuffer = commandQueue.makeCommandBuffer()
                else {
                    throw BakeError.writerFailed("Cannot allocate frame \(frame)")
                }
                let time = Double(frame) / Double(renderFPS)
                try renderer.encode(
                    into: texture,
                    commandBuffer: commandBuffer,
                    input: SceneFrameInput(time: time, userProperties: userProperties)
                )
                await withCheckedContinuation { continuation in
                    commandBuffer.addCompletedHandler { _ in
                        continuation.resume()
                    }
                    commandBuffer.commit()
                }
                if let error = commandBuffer.error {
                    throw error
                }
                if isEncoded {
                    guard sink.adaptor.append(
                        pixelBuffer,
                        withPresentationTime: CMTime(
                            value: CMTimeValue(judges ? frame / 2 : frame),
                            timescale: CMTimeScale(fps)
                        )
                    ) else {
                        throw BakeError
                            .writerFailed(sink.writer.error?
                                .localizedDescription ?? "Cannot append frame \(frame)")
                    }
                    previousEven = pixelBuffer
                } else if let even = previousEven {
                    stats.add(even: even, odd: pixelBuffer)
                    if stats.isDisqualified(totalOddFrames: totalOddFrames) {
                        sink.input.markAsFinished()
                        sink.writer.cancelWriting()
                        return Pass(sink: sink, stats: stats, disqualifiedAtFrame: frame)
                    }
                }
                progress(Double(frame + 1) / Double(frameCount))
            }
        } catch {
            sink.writer.cancelWriting()
            throw error
        }
        try Task.checkCancellation()
        if judges, !stats.usesReducedRate {
            sink.input.markAsFinished()
            sink.writer.cancelWriting()
            return Pass(sink: sink, stats: stats, disqualifiedAtFrame: frameCount)
        }
        sink.input.markAsFinished()
        sink.writer.endSession(atSourceTime: CMTime(
            value: CMTimeValue(judges ? frameCount / 2 : frameCount),
            timescale: CMTimeScale(fps)
        ))
        await sink.writer.finishWriting()
        guard sink.writer.status == .completed else {
            throw BakeError
                .writerFailed(sink.writer.error?
                    .localizedDescription ?? "Writing did not complete")
        }
        return Pass(sink: sink, stats: stats, disqualifiedAtFrame: nil)
    }

    private struct Sink {
        let url: URL
        let fps: Int
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
    }

    private static func makeSink(
        url: URL,
        width: Int,
        height: Int,
        fps: Int,
        quality: Double
    ) throws -> Sink {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                // Rate control changes texture detail across the loop boundary even when
                // the rendered frames meet; fixed quality keeps that change out of the seam.
                kVTCompressionPropertyKey_Quality as String: quality,
                AVVideoExpectedSourceFrameRateKey: fps
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ]
        )
        guard writer.canAdd(input) else {
            throw BakeError
                .writerFailed(writer.error?.localizedDescription ?? "Cannot add video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw BakeError
                .writerFailed(writer.error?.localizedDescription ?? "Cannot start writing")
        }
        writer.startSession(atSourceTime: .zero)
        return Sink(url: url, fps: fps, writer: writer, input: input, adaptor: adaptor)
    }

    /// Compares each odd frame with the even frame shown before it at 30 fps, on the
    /// raw rendered pixels (not on encoded video).
    struct HoldStats {
        private(set) var totalMSE = 0.0
        private(set) var minPSNR = 100.0
        private(set) var maxChanged = 0.0
        private(set) var count = 0

        var isEmpty: Bool {
            count == 0 // swiftlint:disable:this empty_count
        }

        var averagePSNR: Double {
            isEmpty ? 100 : Self.psnr(totalMSE / Double(count))
        }

        var minimumPSNR: Double {
            minPSNR
        }

        var maximumChangedFraction: Double {
            maxChanged
        }

        var usesReducedRate: Bool {
            !isEmpty && averagePSNR >= holdPSNRAverageThreshold
                && minPSNR >= holdPSNRMinimumThreshold && maxChanged <= changedFractionMaximum
        }

        init(
            totalMSE: Double = 0.0,
            minPSNR: Double = 100.0,
            maxChanged: Double = 0.0,
            count: Int = 0
        ) {
            self.totalMSE = totalMSE
            self.minPSNR = minPSNR
            self.maxChanged = maxChanged
            self.count = count
        }

        func isDisqualified(totalOddFrames: Int) -> Bool {
            minPSNR < SceneVideoBaker.holdPSNRMinimumThreshold
                || maxChanged > SceneVideoBaker.changedFractionMaximum
                ||
                (totalOddFrames > 0 && Self
                    .psnr(totalMSE / Double(totalOddFrames)) < SceneVideoBaker
                    .holdPSNRAverageThreshold)
        }

        static func psnr(_ mse: Double) -> Double {
            mse > 1e-10 ? min(100, 10 * log10(255 * 255 / mse)) : 100
        }

        mutating func add(even: CVPixelBuffer, odd: CVPixelBuffer) {
            CVPixelBufferLockBaseAddress(even, .readOnly)
            CVPixelBufferLockBaseAddress(odd, .readOnly)
            defer {
                CVPixelBufferUnlockBaseAddress(even, .readOnly)
                CVPixelBufferUnlockBaseAddress(odd, .readOnly)
            }
            guard let evenBase = CVPixelBufferGetBaseAddress(even)?
                .assumingMemoryBound(to: UInt8.self),
                let oddBase = CVPixelBufferGetBaseAddress(odd)?
                .assumingMemoryBound(to: UInt8.self)
            else { return }
            let width = CVPixelBufferGetWidth(odd)
            let height = CVPixelBufferGetHeight(odd)
            let evenStride = CVPixelBufferGetBytesPerRow(even)
            let oddStride = CVPixelBufferGetBytesPerRow(odd)
            // Stride 2 cuts the 4K pass by 4x; a 1-pixel feature is still caught by its neighbours.
            let step = 2
            var squared = 0
            var changed = 0
            var sampled = 0
            for y in stride(from: 0, to: height, by: step) {
                let rowEven = evenBase.advanced(by: y * evenStride)
                let rowOdd = oddBase.advanced(by: y * oddStride)
                for x in stride(from: 0, to: width, by: step) {
                    let i = x * 4
                    let db = Int(rowEven[i]) - Int(rowOdd[i])
                    let dg = Int(rowEven[i + 1]) - Int(rowOdd[i + 1])
                    let dr = Int(rowEven[i + 2]) - Int(rowOdd[i + 2])
                    squared += db * db + dg * dg + dr * dr
                    if max(abs(db), abs(dg), abs(dr)) > changedPixelDelta { changed += 1 }
                    sampled += 1
                }
            }
            guard sampled > 0 else { return }
            let mse = Double(squared) / Double(sampled * 3)
            totalMSE += mse
            minPSNR = min(minPSNR, Self.psnr(mse))
            maxChanged = max(maxChanged, Double(changed) / Double(sampled))
            count += 1
        }
    }

    private static func installVideo(_ tmpURL: URL, at outputURL: URL) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tmpURL)
        } else {
            try FileManager.default.moveItem(at: tmpURL, to: outputURL)
        }
    }

    private static func removeIfPresent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            AppLog.windowRefresh
                .error("bake cleanup failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

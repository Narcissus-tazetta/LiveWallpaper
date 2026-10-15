import AVFoundation
@testable import LiveWallpaper
import XCTest

final class AerialVideoExporterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AerialVideoExporter-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// The lock screen freezes after the first unlock unless every sample carries HEVC
    /// temporal layer information, as Apple's 240 fps Aerials do.
    func testVideosBecome240FPSHEVCWithTemporalLayers() async throws {
        let source = try await writeH264Video(seconds: 2, framesPerSecond: 30)
        let destination = directory.appendingPathComponent("aerial.mov")

        try await AerialVideoExporter(
            fileManager: .default,
            encodesVideo: true,
            cacheDirectory: nil
        )
        .prepareVideo(from: source, to: destination)

        let asset = AVURLAsset(url: destination)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_HEVC)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 2, accuracy: 0.05)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples = 0
        var withLayers = 0
        var levels = Set<Int>()
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else {
                continue
            }
            samples += 1
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample,
                createIfNecessary: false
            ) as? [[CFString: Any]]
            if let info = attachments?
                .first?[kCMSampleAttachmentKey_HEVCTemporalLevelInfo] as? [CFString: Any]
            {
                withLayers += 1
                if let level = info[kCMHEVCTemporalLevelInfoKey_TemporalLevel] as? Int {
                    levels.insert(level)
                }
            }
        }
        XCTAssertEqual(samples, 480, "2 s at 240 fps")
        // Without an encoder that makes them, the video is still made, without layers.
        guard AerialVideoExporter.supportsTemporalLayers else {
            return
        }
        XCTAssertEqual(withLayers, samples)
        XCTAssertGreaterThan(levels.count, 1, "more than the base layer: \(levels)")
    }

    /// A long 4K video takes over an hour: the same source must not be encoded again.
    func testTheSameSourceIsEncodedOnceAndReportsProgress() async throws {
        let source = try await writeH264Video(seconds: 2, framesPerSecond: 30)
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        let exporter = AerialVideoExporter(
            fileManager: .default,
            encodesVideo: true,
            cacheDirectory: cache
        )
        let reports = Reports()

        try await exporter.prepareVideo(
            from: source,
            to: directory.appendingPathComponent("first.mov")
        ) { reports.add($0) }
        let first = reports.values
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, first.sorted(), "progress only grows")
        XCTAssertEqual(try XCTUnwrap(first.last), 1, accuracy: 0.05)

        try await exporter.prepareVideo(
            from: source,
            to: directory.appendingPathComponent("second.mov")
        ) { reports.add($0) }
        XCTAssertEqual(reports.values.count, first.count, "the second time comes from the cache")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: cache.path)
                .filter { !$0.hasPrefix(".") }.count, 1
        )
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("first.mov")),
            try Data(contentsOf: directory.appendingPathComponent("second.mov"))
        )
    }

    /// Without the app, the desktop shows the lock screen video's first frame: a video
    /// that fades in from black must not leave a black desktop, nor lose its opening.
    func testAVideoThatFadesInFromBlackStartsAtItsFirstVisibleFrame() async throws {
        // Black for the first half second, then bright.
        let source = try await writeH264Video(seconds: 2, framesPerSecond: 30) { frame in
            frame < 15 ? 0 : 200
        }
        let destination = directory.appendingPathComponent("aerial.mov")

        try await AerialVideoExporter(
            fileManager: .default,
            encodesVideo: true,
            cacheDirectory: nil
        )
        .prepareVideo(from: source, to: destination)

        let asset = AVURLAsset(url: destination)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 2, accuracy: 0.05)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let first = try await generator.image(at: .zero).image
        let opening = try await generator.image(at: CMTime(value: 1700, timescale: 1000)).image
        XCTAssertGreaterThan(try brightness(of: first), 150)
        XCTAssertLessThan(try brightness(of: opening), 20, "the dark opening plays at the end")
    }

    /// The user can pick the frame the lock screen (and the desktop after quitting)
    /// begins at, even where the automatic choice would start elsewhere.
    func testAPickedStartFrameComesFirst() async throws {
        // Bright for the first second, then dim: on its own it would start at zero.
        let source = try await writeH264Video(seconds: 2, framesPerSecond: 30) { frame in
            frame < 30 ? 200 : 80
        }
        let destination = directory.appendingPathComponent("aerial.mov")

        try await AerialVideoExporter(
            fileManager: .default,
            encodesVideo: true,
            cacheDirectory: nil
        )
        .prepareVideo(from: source, to: destination, start: 1.0)

        let asset = AVURLAsset(url: destination)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 2, accuracy: 0.05)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let first = try await generator.image(at: .zero).image
        let later = try await generator.image(at: CMTime(value: 1500, timescale: 1000)).image
        XCTAssertEqual(try brightness(of: first), 80, accuracy: 20)
        XCTAssertEqual(try brightness(of: later), 200, accuracy: 20, "the part before the start plays at the end")
    }

    func testANonVideoIsRejected() async throws {
        let source = directory.appendingPathComponent("source.mov")
        try Data("not a movie".utf8).write(to: source)
        let destination = directory.appendingPathComponent("aerial.mov")

        do {
            try await AerialVideoExporter(
                fileManager: .default,
                encodesVideo: true,
                cacheDirectory: nil
            )
            .prepareVideo(from: source, to: destination)
            XCTFail("Expected invalidVideo")
        } catch LockScreenSyncError.invalidVideo {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    private func brightness(of image: CGImage) throws -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Double(pixel[0])
    }

    private func writeH264Video(
        seconds: Int,
        framesPerSecond: Int32,
        // A brightness that changes every frame, so no two frames are identical.
        brightness: (Int) -> Int32 = { Int32($0 * 4 % 256) }
    ) async throws -> URL {
        let url = directory.appendingPathComponent("source.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 96
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 96
            ]
        )
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0 ..< Int(framesPerSecond) * seconds {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let pool = try XCTUnwrap(adaptor.pixelBufferPool)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(
                CVPixelBufferGetBaseAddress(pixels),
                brightness(frame),
                CVPixelBufferGetDataSize(pixels)
            )
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(
                pixels,
                withPresentationTime: CMTime(value: Int64(frame), timescale: framesPerSecond)
            ))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }
}

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func add(_ value: Double) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }
}

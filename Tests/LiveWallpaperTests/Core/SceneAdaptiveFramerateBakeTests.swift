import AppKit
import AVFoundation
@testable import LiveWallpaper
import XCTest

@MainActor
final class SceneAdaptiveFramerateBakeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneAdaptiveFramerateBakeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func makeScene(videoURL: URL, cycles: Int = 1) throws -> SceneDocument {
        var pixels = [UInt8](repeating: 255, count: 64 * 64 * 4)
        for y in 0 ..< 64 {
            for x in 0 ..< 64 {
                let index = (y * 64 + x) * 4
                pixels[index] = UInt8(x * 4)
                pixels[index + 1] = UInt8(y * 4)
                pixels[index + 2] = 0
            }
        }
        let image = CGImage(
            width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )!
        let file = try SceneStore.writeImage(image, prefix: "layer", videoPath: videoURL.path)
        var layer = SceneLayer(name: "gradient", imageFile: file)
        var spin = SceneEffect(kind: .spin)
        spin.cycles = cycles
        layer.effects = [spin]
        var doc = SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [layer])
        doc.loopSeconds = 10
        return doc
    }

    func testBakeGentleSceneProduces30FPSVideo() async throws {
        let video = directory.appendingPathComponent("gentle.mp4")
        // One turn per 10 s moves the rim of a 64x64 canvas well under a pixel per frame
        let scene = try makeScene(videoURL: video, cycles: 1)

        try await SceneVideoBaker.bake(document: scene, videoPath: video.path, to: video) { _ in }

        let asset = AVURLAsset(url: video)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let frameRate = try await track.load(.nominalFrameRate)
        XCTAssertEqual(round(Double(frameRate)), 30.0, "Gentle motion scene should be baked at 30 fps")
    }

    func testBakeRapidMotionKeeps60FPSVideo() async throws {
        let video = directory.appendingPathComponent("rapid.mp4")
        // 300 turns in 10 s = a full spin every 2 frames
        let scene = try makeScene(videoURL: video, cycles: 300)

        try await SceneVideoBaker.bake(document: scene, videoPath: video.path, to: video) { _ in }

        let asset = AVURLAsset(url: video)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let frameRate = try await track.load(.nominalFrameRate)
        XCTAssertEqual(round(Double(frameRate)), 60.0, "Rapid motion scene should be kept at 60 fps")
    }

    func testHoldStatsIsDisqualifiedThresholds() {
        let totalOddFrames = 100
        let thresholdMSE = 65025.0 / pow(10.0, SceneVideoBaker.holdPSNRAverageThreshold / 10.0)

        let defaultStats = SceneVideoBaker.HoldStats()
        XCTAssertFalse(defaultStats.isDisqualified(totalOddFrames: totalOddFrames))
        XCTAssertFalse(defaultStats.isDisqualified(totalOddFrames: 0))
        XCTAssertFalse(defaultStats.isDisqualified(totalOddFrames: -1))

        // minPSNR boundary (threshold: 42.0 dB)
        let statsAtMinPSNR = SceneVideoBaker.HoldStats(totalMSE: 0, minPSNR: 42.0, maxChanged: 0, count: 1)
        XCTAssertFalse(statsAtMinPSNR.isDisqualified(totalOddFrames: totalOddFrames))

        let statsBelowMinPSNR = SceneVideoBaker.HoldStats(totalMSE: 0, minPSNR: 41.999, maxChanged: 0, count: 1)
        XCTAssertTrue(statsBelowMinPSNR.isDisqualified(totalOddFrames: totalOddFrames))

        let statsAboveMinPSNR = SceneVideoBaker.HoldStats(totalMSE: 0, minPSNR: 42.001, maxChanged: 0, count: 1)
        XCTAssertFalse(statsAboveMinPSNR.isDisqualified(totalOddFrames: totalOddFrames))

        // maxChanged boundary (threshold: 0.006)
        let statsAtChanged = SceneVideoBaker.HoldStats(totalMSE: 0, minPSNR: 100, maxChanged: 0.006, count: 1)
        XCTAssertFalse(statsAtChanged.isDisqualified(totalOddFrames: totalOddFrames))

        let statsAboveChanged = SceneVideoBaker.HoldStats(totalMSE: 0, minPSNR: 100, maxChanged: 0.006001, count: 1)
        XCTAssertTrue(statsAboveChanged.isDisqualified(totalOddFrames: totalOddFrames))

        let statsBelowChanged = SceneVideoBaker.HoldStats(totalMSE: 0, minPSNR: 100, maxChanged: 0.005999, count: 1)
        XCTAssertFalse(statsBelowChanged.isDisqualified(totalOddFrames: totalOddFrames))

        // average PSNR boundary (threshold: 45.0 dB)
        let statsAtAvg = SceneVideoBaker.HoldStats(
            totalMSE: thresholdMSE * Double(totalOddFrames), minPSNR: 100, maxChanged: 0, count: 50
        )
        XCTAssertFalse(statsAtAvg.isDisqualified(totalOddFrames: totalOddFrames))

        let statsDisqualifiedByAvg = SceneVideoBaker.HoldStats(
            totalMSE: (thresholdMSE + 0.01) * Double(totalOddFrames), minPSNR: 100, maxChanged: 0, count: 50
        )
        XCTAssertTrue(statsDisqualifiedByAvg.isDisqualified(totalOddFrames: totalOddFrames))

        let statsSafeAvg = SceneVideoBaker.HoldStats(
            totalMSE: (thresholdMSE - 0.01) * Double(totalOddFrames), minPSNR: 100, maxChanged: 0, count: 50
        )
        XCTAssertFalse(statsSafeAvg.isDisqualified(totalOddFrames: totalOddFrames))
    }

    func testHoldStatsIsDisqualifiedMonotonicity() {
        let totalOddFrames = 20

        // Once minPSNR drops below threshold, subsequent high-quality frames cannot revert it
        var statsMinPSNR = SceneVideoBaker.HoldStats(totalMSE: 0, minPSNR: 41.5, maxChanged: 0, count: 1)
        XCTAssertTrue(statsMinPSNR.isDisqualified(totalOddFrames: totalOddFrames))
        for _ in 0 ..< 10 {
            // Even with perfect PSNR frames added, minPSNR remains <= 41.5
            statsMinPSNR = SceneVideoBaker.HoldStats(
                totalMSE: statsMinPSNR.totalMSE,
                minPSNR: min(statsMinPSNR.minimumPSNR, 100.0),
                maxChanged: statsMinPSNR.maximumChangedFraction,
                count: statsMinPSNR.count + 1
            )
            XCTAssertTrue(statsMinPSNR.isDisqualified(totalOddFrames: totalOddFrames))
        }

        // Once maxChanged exceeds threshold, subsequent 0%-changed frames cannot revert it
        var statsChanged = SceneVideoBaker.HoldStats(totalMSE: 0, minPSNR: 100, maxChanged: 0.01, count: 1)
        XCTAssertTrue(statsChanged.isDisqualified(totalOddFrames: totalOddFrames))
        for _ in 0 ..< 10 {
            statsChanged = SceneVideoBaker.HoldStats(
                totalMSE: statsChanged.totalMSE,
                minPSNR: statsChanged.minimumPSNR,
                maxChanged: max(statsChanged.maximumChangedFraction, 0.0),
                count: statsChanged.count + 1
            )
            XCTAssertTrue(statsChanged.isDisqualified(totalOddFrames: totalOddFrames))
        }

        // Once totalMSE exceeds threshold, non-negative MSE increments cannot revert it
        let thresholdMSE = 65025.0 / pow(10.0, SceneVideoBaker.holdPSNRAverageThreshold / 10.0)
        var statsAvg = SceneVideoBaker.HoldStats(
            totalMSE: (thresholdMSE + 0.1) * Double(totalOddFrames), minPSNR: 100, maxChanged: 0, count: 5
        )
        XCTAssertTrue(statsAvg.isDisqualified(totalOddFrames: totalOddFrames))
        for _ in 0 ..< 10 {
            statsAvg = SceneVideoBaker.HoldStats(
                totalMSE: statsAvg.totalMSE + 0.5,
                minPSNR: statsAvg.minimumPSNR,
                maxChanged: statsAvg.maximumChangedFraction,
                count: statsAvg.count + 1
            )
            XCTAssertTrue(statsAvg.isDisqualified(totalOddFrames: totalOddFrames))
        }

        // Monotonicity using real pixel buffers with stats.add
        var statsWithBuffers = SceneVideoBaker.HoldStats()
        let black = makePixelBuffer(fill: 0)
        let white = makePixelBuffer(fill: 255)
        statsWithBuffers.add(even: black, odd: white)
        XCTAssertTrue(statsWithBuffers.isDisqualified(totalOddFrames: totalOddFrames))

        // Adding identical frames (MSE = 0, delta = 0) must keep isDisqualified true
        for _ in 0 ..< 5 {
            statsWithBuffers.add(even: black, odd: black)
            XCTAssertTrue(statsWithBuffers.isDisqualified(totalOddFrames: totalOddFrames))
        }
    }

    func testBakeRapidMotionEarlyDisqualifiesReducedSink() async throws {
        let video = directory.appendingPathComponent("rapid-early.mp4")
        let scene = try makeScene(videoURL: video, cycles: 300)

        let result = try await SceneVideoBaker.bake(document: scene, videoPath: video.path, to: video) { _ in }
        let statistics = try XCTUnwrap(result)

        XCTAssertEqual(statistics.reducedDisqualifiedAtFrame, 1, "Rapid motion scene must disqualify 30 fps sink on frame 1")
        let stats = statistics.holdStats
        XCTAssertEqual(stats.count, 1, "Only 1 odd frame should be evaluated after early disqualification")
        XCTAssertTrue(stats.isDisqualified(totalOddFrames: 300))
        XCTAssertFalse(stats.usesReducedRate)

        let asset = AVURLAsset(url: video)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let frameRate = try await track.load(.nominalFrameRate)
        XCTAssertEqual(round(Double(frameRate)), 60.0, "Resulting video must still be 60 fps")
    }

    func testBakeGentleSceneDoesNotDisqualifyAndProcessesAllFrames() async throws {
        let video = directory.appendingPathComponent("gentle-full.mp4")
        let scene = try makeScene(videoURL: video, cycles: 1)

        let result = try await SceneVideoBaker.bake(document: scene, videoPath: video.path, to: video) { _ in }
        let statistics = try XCTUnwrap(result)

        XCTAssertNil(statistics.reducedDisqualifiedAtFrame, "Gentle motion scene must not be disqualified")
        let stats = statistics.holdStats
        XCTAssertEqual(stats.count, 300, "All 300 odd frames must be evaluated for gentle motion scene")
        XCTAssertTrue(stats.usesReducedRate)

        let asset = AVURLAsset(url: video)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let frameRate = try await track.load(.nominalFrameRate)
        XCTAssertEqual(round(Double(frameRate)), 30.0, "Resulting video must be 30 fps")
    }

    func testHoldStatsIntermediateCumulativeMSEDisqualification() {
        let totalOddFrames = 5
        let base = makePixelBuffer(blue: 100, green: 100, red: 100)
        let slightlyDifferent = makePixelBuffer(blue: 102, green: 100, red: 100)

        var stats = SceneVideoBaker.HoldStats()
        for _ in 1 ... 7 {
            stats.add(even: base, odd: slightlyDifferent)
            XCTAssertFalse(stats.isDisqualified(totalOddFrames: totalOddFrames))
            XCTAssertGreaterThanOrEqual(stats.minimumPSNR, SceneVideoBaker.holdPSNRMinimumThreshold)
            XCTAssertLessThanOrEqual(stats.maximumChangedFraction, SceneVideoBaker.changedFractionMaximum)
        }

        stats.add(even: base, odd: slightlyDifferent)
        XCTAssertTrue(stats.isDisqualified(totalOddFrames: totalOddFrames))
        XCTAssertGreaterThanOrEqual(stats.minimumPSNR, SceneVideoBaker.holdPSNRMinimumThreshold)
        XCTAssertLessThanOrEqual(stats.maximumChangedFraction, SceneVideoBaker.changedFractionMaximum)
    }

    func testConcurrentBakesReturnIndependentStatistics() async throws {
        let rapidURL = directory.appendingPathComponent("parallel-rapid.mp4")
        let gentleURL = directory.appendingPathComponent("parallel-gentle.mp4")
        var rapid = try makeScene(videoURL: rapidURL, cycles: 300)
        rapid.loopSeconds = 1
        var gentle = try makeScene(videoURL: gentleURL)
        gentle.loopSeconds = 1
        gentle.layers[0].effects[0].kind = .sway
        gentle.layers[0].effects[0].strength = 0

        async let rapidResult = SceneVideoBaker.bake(document: rapid, videoPath: rapidURL.path, to: rapidURL) { _ in }
        async let gentleResult = SceneVideoBaker.bake(document: gentle, videoPath: gentleURL.path, to: gentleURL) { _ in }
        let (rapidValue, gentleValue) = try await (rapidResult, gentleResult)
        let rapidStats = try XCTUnwrap(rapidValue)
        let gentleStats = try XCTUnwrap(gentleValue)
        XCTAssertEqual(rapidStats.reducedDisqualifiedAtFrame, 1)
        XCTAssertEqual(rapidStats.holdStats.count, 1)
        XCTAssertFalse(rapidStats.holdStats.usesReducedRate)
        XCTAssertNil(gentleStats.reducedDisqualifiedAtFrame)
        XCTAssertEqual(gentleStats.holdStats.count, 30)
        XCTAssertTrue(gentleStats.holdStats.usesReducedRate)

        for (url, fps) in [(rapidURL, 60.0), (gentleURL, 30.0)] {
            let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let actualFPS = try await track.load(.nominalFrameRate)
            XCTAssertEqual(Double(actualFPS).rounded(), fps)
        }
    }

    func testBakeIntermediateDisqualificationWithKeyframes() async throws {
        let video = directory.appendingPathComponent("intermediate-early.mp4")
        var pixels = [UInt8](repeating: 255, count: 64 * 64 * 4)
        for y in 0 ..< 64 {
            for x in 0 ..< 64 {
                let index = (y * 64 + x) * 4
                pixels[index] = UInt8(x * 4)
                pixels[index + 1] = UInt8(y * 4)
                pixels[index + 2] = 0
            }
        }
        let image = CGImage(
            width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )!
        let file = try SceneStore.writeImage(image, prefix: "layer", videoPath: video.path)
        var layer = SceneLayer(name: "gradient", imageFile: file)
        var rotatedTransform = SceneTransform()
        rotatedTransform.rotation = 180
        layer.keyframes = [
            SceneKeyframe(time: 0.0, transform: .identity),
            SceneKeyframe(time: 0.4, transform: .identity),
            SceneKeyframe(time: 0.7, transform: rotatedTransform),
            SceneKeyframe(time: 1.0, transform: .identity)
        ]
        var doc = SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [layer])
        doc.loopSeconds = 1

        let result = try await SceneVideoBaker.bake(document: doc, videoPath: video.path, to: video) { _ in }
        let statistics = try XCTUnwrap(result)

        let frame = try XCTUnwrap(statistics.reducedDisqualifiedAtFrame)
        XCTAssertGreaterThan(frame, 1, "Must disqualify at an intermediate frame, not on frame 1")
        XCTAssertLessThan(frame, 60, "Must disqualify before loop completes")
        let stats = statistics.holdStats
        XCTAssertGreaterThan(stats.count, 1, "Multiple odd frames must be evaluated before disqualification")
        XCTAssertLessThan(stats.count, 30, "Subsequent frames must not be evaluated after disqualification")
        XCTAssertTrue(stats.isDisqualified(totalOddFrames: 30))

        let asset = AVURLAsset(url: video)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let frameRate = try await track.load(.nominalFrameRate)
        XCTAssertEqual(round(Double(frameRate)), 60.0, "Resulting video must still be 60 fps")
    }

    private func makePixelBuffer(
        width: Int = 16, height: Int = 16,
        blue: UInt8 = 0, green: UInt8 = 0, red: UInt8 = 0
    ) -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attrs, &pixelBuffer
        )
        let pb = pixelBuffer!
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        for y in 0 ..< height {
            let row = base.advanced(by: y * stride)
            for x in 0 ..< width {
                row[x * 4] = blue
                row[x * 4 + 1] = green
                row[x * 4 + 2] = red
                row[x * 4 + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    private func makePixelBuffer(width: Int = 16, height: Int = 16, fill: UInt8 = 0) -> CVPixelBuffer {
        makePixelBuffer(width: width, height: height, blue: fill, green: fill, red: fill)
    }
}

import AppKit
import AVFoundation
@testable import LiveWallpaper
import XCTest

@MainActor
final class LightweightProxyPlaybackTests: XCTestCase {
    private func waitUntil(
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(
            condition(),
            "Playback / generation did not reach the expected state",
            file: file,
            line: line
        )
    }

    func testDedicatedSelectionRequestsAProxy() {
        _ = NSApplication.shared
        let model = WallpaperModel(lightweightProxyCache: LightweightProxyCache(rootDirectory: nil))
        model.lightweightMode = true
        model.lightweightProxyCache.initializationState = .loading
        defer {
            model.stopAllDedicatedPlayers(); model.lightweightProxyCache.cancelActiveGeneration()
        }
        _ = model.ensureDedicatedPlayer(forScreenID: "proxy-test", path: "/tmp/proxy-test.mp4")
        XCTAssertEqual(model.lightweightProxyState, .generating)
    }

    private func fixture(
        _ url: URL,
        width: Int = 1920,
        height: Int = 1080,
        fps: Int32 = 60
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
            ]
        )
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0 ..< Int(fps) * 3 {
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while !input.isReadyForMoreMediaData, writer.status == .writing,
                  ProcessInfo.processInfo.systemUptime < deadline
            {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            var buffer: CVPixelBuffer?
            try CVPixelBufferPoolCreatePixelBuffer(nil, XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixelBuffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            try memset(
                XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer)),
                Int32(50 + frame % 180),
                CVPixelBufferGetDataSize(pixelBuffer)
            )
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            XCTAssertTrue(adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)
            ))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyPlayback-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func assetURL(_ player: AVQueuePlayer) -> URL? {
        (player.currentItem?.asset as? AVURLAsset)?.url
    }

    func testTwoDedicatedVideosGenerateAndSwapWhilePreservingPauseAndPlayback() async throws {
        let root = try directory()
        let first = root.appendingPathComponent("first.mp4"),
            second = root.appendingPathComponent("second.mp4")
        try await fixture(first)
        try await fixture(second)
        let cache = LightweightProxyCache(rootDirectory: root.appendingPathComponent("cache"))
        let model = WallpaperModel(lightweightProxyCache: cache)
        model.lightweightMode = true
        model.dedicatedPlaybackContinuityEnabled = false
        defer {
            model.stopAllPlayers(); model.stopAllDedicatedPlayers(); cache
                .cancelActiveGeneration(); cache.flushMetadataImmediately()
        }
        // Hold initialization until both originals have a playhead to preserve.
        cache.initializationState = .loading
        model.currentVideoPath = first.path
        model.playRegisteredVideo(path: first.path)
        var a = model.ensureDedicatedPlayer(forScreenID: "screen-a", path: first.path)
        var b = model.ensureDedicatedPlayer(forScreenID: "screen-b", path: second.path)
        _ = model.ensureDedicatedPlayer(forScreenID: "screen-c", path: first.path)
        try await waitUntil {
            a.currentItem?.status == .readyToPlay && b.currentItem?.status == .readyToPlay
        }
        await a.seek(
            to: CMTime(seconds: 1, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        await b.seek(
            to: CMTime(seconds: 1.5, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        a.play()
        XCTAssertEqual(model.lightweightProxyState, .generating)
        cache.initializationState = .idle
        cache.ensureInitialized()
        try await waitUntil(timeout: 40) { model.lightweightProxyState == .ready }
        a = try XCTUnwrap(model.dedicatedSlotsByScreenID["screen-a"]?[first.path]?.player)
        b = try XCTUnwrap(model.dedicatedSlotsByScreenID["screen-b"]?[second.path]?.player)
        let firstProxy = try XCTUnwrap(cache.cachedProxyURL(for: first.path))
        let secondProxy = try XCTUnwrap(cache.cachedProxyURL(for: second.path))
        try await waitUntil { self.assetURL(a) == firstProxy && self.assetURL(b) == secondProxy }
        XCTAssertEqual(assetURL(a), firstProxy)
        XCTAssertEqual(assetURL(b), secondProxy)
        let shared = try XCTUnwrap(model.sharedPlayer)
        try await waitUntil { self.assetURL(shared) == firstProxy }
        XCTAssertEqual(
            assetURL(model.ensureDedicatedPlayer(forScreenID: "screen-c", path: first.path)),
            firstProxy
        )
        try await waitUntil { a.rate > 0 && b.currentTime().seconds > 1 }
        XCTAssertEqual(b.rate, 0)
        XCTAssertEqual(b.currentTime().seconds, 1.5, accuracy: 0.1)
        XCTAssertTrue(a.isMuted && b.isMuted)
        for url in [firstProxy, secondProxy] {
            let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let size = try await track.load(.naturalSize)
            let fps = try await track.load(.nominalFrameRate)
            XCTAssertLessThanOrEqual(max(size.width, size.height), 1280)
            XCTAssertLessThanOrEqual(fps, 30.1)
            print("Dedicated proxy output: \(size.width)x\(size.height), \(fps) fps")
        }
        let before = a.currentTime().seconds
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNotEqual(a.currentTime().seconds, before, accuracy: 0.05)
        let looper = try XCTUnwrap(model.dedicatedSlotsByScreenID["screen-a"]?[first.path]?.looper)
        try await waitUntil(timeout: 5) { looper.loopCount > 0 }
        XCTAssertGreaterThan(a.rate, 0)
        model.lightweightMode = false
        model.applyLightweightSettings()
        model.requestPlaybackReconfiguration()
        try await waitUntil {
            model.dedicatedSlotsByScreenID["screen-a"]?[first.path]?.player !== a
        }
        a = try XCTUnwrap(model.dedicatedSlotsByScreenID["screen-a"]?[first.path]?.player)
        b = try XCTUnwrap(model.dedicatedSlotsByScreenID["screen-b"]?[second.path]?.player)
        try await waitUntil { self.assetURL(a) == first && self.assetURL(b) == second }
        try await waitUntil { b.currentTime().seconds > 1 }
        XCTAssertEqual(b.rate, 0)
        XCTAssertEqual(b.currentTime().seconds, 1.5, accuracy: 0.1)
        XCTAssertEqual(model.lightweightProxyState, .idle)
        model.lightweightMode = true
        let cachedPlayer = model.ensureDedicatedPlayer(forScreenID: "screen-a", path: first.path)
        XCTAssertFalse(cachedPlayer === a)
        XCTAssertTrue(model.ensureDedicatedPlayer(forScreenID: "screen-a", path: first.path) === cachedPlayer)
        try await waitUntil { self.assetURL(cachedPlayer) == firstProxy }
    }

    func testQueuedRequestsSurviveInitializationAndNotifyEverySubscriber() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("small.mp4")
        try await fixture(url, width: 64, height: 48, fps: 30)
        let cache = LightweightProxyCache(rootDirectory: root.appendingPathComponent("cache"))
        defer { cache.cancelActiveGeneration(); cache.flushMetadataImmediately() }
        var ready = 0, failed = 0
        for path in [url.path, root.appendingPathComponent("missing.mp4").path, url.path] {
            cache.generateProxyIfNeeded(for: path) { result in
                switch result {
                case .passthrough: ready += 1
                case .failed: failed += 1
                default: XCTFail("Unexpected result")
                }
            }
        }
        try await waitUntil { ready == 2 && failed == 1 }
        XCTAssertNil(cache.activeGeneration)
    }

    func testCancellingNotifiesQueuedRequestsAndAllowsImmediateSamePathRestart() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("video.mp4")
        try await fixture(url)
        let cache = LightweightProxyCache(rootDirectory: root.appendingPathComponent("cache"))
        cache.initializationState = .ready
        defer { cache.cancelActiveGeneration(); cache.flushMetadataImmediately() }
        var cancelled = 0, completed = false
        cache
            .generateProxyIfNeeded(for: url.path) {
                if case .cancelled = $0 { cancelled += 1 } else { XCTFail() }
            }
        cache
            .generateProxyIfNeeded(for: "missing") {
                if case .cancelled = $0 { cancelled += 1 } else { XCTFail() }
            }
        try await waitUntil { cache.activeGeneration?.session != nil }
        cache.cancelActiveGeneration()
        cache
            .generateProxyIfNeeded(for: url.path) {
                if case .ready = $0 { completed = true } else { XCTFail() }
            }
        try await waitUntil(timeout: 40) { completed }
        XCTAssertEqual(cancelled, 2)
    }

    func testChangedDedicatedPathDoesNotSwapOldCompletionAndFailureIsVisible() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("video.mp4")
        try await fixture(url)
        let cache = LightweightProxyCache(rootDirectory: root.appendingPathComponent("cache"))
        let model = WallpaperModel(lightweightProxyCache: cache)
        model.lightweightMode = true
        cache.initializationState = .loading
        defer {
            model.stopAllPlayers(); model.stopAllDedicatedPlayers(); cache
                .cancelActiveGeneration(); cache.flushMetadataImmediately()
        }
        let old = model.ensureDedicatedPlayer(forScreenID: "screen-a", path: url.path)
        let missing = root.appendingPathComponent("missing.mp4")
        let current = model.ensureDedicatedPlayer(forScreenID: "screen-a", path: missing.path)
        cache.initializationState = .idle
        cache.ensureInitialized()
        try await waitUntil(timeout: 40) { model.lightweightProxyState == .failed }
        XCTAssertFalse(current === old)
        XCTAssertNotEqual(assetURL(current), url)
        XCTAssertEqual(assetURL(old), url)
        XCTAssertEqual(model.activeDedicatedPathByScreenID["screen-a"], missing.path)
    }

    func testTrimmedSuspendedPlaybackKeepsItsPositionAfterGeneration() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("trimmed.mp4")
        try await fixture(url)
        let cache = LightweightProxyCache(rootDirectory: root.appendingPathComponent("cache"))
        let model = WallpaperModel(lightweightProxyCache: cache)
        model.lightweightMode = true
        model.dedicatedPlaybackContinuityEnabled = true
        model.wallpaperEditByPath[url.path] = WallpaperEditMetadata(
            trimStart: 0.5,
            trimEnd: 2.5,
            loopStart: 1
        )
        model.suspendedDisplayIDs = ["screen-a"]
        cache.initializationState = .loading
        defer {
            model.stopAllPlayers(); model.stopAllDedicatedPlayers(); cache
                .cancelActiveGeneration(); cache.flushMetadataImmediately()
        }
        var player = model.ensureDedicatedPlayer(forScreenID: "screen-a", path: url.path)
        try await waitUntil { player.currentItem?.status == .readyToPlay }
        // Give the intro's initial seek time to settle before choosing a resume position.
        try await Task.sleep(nanoseconds: 150_000_000)
        await player.seek(
            to: CMTime(seconds: 1.75, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        cache.initializationState = .idle
        cache.ensureInitialized()
        try await waitUntil(timeout: 40) { model.lightweightProxyState == .ready }
        player = try XCTUnwrap(model.dedicatedSlotsByScreenID["screen-a"]?[url.path]?.player)
        try await waitUntil { abs(player.currentTime().seconds - 1.75) < 0.1 }
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(assetURL(player), cache.cachedProxyURL(for: url.path))
        model.suspendedDisplayIDs = []
        player.play()
        let looper = try XCTUnwrap(model.dedicatedSlotsByScreenID["screen-a"]?[url.path]?.looper)
        try await waitUntil(timeout: 5) { looper.loopCount > 0 }
        XCTAssertGreaterThanOrEqual(player.currentTime().seconds, 0.95)
        XCTAssertLessThan(player.currentTime().seconds, 2.55)
        XCTAssertGreaterThan(player.rate, 0)
    }

    func testDisablingModeDuringGenerationLeavesTheOriginalPlayer() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("video.mp4")
        try await fixture(url)
        let cache = LightweightProxyCache(rootDirectory: root.appendingPathComponent("cache"))
        let model = WallpaperModel(lightweightProxyCache: cache)
        model.lightweightMode = true
        cache.initializationState = .ready
        defer {
            model.stopAllPlayers(); model.stopAllDedicatedPlayers(); cache
                .cancelActiveGeneration(); cache.flushMetadataImmediately()
        }
        let player = model.ensureDedicatedPlayer(forScreenID: "screen-a", path: url.path)
        try await waitUntil { cache.activeGeneration?.session != nil }
        model.lightweightMode = false
        model.applyLightweightSettings()
        try await waitUntil { cache.activeGeneration == nil }
        XCTAssertEqual(model.lightweightProxyState, .idle)
        XCTAssertEqual(assetURL(player), url)
        XCTAssertNil(cache.cachedProxyURL(for: url.path))
    }

    func testDownscalingDoesNotIncreaseLowFrameRates() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("slow.mp4")
        try await fixture(url, fps: 15)
        let cache = LightweightProxyCache(rootDirectory: root.appendingPathComponent("cache"))
        defer { cache.cancelActiveGeneration(); cache.flushMetadataImmediately() }
        var output: URL?
        cache.generateProxyIfNeeded(for: url.path) {
            if case let .ready(url) = $0 { output = url }
            else { XCTFail("Proxy generation failed") }
        }
        try await waitUntil(timeout: 40) { output != nil }
        let tracks = try await AVURLAsset(url: XCTUnwrap(output)).loadTracks(withMediaType: .video)
        let fps = try await XCTUnwrap(tracks.first).load(.nominalFrameRate)
        XCTAssertLessThanOrEqual(fps, 15.1)
    }

    func testDedicatedViewReceivesTheGeneratedPlayer() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("view.mp4")
        try await fixture(url)
        let cache = LightweightProxyCache(rootDirectory: root.appendingPathComponent("cache"))
        let model = WallpaperModel(lightweightProxyCache: cache)
        model.lightweightMode = true
        cache.initializationState = .loading
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let view = try PlayerView(frame: XCTUnwrap(window.contentView?.bounds))
        window.contentView = view
        model.windows = [window]
        model.playerViews = [view]
        model.displayIDByWindow[ObjectIdentifier(window)] = "screen-a"
        let original = model.ensureDedicatedPlayer(forScreenID: "screen-a", path: url.path)
        view.player = original
        defer {
            view.player = nil
            model.stopAllDedicatedPlayers()
            cache.cancelActiveGeneration()
            cache.flushMetadataImmediately()
            model.windows = []
            model.playerViews = []
            window.close()
        }
        cache.initializationState = .idle
        cache.ensureInitialized()
        try await waitUntil(timeout: 40) { model.lightweightProxyState == .ready }
        let replacement = try XCTUnwrap(model.dedicatedSlotsByScreenID["screen-a"]?[url.path]?
            .player)
        XCTAssertFalse(replacement === original)
        XCTAssertTrue(view.player === replacement)
        XCTAssertTrue(view.playerLayer.player === replacement)
        try await waitUntil { self.assetURL(replacement) == cache.cachedProxyURL(for: url.path) }
    }
}

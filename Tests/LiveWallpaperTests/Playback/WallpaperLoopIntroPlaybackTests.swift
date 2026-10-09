import AVFoundation
@testable import LiveWallpaper
import XCTest

/// 「途中からループする」の実測テスト。純関数(`introSeekSeconds`)だけでは、
/// この機能が過去2回落ちた場所 — **実際の `AVPlayerLooper` が継ぎ目で止まらずに
/// 回り続けるか** — をまったく検証できない。実ファイルを本番と同じ
/// `WallpaperLoopBuilder.makeLooper` で再生し、壁時計で観測する。
///
/// 検証する不変条件は2つ:
/// 1. 初回はカット開始位置から流れる(イントロ区間を実際に通る)。
/// 2. カット終了位置を跨いだ後もループ区間の中で再生位置が進み続ける
///    (= 継ぎ目で固まらない。過去2回の不具合はまさにここで止まっていた)。
@MainActor
final class WallpaperLoopIntroPlaybackTests: XCTestCase {
    private var fixtureDirectory: URL!
    private var videoURL: URL!

    /// Generated per run instead of reading the user's library: the library's directory
    /// order (and its contents) changes, and CI has no library at all, so these tests
    /// used to pick an arbitrary video locally and silently skip on CI.
    override func setUp() async throws {
        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallpaperLoopIntroPlaybackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        videoURL = fixtureDirectory.appendingPathComponent("fixture.mp4")
        try await Self.writeFixtureVideo(to: videoURL, seconds: 6, fps: 30)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fixtureDirectory)
    }

    private static func writeFixtureVideo(to url: URL, seconds: Int, fps: Int32) async throws {
        let size = 64
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size,
                AVVideoHeightKey: size,
                AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: Int(fps)],
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size,
                kCVPixelBufferHeightKey as String: size,
            ]
        )
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), "writer failed: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)

        let frameCount = seconds * Int(fps)
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let pool = try XCTUnwrap(adaptor.pixelBufferPool)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let pixelBuffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
            memset(base, Int32(frame % 256), CVPixelBufferGetDataSize(pixelBuffer))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "writer failed: \(String(describing: writer.error))")
    }

    /// 壁時計で `seconds` だけ待つ(その間メインループは回り続けるので、
    /// イントロシークのポーリングも番犬も普通に動く)。
    private func wait(seconds: TimeInterval) {
        let done = expectation(description: "waited \(seconds)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 2)
    }

    func testIntroPlaysFromTheCutStartThenKeepsLooping() throws {
        let asset = AVURLAsset(url: videoURL)

        let trimStart = 0.5
        let loopStart = 2.0
        let trimEnd = 3.0

        let player = AVQueuePlayer()
        player.isMuted = true
        let looper = WallpaperLoopBuilder.makeLooper(
            player: player,
            templateItem: AVPlayerItem(asset: asset),
            trimStart: trimStart,
            trimEnd: trimEnd,
            loopStart: loopStart,
            context: "test"
        )
        defer { looper.disableLooping() }
        player.play()

        // 1周目: イントロ区間(カット開始位置 ... ループ開始位置)を通っている。
        wait(seconds: 1.0)
        XCTAssertNotEqual(looper.status, .failed, "the loop itself must be alive")
        let intro = player.currentTime().seconds
        XCTAssertGreaterThanOrEqual(
            intro, trimStart - 0.2,
            "the first pass must start at the cut start, not at the loop start"
        )
        XCTAssertLessThan(
            intro, loopStart,
            "one second in, playback should still be inside the intro range"
        )

        // 継ぎ目を跨いだ後: ループ区間の中で進み続けている(止まっていない)。
        wait(seconds: 3.0)
        let afterSeam = player.currentTime().seconds
        XCTAssertGreaterThan(player.rate, 0, "playback must not have stopped at the seam")
        XCTAssertTrue(
            afterSeam >= loopStart - 0.2 && afterSeam <= trimEnd + 0.2,
            "after the seam playback must be inside the loop range, was \(afterSeam)"
        )

        // Not a multiple of the 1 s loop range: a full lap would land on the same playhead
        // and read as frozen.
        wait(seconds: 0.4)
        let later = player.currentTime().seconds
        XCTAssertNotEqual(
            later, afterSeam,
            accuracy: 0.01,
            "the playhead must keep advancing — a frozen playhead is the exact bug this feature had twice"
        )
        XCTAssertGreaterThan(looper.loopCount, 0, "the looper must have completed at least one lap")
    }

    /// ループ開始位置なし(= イントロなし)のときは、従来どおりカット開始位置から
    /// 素直にループする。イントロ経路を足したことで通常経路が壊れていないことの確認。
    func testPlainCutRangeStillLoopsWithoutAnIntro() throws {
        let asset = AVURLAsset(url: videoURL)

        let player = AVQueuePlayer()
        player.isMuted = true
        let looper = WallpaperLoopBuilder.makeLooper(
            player: player,
            templateItem: AVPlayerItem(asset: asset),
            trimStart: 1.0,
            trimEnd: 2.0,
            loopStart: nil,
            context: "test"
        )
        defer { looper.disableLooping() }
        player.play()

        wait(seconds: 2.5)
        XCTAssertNotEqual(looper.status, .failed)
        XCTAssertGreaterThan(player.rate, 0)
        let time = player.currentTime().seconds
        XCTAssertTrue(
            time >= 0.8 && time <= 2.2,
            "playback must stay inside the cut range, was \(time)"
        )
    }
}

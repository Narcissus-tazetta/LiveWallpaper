import AVFoundation
@testable import LiveWallpaper
import XCTest

/// `loopTimeRange` / `introSeekSeconds` の算出を検証する。ループ区間は
/// 「ループ開始位置 ... カット終了位置」(未指定ならカット開始位置から)、
/// ループ開始位置があるときだけ初回はカット開始位置から流す(イントロ)。
///
/// 最重要の不変条件は「終端を確定できないときに timeRange を作らないこと」。
/// 実測(AVFoundation)では、実尺をはみ出す timeRange
/// (`.positiveInfinity` を含む)を渡した AVPlayerLooper は
/// `-11838 "Loop range must be within [0, item duration]"` で `.failed` になり、
/// キューにアイテムを1つも入れない = 再生が始まらず直前のフレームで止まる。
final class WallpaperLoopBuilderTests: XCTestCase {
    func testLoopSpansTheCutRange() throws {
        let range = try XCTUnwrap(
            WallpaperLoopBuilder.loopTimeRange(trimStart: 5, trimEnd: 60)
        )
        XCTAssertEqual(range.start.seconds, 5, accuracy: 0.001)
        XCTAssertEqual(range.end.seconds, 60, accuracy: 0.001)
    }

    func testNoRangeWhenTrimEndIsUnknown() {
        XCTAssertNil(
            WallpaperLoopBuilder.loopTimeRange(trimStart: 5, trimEnd: nil),
            "an open-ended range would make AVPlayerLooper fail (-11838) and play nothing; " +
                "the caller must fall back to a whole-asset loop instead"
        )
    }

    func testNoRangeWhenTrimEndIsNotAfterTrimStart() {
        XCTAssertNil(WallpaperLoopBuilder.loopTimeRange(trimStart: 5, trimEnd: 5))
        XCTAssertNil(WallpaperLoopBuilder.loopTimeRange(trimStart: 5, trimEnd: 3))
    }

    // MARK: - 途中ループ(ループ開始位置 + イントロ)

    func testLoopStartsFromTheCustomLoopStartWhenSet() throws {
        let range = try XCTUnwrap(
            WallpaperLoopBuilder.loopTimeRange(trimStart: 5, trimEnd: 60, loopStart: 20)
        )
        XCTAssertEqual(range.start.seconds, 20, accuracy: 0.001)
        XCTAssertEqual(range.end.seconds, 60, accuracy: 0.001)
    }

    func testOutOfRangeLoopStartFallsBackToTheCutStart() throws {
        // 壊れた保存データでも「ループしない」より「イントロが無いだけ」を選ぶ。
        let tooEarly = try XCTUnwrap(
            WallpaperLoopBuilder.loopTimeRange(trimStart: 5, trimEnd: 60, loopStart: 1)
        )
        XCTAssertEqual(tooEarly.start.seconds, 5, accuracy: 0.001)

        let tooLate = try XCTUnwrap(
            WallpaperLoopBuilder.loopTimeRange(trimStart: 5, trimEnd: 60, loopStart: 60)
        )
        XCTAssertEqual(tooLate.start.seconds, 5, accuracy: 0.001)
    }

    func testIntroStartsAtTheCutStartWhenALoopStartIsSet() {
        XCTAssertEqual(
            WallpaperLoopBuilder.introSeekSeconds(trimStart: 5, trimEnd: 60, loopStart: 20),
            5
        )
    }

    func testNoIntroWithoutACustomLoopStart() {
        XCTAssertNil(
            WallpaperLoopBuilder.introSeekSeconds(trimStart: 5, trimEnd: 60, loopStart: nil)
        )
    }

    func testNoIntroWhenTheLoopStartIsEffectivelyTheCutStart() {
        XCTAssertNil(
            WallpaperLoopBuilder.introSeekSeconds(trimStart: 5, trimEnd: 60, loopStart: 5.01),
            "a sub-tick lead-in is not worth a seek"
        )
    }

    func testNoIntroWhenNoRangeCanBeBuilt() {
        XCTAssertNil(
            WallpaperLoopBuilder.introSeekSeconds(trimStart: 5, trimEnd: nil, loopStart: 20),
            "without a range the looper runs the whole asset; there is no loop to introduce"
        )
    }

    func testNoIntroWhenTheLoopStartIsOutOfRange() {
        XCTAssertNil(
            WallpaperLoopBuilder.introSeekSeconds(trimStart: 5, trimEnd: 60, loopStart: 99),
            "an out-of-range loop start falls back to the cut start, so there is nothing to play first"
        )
    }

    // MARK: - 復元シークの丸め

    //
    // 「別の壁紙に切り替えて戻したら、トリムしたはずの最後の部分で止まる」不具合の
    // 再発防止。専用プレイヤー/deep suspend/軽量プロキシの復元シークが、トリムで
    // 捨てた領域の位置を覚えたまま seek してループ区間の外へ出ていたのが原因。

    func testResumeInsideLoopRangeIsKept() {
        XCTAssertEqual(
            WallpaperLoopBuilder.clampedResumeSeconds(
                30,
                trimStart: 5,
                trimEnd: 60,
                itemDurationSeconds: 120
            ),
            30
        )
    }

    func testResumeInsideTheIntroRangeIsKept() {
        // イントロ区間(カット開始位置 ... ループ開始位置)も再生される領域なので、
        // そこへ戻すのは正しい。カット終了位置まで進めば通常どおりループに入る。
        XCTAssertEqual(
            WallpaperLoopBuilder.clampedResumeSeconds(
                8,
                trimStart: 5,
                trimEnd: 60,
                itemDurationSeconds: 120
            ),
            8
        )
    }

    func testResumeAfterTrimEndIsRejected() {
        XCTAssertNil(
            WallpaperLoopBuilder.clampedResumeSeconds(
                90,
                trimStart: 5,
                trimEnd: 60,
                itemDurationSeconds: 120
            ),
            "a position past the cut must not be restored — seeking there leaves the loop"
        )
    }

    func testResumeBeforeTrimStartIsRejected() {
        XCTAssertNil(
            WallpaperLoopBuilder.clampedResumeSeconds(
                2,
                trimStart: 5,
                trimEnd: 60,
                itemDurationSeconds: 120
            ),
            "the looper already starts at trimStart; seeking behind it leaves the loop"
        )
    }

    func testResumeAtTheVerySeamIsRejected() {
        XCTAssertNil(
            WallpaperLoopBuilder.clampedResumeSeconds(
                60,
                trimStart: 5,
                trimEnd: 60,
                itemDurationSeconds: 120
            )
        )
    }

    func testResumeIsBoundedByAssetDurationWhenTrimEndIsUnknown() {
        XCTAssertNil(
            WallpaperLoopBuilder.clampedResumeSeconds(
                120,
                trimStart: 5,
                trimEnd: nil,
                itemDurationSeconds: 120
            ),
            "the very end of the asset is the loop seam — restoring there is pointless"
        )
        XCTAssertEqual(
            WallpaperLoopBuilder.clampedResumeSeconds(
                100,
                trimStart: 5,
                trimEnd: nil,
                itemDurationSeconds: 120
            ),
            100
        )
    }

    func testResumeWithUnknownDurationAndNoTrimEndIsKept() {
        XCTAssertEqual(
            WallpaperLoopBuilder.clampedResumeSeconds(
                100,
                trimStart: 5,
                trimEnd: nil,
                itemDurationSeconds: nil
            ),
            100
        )
    }

    func testMakeLooperProducesALooperReadyForTheGivenPlayer() {
        let player = AVQueuePlayer()
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent.mp4"))
        let looper = WallpaperLoopBuilder.makeLooper(
            player: player,
            templateItem: item,
            trimStart: 0,
            trimEnd: 30
        )
        XCTAssertEqual(
            looper.loopCount,
            0,
            "an active AVPlayerLooper reports 0 completed loops initially"
        )
        looper.disableLooping()
    }

    // MARK: - 実プレイヤーでの実測

    private func sampleVideoURL() -> URL? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LiveWallpaper/Videos")
        let files =
            (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
                ?? []
        return files.first { ["mp4", "mov"].contains($0.pathExtension.lowercased()) }
    }

    /// 実際の AVQueuePlayer + AVPlayerLooper で「区間がちゃんとループする」ことと
    /// 「trimEnd 未設定でも再生が止まらない」ことを実測する。純関数のテストだけでは、
    /// range の作り方が AVFoundation の受け付ける形かどうかを取りこぼす
    /// (実際に `.positiveInfinity` を渡していた実装がそれで再生不能になっていた)。
    @MainActor
    func testLooperActuallyLoopsAndNeverStalls() throws {
        guard let url = sampleVideoURL() else {
            throw XCTSkip("no sample video available in Videos dir")
        }

        func observe(trimStart: Double, trimEnd: Double?, seconds: Double) -> (
            status: AVPlayerLooper.Status, wraps: Int, advanced: Bool
        ) {
            let player = AVQueuePlayer()
            player.actionAtItemEnd = .none
            player.isMuted = true
            let item = AVPlayerItem(asset: AVURLAsset(url: url))
            let looper = WallpaperLoopBuilder.makeLooper(
                player: player,
                templateItem: item,
                trimStart: trimStart,
                trimEnd: trimEnd
            )
            player.play()
            var samples: [Double] = []
            var wraps = 0
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                let time = player.currentTime().seconds
                guard time.isFinite else { continue }
                if let last = samples.last, time < last - 0.15 {
                    wraps += 1
                }
                samples.append(time)
            }
            let advanced = (samples.max() ?? 0) - (samples.min() ?? 0) > 0.1
            let status = looper.status
            looper.disableLooping()
            player.pause()
            player.removeAllItems()
            return (status, wraps, advanced)
        }

        let cut = observe(trimStart: 0.5, trimEnd: 2.0, seconds: 5)
        XCTAssertNotEqual(cut.status, .failed, "a range inside the asset must be accepted")
        XCTAssertGreaterThan(cut.wraps, 0, "the cut range must loop, not play through once")

        let openEnded = observe(trimStart: 0.5, trimEnd: nil, seconds: 3)
        XCTAssertNotEqual(
            openEnded.status, .failed,
            "an unknown trimEnd must fall back to a whole-asset loop — a failed looper " +
                "enqueues nothing and the wallpaper freezes on its last frame"
        )
        XCTAssertTrue(openEnded.advanced, "playback must actually advance")
    }
}

@testable import LiveWallpaper
import XCTest

/// 編集内容を他の動画へコピーするときの作り直し。
///
/// はみ出した trimEnd をそのまま書き込むと、コピー先の壁紙は
/// `AVPlayerLooper` が `.failed` になって**一切再生されなくなる**。
/// 「収まらないならコピーしない」を必ず守る。
final class TrimEditCopyPlannerTests: XCTestCase {
    private let minimumSegment: Double = 0.5
    private let endGuard: Double = WallpaperLoopBuilder.loopEndGuard

    private func plan(
        _ source: WallpaperEditMetadata,
        targetDuration: Double
    ) -> WallpaperEditMetadata? {
        TrimEditCopyPlanner.plan(
            source: source,
            targetDuration: targetDuration,
            minimumSegment: minimumSegment,
            endGuard: endGuard
        )
    }

    func testCopiesUnchangedWhenItFits() {
        let source = WallpaperEditMetadata(trimStart: 5, trimEnd: 20, loopStart: 12)
        let result = plan(source, targetDuration: 60)

        XCTAssertEqual(result?.trimStart, 5)
        XCTAssertEqual(result?.trimEnd, 20)
        XCTAssertEqual(result?.loopStart, 12)
    }

    func testClampsTheEndInsideTheShorterTarget() {
        let source = WallpaperEditMetadata(trimStart: 5, trimEnd: 100, loopStart: nil)
        let result = plan(source, targetDuration: 30)

        XCTAssertEqual(result?.trimEnd ?? 0, 30 - endGuard, accuracy: 0.0001)
        XCTAssertNotNil(result?.trimEnd, "終端は必ず具体値にする(nilだと全体ループへ落ちる)")
    }

    func testFillsTheEndWhenTheSourceHasNone() {
        let source = WallpaperEditMetadata(trimStart: 2, trimEnd: nil, loopStart: nil)
        let result = plan(source, targetDuration: 30)

        XCTAssertEqual(result?.trimEnd ?? 0, 30 - endGuard, accuracy: 0.0001)
    }

    func testSkipsTargetsTooShortForTheCutStart() {
        let source = WallpaperEditMetadata(trimStart: 50, trimEnd: 60, loopStart: nil)
        XCTAssertNil(
            plan(source, targetDuration: 20),
            "カット開始位置がコピー先の尺を越えている動画は書き換えない"
        )
    }

    func testSkipsWhenTheRemainingRangeIsShorterThanTheMinimumSegment() {
        let source = WallpaperEditMetadata(trimStart: 9.8, trimEnd: 30, loopStart: nil)
        XCTAssertNil(plan(source, targetDuration: 10))
    }

    func testDropsALoopStartThatNoLongerFits() {
        let source = WallpaperEditMetadata(trimStart: 1, trimEnd: 50, loopStart: 40)
        let result = plan(source, targetDuration: 20)

        XCTAssertNotNil(result, "カット範囲だけでもコピーできるなら成功させる")
        XCTAssertNil(result?.loopStart, "収まらないループ開始位置は丸めずに捨てる")
    }

    func testSkipsWhenTheDurationIsUnknown() {
        let source = WallpaperEditMetadata(trimStart: 0, trimEnd: 10, loopStart: nil)
        XCTAssertNil(
            plan(source, targetDuration: 0),
            "尺が読めない動画は検証できないので触らない"
        )
    }

    func testPlannedResultIsAlwaysValid() {
        let source = WallpaperEditMetadata(trimStart: 3, trimEnd: 100, loopStart: 50)
        for targetDuration in stride(from: 4.0, through: 120.0, by: 1.0) {
            guard let result = plan(source, targetDuration: targetDuration) else {
                continue
            }
            XCTAssertTrue(
                result.isValid(assetDuration: targetDuration),
                "コピー結果は常に妥当でなければならない (duration=\(targetDuration))"
            )
        }
    }
}

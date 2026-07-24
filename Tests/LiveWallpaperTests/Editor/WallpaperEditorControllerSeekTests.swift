@testable import LiveWallpaper
import XCTest

/// setDraftTrimStart/End はどちらも同じように playheadTime と seekRequest を
/// 更新するべき、という不変条件を確認する。以前は setDraftTrimStart だけが
/// playheadTime を更新しており、trimEnd をドラッグしてもプレビューが追従しなかった。
@MainActor
final class WallpaperEditorControllerSeekTests: XCTestCase {
    private func makeController() -> WallpaperEditorController {
        let model = WallpaperModel()
        model.libraryVideoPaths = ["/a.mp4"]
        let controller = WallpaperEditorController(model: model)
        controller.activate()
        controller.selectVideo(path: "/a.mp4")
        controller.draft.assetDuration = 100
        return controller
    }

    func testSetDraftTrimStartMovesPlayheadAndIssuesSeek() {
        let controller = makeController()
        let previousSeek = controller.seekRequest

        controller.setDraftTrimStart(12)

        XCTAssertEqual(controller.draft.trimStart, 12)
        XCTAssertEqual(controller.playheadTime, 12)
        XCTAssertNotEqual(controller.seekRequest, previousSeek)
        XCTAssertEqual(controller.seekRequest?.time, 12)
    }

    func testSetDraftTrimEndMovesPlayheadToTrimEnd() {
        let controller = makeController()

        controller.setDraftTrimEnd(40)

        XCTAssertEqual(controller.draft.trimEnd, 40)
        XCTAssertEqual(
            controller.playheadTime, 40,
            "dragging the end handle should move the preview to the end handle, not leave it at trimStart"
        )
        XCTAssertEqual(controller.seekRequest?.time, 40)
    }

    func testSeekClampsToAssetDurationAndUpdatesPlayhead() {
        let controller = makeController()

        controller.seek(to: 999)

        XCTAssertEqual(controller.playheadTime, 100, "seek should clamp to the asset duration")
        XCTAssertEqual(controller.seekRequest?.time, 100)
    }

    func testEachSeekTokenIsUnique() {
        let controller = makeController()
        controller.setDraftTrimStart(5)
        let first = controller.seekRequest
        controller.setDraftTrimStart(5)
        let second = controller.seekRequest

        XCTAssertNotEqual(
            first?.id, second?.id,
            "two seeks to the same time must still produce distinct tokens so the preview player re-applies them"
        )
    }

    // MARK: - 保存時の trimEnd クランプ

    //
    // trimEnd が実尺以上のまま保存されると、再生側の AVPlayerLooper が
    // -11838 "Loop range must be within [0, item duration]" で .failed になり、
    // その壁紙が一切再生されない(直前のフレームで止まったように見える)。

    func testCommitFillsAndClampsTrimEndInsideTheAsset() {
        let controller = makeController()
        controller.setDraftTrimStart(10)

        controller.commit(path: "/a.mp4")

        let saved = controller.draft.trimEnd
        XCTAssertNotNil(saved, "an unset trimEnd must be filled in on save, not left open-ended")
        XCTAssertEqual(saved ?? 0, 100 - WallpaperLoopBuilder.loopEndGuard, accuracy: 0.0001)
        XCTAssertFalse(
            controller.isDraftDirty(path: "/a.mp4"),
            "the clamped value must be written back to the draft, or Save stays enabled forever"
        )
    }

    func testLoopSafeTrimEndIsNilBeforeTheDurationIsKnown() {
        var draft = WallpaperEditDraft(path: "/a.mp4", trimStart: 0, trimEnd: nil)
        draft.assetDuration = 0
        XCTAssertNil(draft.loopSafeTrimEnd)
    }

    // MARK: - 途中ループ(ループ開始位置)

    func testToggleCustomLoopStartSeedsTheMidpointOfTheCutRange() {
        let controller = makeController()
        controller.setDraftTrimStart(10)
        controller.setDraftTrimEnd(50)

        controller.toggleCustomLoopStart(true)

        XCTAssertEqual(controller.draft.loopStart, 30)
        XCTAssertTrue(controller.draft.hasCustomLoopStart)
    }

    func testLoopStartIsClampedInsideTheCutRange() {
        let controller = makeController()
        controller.setDraftTrimStart(10)
        controller.setDraftTrimEnd(50)

        controller.setDraftLoopStart(5)
        XCTAssertEqual(
            controller.draft.loopStart ?? 0,
            10 + WallpaperLoopBuilder.introMinimumLeadIn,
            accuracy: 0.0001,
            """
            カット開始位置ちょうどは許さない。同じ値だと保存時に \
            loopSafeLoopStart が捨ててしまい、「保存したのにチェックが外れる」 \
            という食い違いになる
            """
        )

        controller.setDraftLoopStart(999)
        XCTAssertEqual(
            controller.draft.loopStart ?? 0,
            50 - controller.minimumSegmentDuration,
            accuracy: 0.0001,
            "the loop must keep at least the minimum segment before the cut end"
        )
    }

    func testShrinkingTheCutEndPastTheLoopStartDropsIt() {
        let controller = makeController()
        controller.setDraftTrimEnd(50)
        controller.setDraftLoopStart(40)

        controller.setDraftTrimEnd(20)

        XCTAssertNil(
            controller.draft.loopStart,
            "a loop start swallowed by the new cut end must be dropped, not silently rounded"
        )
    }

    func testCommitPersistsTheLoopStartAndSettlesTheDraft() {
        let controller = makeController()
        controller.setDraftTrimStart(10)
        controller.setDraftTrimEnd(50)
        controller.setDraftLoopStart(30)

        controller.commit(path: "/a.mp4")

        XCTAssertEqual(controller.draft.loopStart, 30)
        XCTAssertFalse(controller.isDraftDirty(path: "/a.mp4"))
    }

    func testCommitDropsALoopStartThatCannotFitInsideTheCutRange() {
        var draft = WallpaperEditDraft(path: "/a.mp4", trimStart: 0, trimEnd: 10, loopStart: 9.9)
        draft.assetDuration = 100
        XCTAssertNil(draft.loopSafeLoopStart(minimumSegment: 0.5))
    }
}

@testable import LiveWallpaper
import XCTest

/// キーボード操作・Undo・ズーム・書き出し範囲まわりの不変条件。
@MainActor
final class WallpaperEditorInteractionTests: XCTestCase {
    private func makeController(duration: Double = 100) -> WallpaperEditorController {
        let model = WallpaperModel()
        model.libraryVideoPaths = ["/a.mp4"]
        let controller = WallpaperEditorController(model: model)
        controller.activate()
        controller.selectVideo(path: "/a.mp4")
        controller.draft.assetDuration = duration
        controller.draft.frameRate = 30
        controller.resetTimelineWindow()
        return controller
    }

    // MARK: - 再生位置からハンドルを置く

    func testSettingTheCutStartFromThePlayhead() {
        let controller = makeController()
        controller.seek(to: 12.5)

        controller.setTrimStartToPlayhead()

        XCTAssertEqual(controller.draft.trimStart, 12.5)
    }

    func testSettingTheCutEndFromThePlayhead() {
        let controller = makeController()
        controller.seek(to: 40)

        controller.setTrimEndToPlayhead()

        XCTAssertEqual(controller.draft.trimEnd, 40)
    }

    func testFrameStepUsesTheRealFrameRate() {
        let controller = makeController()
        controller.draft.frameRate = 60
        controller.seek(to: 10)

        controller.stepPlayhead(byFrames: 1)

        XCTAssertEqual(controller.playheadTime, 10 + 1.0 / 60.0, accuracy: 0.0001)
        XCTAssertFalse(
            controller.isPreviewPlaying,
            "1コマ送りしたのに再生が続いていては、送った先を確認できない"
        )
    }

    func testFrameStepFallsBackToASaneRateWhenUnknown() {
        let controller = makeController()
        controller.draft.frameRate = 0
        controller.seek(to: 10)

        controller.stepPlayhead(byFrames: 1)

        XCTAssertEqual(controller.playheadTime, 10 + 1.0 / 30.0, accuracy: 0.0001)
    }

    func testPlayheadStepsAreClampedToTheAsset() {
        let controller = makeController()
        controller.seek(to: 0)
        controller.stepPlayhead(bySeconds: -5)
        XCTAssertEqual(controller.playheadTime, 0)

        controller.seek(to: 100)
        controller.stepPlayhead(bySeconds: 5)
        XCTAssertEqual(controller.playheadTime, 100)
    }

    // MARK: - Undo / Redo

    func testUndoRestoresThePreviousCut() {
        let controller = makeController()
        controller.setDraftTrimStart(10)
        controller.endInteractiveEdit()
        controller.setDraftTrimStart(30)

        XCTAssertTrue(controller.canUndo)
        controller.undo()

        XCTAssertEqual(controller.draft.trimStart, 10)
        XCTAssertTrue(controller.canRedo)
        controller.redo()
        XCTAssertEqual(controller.draft.trimStart, 30)
    }

    func testOneDragCollapsesIntoOneUndoStep() {
        let controller = makeController()
        // ドラッグ相当: 区切りを入れずに連続で更新する。
        for value in stride(from: 1.0, through: 20.0, by: 1.0) {
            controller.setDraftTrimStart(value)
        }
        controller.endInteractiveEdit()

        controller.undo()

        XCTAssertEqual(
            controller.draft.trimStart, 0,
            "1回のドラッグは⌘Z 1回でまとめて戻る"
        )
        XCTAssertFalse(controller.canUndo)
    }

    func testNoOpEditsAreNotRecorded() {
        let controller = makeController()
        controller.setDraftTrimStart(10)
        controller.endInteractiveEdit()
        // 端でクランプされ続けるドラッグ(値が動かない)
        controller.setDraftTrimStart(-5)
        controller.setDraftTrimStart(-9)
        controller.endInteractiveEdit()

        controller.undo()
        XCTAssertEqual(controller.draft.trimStart, 10, "0へのクランプは1手として積まれる")
        controller.undo()
        XCTAssertEqual(controller.draft.trimStart, 0)
        XCTAssertFalse(controller.canUndo, "値が動かない呼び出しは履歴を汚さない")
    }

    func testLoadingAnotherVideoClearsTheHistory() {
        let controller = makeController()
        controller.setDraftTrimStart(10)
        XCTAssertTrue(controller.canUndo)

        controller.loadDraft(path: "/a.mp4")

        XCTAssertFalse(controller.canUndo, "別の内容を読み込んだ後に前の動画の履歴は使えない")
    }

    // MARK: - 保存で値が動かないこと

    func testCutEndStaysPutAcrossSave() {
        let controller = makeController()
        let shownBeforeSave = controller.draft.effectiveTrimEnd

        controller.commit(path: "/a.mp4")

        XCTAssertEqual(
            controller.draft.effectiveTrimEnd, shownBeforeSave,
            accuracy: 0.0001,
            "保存した瞬間に終了時刻の表示が動いてはいけない"
        )
        XCTAssertFalse(controller.isDraftDirty(path: "/a.mp4"))
    }

    func testDraggingTheEndCannotExceedTheGuardedMaximum() {
        let controller = makeController()
        controller.setDraftTrimEnd(999)

        XCTAssertEqual(
            controller.draft.trimEnd ?? 0,
            100 - WallpaperLoopBuilder.loopEndGuard,
            accuracy: 0.0001
        )
    }

    // MARK: - ループ開始位置

    func testLoopStartCreatedInTheUIAlwaysSurvivesSaving() {
        let controller = makeController()
        controller.setDraftTrimEnd(50)
        controller.toggleCustomLoopStart(true)
        // カット開始位置ちょうどへ寄せようとしても、保存できる下限で止まる。
        controller.setDraftLoopStart(0)
        XCTAssertTrue(controller.draft.hasCustomLoopStart)

        controller.commit(path: "/a.mp4")

        XCTAssertTrue(
            controller.draft.hasCustomLoopStart,
            "UIで作れる値は必ず保存できる値でなければならない"
        )
        XCTAssertNotNil(controller.model.wallpaperEdit(for: "/a.mp4")?.loopStart)
    }

    // MARK: - リセット

    func testResetMovesThePreviewBackToTheStart() {
        let controller = makeController()
        controller.setDraftTrimStart(30)
        let before = controller.seekRequest

        controller.resetDraft()

        XCTAssertEqual(controller.playheadTime, 0)
        XCTAssertNotEqual(controller.seekRequest, before, "リセットはプレビューにも反映する")
        XCTAssertEqual(controller.seekRequest?.time, 0)
    }

    // MARK: - ズーム

    func testZoomToSelectionFramesTheCutRange() {
        let controller = makeController()
        controller.setDraftTrimStart(40)
        controller.setDraftTrimEnd(50)

        controller.zoomTimelineToSelection()

        XCTAssertTrue(controller.timelineWindow.contains(40))
        XCTAssertTrue(controller.timelineWindow.contains(50))
        XCTAssertLessThan(controller.timelineWindow.duration, 100)
        XCTAssertTrue(controller.canZoomOut)
    }

    func testZoomToFullRestoresTheWholeAsset() {
        let controller = makeController()
        controller.zoomTimeline(by: 8)
        XCTAssertTrue(controller.canZoomOut)

        controller.zoomTimelineToFull()

        XCTAssertFalse(controller.canZoomOut)
        XCTAssertEqual(controller.timelineWindow.duration, 100)
    }

    func testPlaybackScrollsTheZoomedTimeline() {
        let controller = makeController()
        controller.seek(to: 0)
        controller.zoomTimeline(by: 10, anchor: 0)
        XCTAssertFalse(controller.timelineWindow.contains(80))

        // 再生が進んで窓の外へ出た
        controller.playheadTime = 80

        XCTAssertTrue(
            controller.timelineWindow.contains(80),
            "拡大中は再生位置を追いかけないと、何も動いていないように見える"
        )
    }

    func testKeyframeSnappingIsOffWhenThereIsNoIndex() {
        let controller = makeController()
        controller.snapsToKeyframes = true

        XCTAssertEqual(controller.snappedToKeyframe(12.34), 12.34, accuracy: 0.0001)
    }

    // MARK: - 書き出し範囲

    func testExportRangeMatchesTheCut() {
        let range = WallpaperTrimExporter.makeTimeRange(
            trimStart: 10,
            trimEnd: 25,
            assetDuration: 100
        )

        XCTAssertEqual(range?.start.seconds ?? 0, 10, accuracy: 0.0001)
        XCTAssertEqual(range?.duration.seconds ?? 0, 15, accuracy: 0.0001)
    }

    func testExportRangeFallsBackToTheWholeAssetWhenTheEndIsUnset() {
        let range = WallpaperTrimExporter.makeTimeRange(
            trimStart: 0,
            trimEnd: nil,
            assetDuration: 42
        )

        XCTAssertEqual(range?.duration.seconds ?? 0, 42, accuracy: 0.0001)
    }

    func testExportRangeIsNilWhenEmpty() {
        XCTAssertNil(
            WallpaperTrimExporter.makeTimeRange(trimStart: 10, trimEnd: 10, assetDuration: 100)
        )
        XCTAssertNil(
            WallpaperTrimExporter.makeTimeRange(trimStart: 0, trimEnd: 10, assetDuration: 0)
        )
    }

    func testExportFileNameIsDistinctFromTheSource() {
        let name = WallpaperTrimExporter.suggestedFileName(
            sourcePath: "/tmp/ocean.mov",
            fileExtension: "mp4"
        )
        XCTAssertEqual(name, "ocean-trimmed.mp4")
    }
}

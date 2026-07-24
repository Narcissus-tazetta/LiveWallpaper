@testable import LiveWallpaper
import XCTest

/// 未保存のトリム編集が黙って消えないことを守るテスト。
///
/// かつては `activate()` と `handleCurrentVideoPathChange()` が、選択中の動画が
/// 変わっていなくても無条件に保存済みの値を読み直していた。実際に踏む経路が
/// 2つあり、どちらもユーザーには「編集が勝手に消えた」としか見えない:
/// - 編集途中で別タブへ行って戻る(タブ切り替えで activate される)
/// - スケジュール/集中モードが壁紙を自動で切り替える(currentVideoPath が変わる)
@MainActor
final class WallpaperEditorDraftPreservationTests: XCTestCase {
    private func makeController() -> WallpaperEditorController {
        let model = WallpaperModel()
        model.libraryVideoPaths = ["/a.mp4", "/b.mp4"]
        let controller = WallpaperEditorController(model: model)
        controller.activate()
        controller.selectVideo(path: "/a.mp4")
        controller.draft.assetDuration = 100
        return controller
    }

    func testReactivatingTheTabKeepsUnsavedEdits() {
        let controller = makeController()
        controller.setDraftTrimStart(10)
        controller.setDraftTrimEnd(50)

        controller.deactivate()
        controller.activate()

        XCTAssertEqual(controller.draft.trimStart, 10)
        XCTAssertEqual(controller.draft.trimEnd, 50)
        XCTAssertTrue(controller.isDraftDirty(path: "/a.mp4"))
    }

    func testExternalWallpaperSwitchKeepsUnsavedEdits() {
        let controller = makeController()
        controller.setDraftTrimStart(10)
        controller.setDraftTrimEnd(50)

        controller.handleCurrentVideoPathChange()

        XCTAssertEqual(
            controller.draft.trimStart, 10,
            "スケジュールや集中モードが壁紙を切り替えただけで編集を捨ててはいけない"
        )
        XCTAssertEqual(controller.draft.trimEnd, 50)
    }

    func testDiscardingChangesStillReloadsSavedValues() {
        let controller = makeController()
        controller.setDraftTrimStart(10)
        controller.setDraftTrimEnd(50)

        controller.discardDraftChanges(path: "/a.mp4")

        XCTAssertEqual(controller.draft.trimStart, 0, "「変更を破棄」は明示操作なので必ず読み直す")
        XCTAssertNil(controller.draft.trimEnd)
    }

    func testSwitchingVideosWithUnsavedEditsAsksFirst() {
        let controller = makeController()
        controller.setDraftTrimStart(10)

        let switched = controller.requestSelectVideo(path: "/b.mp4")

        XCTAssertFalse(switched, "未保存なら即座に切り替えない")
        XCTAssertEqual(controller.pendingSelectionPath, "/b.mp4")
        XCTAssertEqual(controller.draft.path, "/a.mp4", "確認が済むまで編集対象は変わらない")
        XCTAssertEqual(controller.draft.trimStart, 10)
    }

    func testSwitchingVideosWithoutChangesDoesNotAsk() {
        let controller = makeController()

        let switched = controller.requestSelectVideo(path: "/b.mp4")

        XCTAssertTrue(switched)
        XCTAssertNil(controller.pendingSelectionPath)
        XCTAssertEqual(controller.draft.path, "/b.mp4")
    }

    func testConfirmingWithSaveKeepsTheEditOnTheOriginalVideo() {
        let controller = makeController()
        controller.setDraftTrimStart(10)
        controller.setDraftTrimEnd(50)
        _ = controller.requestSelectVideo(path: "/b.mp4")

        controller.confirmPendingSelection(savingFirst: true)

        XCTAssertNil(controller.pendingSelectionPath)
        XCTAssertEqual(controller.draft.path, "/b.mp4")
        let saved = controller.model.wallpaperEdit(for: "/a.mp4")
        XCTAssertEqual(saved?.trimStart, 10, "「保存して切り替える」は元の動画へ保存してから移る")
        XCTAssertEqual(saved?.trimEnd, 50)
    }

    func testCancellingKeepsEverything() {
        let controller = makeController()
        controller.setDraftTrimStart(10)
        _ = controller.requestSelectVideo(path: "/b.mp4")

        controller.cancelPendingSelection()

        XCTAssertNil(controller.pendingSelectionPath)
        XCTAssertEqual(controller.draft.path, "/a.mp4")
        XCTAssertEqual(controller.draft.trimStart, 10)
        XCTAssertNil(controller.model.wallpaperEdit(for: "/a.mp4"))
    }

    func testMissingVideoDropsTheDraftEvenIfUnsaved() {
        let controller = makeController()
        controller.setDraftTrimStart(10)

        controller.model.libraryVideoPaths = ["/b.mp4"]
        controller.pruneMissing(validPaths: ["/b.mp4"])

        XCTAssertEqual(
            controller.draft.path, "/b.mp4",
            "消えた動画のドラフトは「未保存だから残す」対象ではない"
        )
    }
}

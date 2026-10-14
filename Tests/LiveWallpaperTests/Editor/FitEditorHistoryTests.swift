@testable import LiveWallpaper
import XCTest

@MainActor
final class FitEditorHistoryTests: XCTestCase {
    private let path = "/tmp/FitEditorHistoryTests/video.mp4"
    private var model: WallpaperModel!
    private var editor: FitEditorController!

    override func setUp() {
        model = WallpaperModel()
        editor = FitEditorController(model: model)
    }

    override func tearDown() {
        model.clearWallpaperPresentation(path: path, screenID: "A")
    }

    func testOneDragIsOneStepAndTheNextDragIsAnother() {
        for zoom in [1.2, 1.4, 1.6] {
            editor.setDraftZoom(zoom, path: path, screenID: "A")
        }
        editor.breakDraftHistoryCoalescing()
        for zoom in [1.8, 2.0] {
            editor.setDraftZoom(zoom, path: path, screenID: "A")
        }

        editor.undoDraft(path: path, screenID: "A")
        XCTAssertEqual(editor.zoom(path: path, screenID: "A"), 1.6)
        editor.undoDraft(path: path, screenID: "A")
        XCTAssertEqual(editor.zoom(path: path, screenID: "A"), 1.0)
        XCTAssertFalse(editor.canUndoDraft(path: path, screenID: "A"))

        editor.redoDraft(path: path, screenID: "A")
        XCTAssertEqual(editor.zoom(path: path, screenID: "A"), 1.6)
    }

    func testResetIsItsOwnStepEvenRightAfterADrag() {
        editor.setDraftZoom(1.5, path: path, screenID: "A")
        editor.resetDraft(path: path, screenID: "A")

        editor.undoDraft(path: path, screenID: "A")
        XCTAssertEqual(editor.zoom(path: path, screenID: "A"), 1.5)
    }

    func testUndoChangesOnlyTheDraftNotTheSavedSettings() {
        editor.setDraftZoom(1.5, path: path, screenID: "A")
        editor.applyDraft(path: path, screenID: "A", showFeedback: false)

        editor.undoDraft(path: path, screenID: "A")
        XCTAssertEqual(editor.zoom(path: path, screenID: "A"), 1.0)
        XCTAssertEqual(model.wallpaperZoom(path: path, screenID: "A"), 1.5)
        XCTAssertTrue(editor.isDraftDirty(path: path, screenID: "A"))
    }

    func testEachScreenKeepsItsOwnHistory() {
        editor.setDraftZoom(1.5, path: path, screenID: "A")
        editor.setDraftZoom(2.0, path: path, screenID: "B")
        XCTAssertTrue(editor.canUndoDraft(path: path, screenID: "A"))

        editor.undoDraft(path: path, screenID: "A")
        XCTAssertEqual(editor.zoom(path: path, screenID: "A"), 1.0)
        XCTAssertTrue(editor.canUndoDraft(path: path, screenID: "B"))
    }

    func testADragSnapsToTheCentreAndLeavesItWhenMovingOn() {
        // Zoomed in, so both axes have room to pan and offsets are kept.
        editor.setDraftZoom(3, path: path, screenID: "A")
        let near = CGSize(width: 0.05, height: 0.05)
        editor.dragDraftOffset(dx: 0.5, dy: 0, snapDistance: near, snaps: true, path: path, screenID: "A")
        editor.endDraftDrag()
        editor.dragDraftOffset(dx: -0.47, dy: 0, snapDistance: near, snaps: true, path: path, screenID: "A")
        XCTAssertEqual(editor.offsetX(path: path, screenID: "A"), 0)
        XCTAssertTrue(editor.snappedAxes.x)
        // The pointer keeps its own place: 0.03 - 0.1 is past the centre's pull.
        editor.dragDraftOffset(dx: -0.1, dy: 0, snapDistance: near, snaps: true, path: path, screenID: "A")
        XCTAssertEqual(editor.offsetX(path: path, screenID: "A"), -0.07, accuracy: 1e-9)
        XCTAssertFalse(editor.snappedAxes.x)
        editor.endDraftDrag()
        XCTAssertEqual(editor.snappedAxes, FitSnappedAxes())
    }

    func testADragWithSnappingOffStopsWhereThePointerIs() {
        editor.setDraftZoom(3, path: path, screenID: "A")
        editor.dragDraftOffset(
            dx: 0.02, dy: 0, snapDistance: CGSize(width: 0.05, height: 0.05), snaps: false, path: path, screenID: "A"
        )
        XCTAssertEqual(editor.offsetX(path: path, screenID: "A"), 0.02, accuracy: 1e-9)
        XCTAssertFalse(editor.snappedAxes.x)
    }
}

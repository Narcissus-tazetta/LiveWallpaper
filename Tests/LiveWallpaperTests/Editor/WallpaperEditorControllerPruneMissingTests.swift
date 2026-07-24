import XCTest

@testable import LiveWallpaper

/// pruneMissing が、選択中の動画がライブラリから消えたときに draft も破棄することを
/// 確認する。以前は selectedVideoPath だけ nil にして draft を放置していたため、
/// トリムパネルのヘッダー/プレビューは新しく解決された動画を指す一方、スクラバーは
/// 削除済みの動画の古い尺・トリム範囲を表示し続けてしまっていた。
@MainActor
final class WallpaperEditorControllerPruneMissingTests: XCTestCase {
    func testPruneMissingResyncsDraftAwayFromDeletedVideo() {
        let model = WallpaperModel()
        model.libraryVideoPaths = ["/a.mp4", "/b.mp4"]
        let controller = WallpaperEditorController(model: model)
        controller.activate()
        controller.selectVideo(path: "/a.mp4")
        XCTAssertEqual(controller.draft.path, "/a.mp4")

        // 実際の呼び出し元(MediaLibrary.swift)は model.libraryVideoPaths が
        // 変わった直後に、その同じ集合を validPaths として渡す。
        model.libraryVideoPaths = ["/b.mp4"]
        controller.pruneMissing(validPaths: ["/b.mp4"])

        XCTAssertNotEqual(
            controller.draft.path, "/a.mp4",
            "the draft must not keep pointing at a video that no longer exists"
        )
        XCTAssertEqual(
            controller.draft.path, "/b.mp4",
            "the draft should resync to whatever resolvedVideoPath() now falls back to"
        )
    }

    func testPruneMissingClearsDraftWhenNoVideosRemain() {
        let model = WallpaperModel()
        model.libraryVideoPaths = ["/a.mp4"]
        let controller = WallpaperEditorController(model: model)
        controller.activate()
        controller.selectVideo(path: "/a.mp4")

        model.libraryVideoPaths = []
        controller.pruneMissing(validPaths: [])

        XCTAssertEqual(controller.draft.path, "")
        XCTAssertNil(controller.selectedVideoPath)
    }

    func testPruneMissingLeavesDraftAloneWhenStillValid() {
        let model = WallpaperModel()
        model.libraryVideoPaths = ["/a.mp4", "/b.mp4"]
        let controller = WallpaperEditorController(model: model)
        controller.activate()
        controller.selectVideo(path: "/a.mp4")

        controller.pruneMissing(validPaths: ["/a.mp4", "/b.mp4"])

        XCTAssertEqual(controller.draft.path, "/a.mp4")
        XCTAssertEqual(controller.selectedVideoPath, "/a.mp4")
    }
}

import XCTest

@testable import LiveWallpaper

@MainActor
final class RestoredPathPruningTests: XCTestCase {
    func testCurrentPathIsPrunedLast() {
        let ordered = WallpaperModel.orderedMissingPathsForPruning(
            ["/a.mp4", "/current.mp4", "/b.mp4"],
            currentPath: "/current.mp4"
        )
        XCTAssertEqual(ordered, ["/a.mp4", "/b.mp4", "/current.mp4"])
    }

    func testOrderIsOtherwisePreserved() {
        let ordered = WallpaperModel.orderedMissingPathsForPruning(
            ["/a.mp4", "/b.mp4", "/c.mp4"],
            currentPath: "/playing.mp4"
        )
        XCTAssertEqual(ordered, ["/a.mp4", "/b.mp4", "/c.mp4"])
    }

    func testNoCurrentPathKeepsEveryEntry() {
        let ordered = WallpaperModel.orderedMissingPathsForPruning(
            ["/a.mp4", "/b.mp4"],
            currentPath: nil
        )
        XCTAssertEqual(ordered, ["/a.mp4", "/b.mp4"])
    }

    /// 再生中の動画しか欠損していない場合も落とさない(1件だけ処理される)。
    func testCurrentPathOnly() {
        let ordered = WallpaperModel.orderedMissingPathsForPruning(
            ["/current.mp4"],
            currentPath: "/current.mp4"
        )
        XCTAssertEqual(ordered, ["/current.mp4"])
    }

    func testEmptyInput() {
        XCTAssertEqual(
            WallpaperModel.orderedMissingPathsForPruning([], currentPath: "/current.mp4"),
            []
        )
    }
}

import XCTest
@testable import LiveWallpaper

@MainActor
final class WindowRefreshPolicyTests: XCTestCase {
    func testActiveSpaceRefreshDoesNotAllowReorder() {
        XCTAssertFalse(
            WallpaperModel.allowsWindowReorder(for: .activeSpaceTransition)
        )
    }

    func testFinderRestartRefreshAllowsReorder() {
        XCTAssertTrue(
            WallpaperModel.allowsWindowReorder(for: .finderRestart)
        )
    }

    func testRefreshDelaysDifferByReason() {
        XCTAssertEqual(
            WallpaperModel.refreshDelays(for: .activeSpaceTransition),
            [0.0]
        )
        XCTAssertEqual(
            WallpaperModel.refreshDelays(for: .finderRestart),
            [0.1, 0.35, 0.8, 1.6, 3.0]
        )
    }

    func testRebuildOrderingPolicyOnlyForNewWindows() {
        XCTAssertTrue(
            WallpaperModel.shouldReassertOrderingOnRebuild(isReusedWindow: false)
        )
        XCTAssertFalse(
            WallpaperModel.shouldReassertOrderingOnRebuild(isReusedWindow: true)
        )
    }
}

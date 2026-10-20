import XCTest

@testable import LiveWallpaper

/// The window list mirrors what CGWindowList returned on a real 1470×956 screen
/// (front to back): the menu bar, the Dock's full-screen transparent window, an app
/// window, a window-server strip under the menu bar, a desktop widget and Finder's
/// desktop.
final class DesktopClickDetectorTests: XCTestCase {
    private let finder: pid_t = 100
    private let dock: pid_t = 200
    private let app: pid_t = 300
    private let widgets: pid_t = 400
    private let own: pid_t = 500
    private let windowServer: pid_t = 600
    private let desktopLayer = DesktopClickDetector.desktopIconLayer

    private var windows: [OnScreenWindow] {
        [
            OnScreenWindow(ownerPID: windowServer, isWindowServer: true, layer: 24,
                           bounds: CGRect(x: 0, y: 0, width: 1470, height: 33), alpha: 1),
            OnScreenWindow(ownerPID: dock, isWindowServer: false, layer: 20,
                           bounds: CGRect(x: 0, y: 0, width: 1470, height: 956), alpha: 1),
            OnScreenWindow(ownerPID: app, isWindowServer: false, layer: 0,
                           bounds: CGRect(x: 138, y: 209, width: 600, height: 400), alpha: 1),
            OnScreenWindow(ownerPID: windowServer, isWindowServer: true, layer: desktopLayer + 1,
                           bounds: CGRect(x: 0, y: 0, width: 1470, height: 81), alpha: 1),
            OnScreenWindow(ownerPID: widgets, isWindowServer: false, layer: desktopLayer + 1,
                           bounds: CGRect(x: 1031, y: 176, width: 400, height: 300), alpha: 1),
            OnScreenWindow(ownerPID: finder, isWindowServer: false, layer: desktopLayer,
                           bounds: CGRect(x: 0, y: 0, width: 1470, height: 956), alpha: 1),
        ]
    }

    private func isDesktop(_ x: CGFloat, _ y: CGFloat, windows: [OnScreenWindow]? = nil) -> Bool {
        DesktopClickDetector.isDesktopClick(
            at: CGPoint(x: x, y: y), windows: windows ?? self.windows,
            finderPID: finder, dockPID: dock, ownPID: own
        )
    }

    func testEmptyDesktopCounts() {
        XCTAssertTrue(isDesktop(900, 800))
    }

    func testJustBelowTheMenuBarStillCounts() {
        XCTAssertTrue(isDesktop(900, 60))
    }

    func testAppWindowMenuBarAndWidgetsDoNot() {
        XCTAssertFalse(isDesktop(300, 300))
        XCTAssertFalse(isDesktop(900, 10))
        XCTAssertFalse(isDesktop(1100, 200))
    }

    func testPointerWindowIsLookedThrough() {
        var list = windows
        list.insert(OnScreenWindow(ownerPID: windowServer, isWindowServer: true, layer: DesktopClickDetector.cursorLayer,
                                   bounds: CGRect(x: 880, y: 780, width: 28, height: 40), alpha: 1), at: 0)
        XCTAssertTrue(isDesktop(900, 800, windows: list))
    }

    func testStageManagerOverlayIsLookedThroughButItsThumbnailsAreNot() {
        let windowManager: pid_t = 700
        var list = windows
        list.insert(OnScreenWindow(ownerPID: windowManager, isWindowServer: false, layer: 18,
                                   bounds: CGRect(x: 0, y: 0, width: 1470, height: 956), alpha: 1), at: 2)
        list.insert(OnScreenWindow(ownerPID: windowManager, isWindowServer: false, layer: 18,
                                   bounds: CGRect(x: 20, y: 200, width: 120, height: 90), alpha: 1), at: 2)
        func check(_ x: CGFloat, _ y: CGFloat) -> Bool {
            DesktopClickDetector.isDesktopClick(
                at: CGPoint(x: x, y: y), windows: list, finderPID: finder, dockPID: dock, ownPID: own,
                windowManagerPID: windowManager, screenSizes: [CGSize(width: 1470, height: 956)]
            )
        }
        XCTAssertTrue(check(900, 800))
        XCTAssertFalse(check(60, 240))
    }

    func testFinderWindowIsNotTheDesktop() {
        var list = windows
        list.insert(OnScreenWindow(ownerPID: finder, isWindowServer: false, layer: 0,
                                   bounds: CGRect(x: 800, y: 600, width: 300, height: 200), alpha: 1), at: 2)
        XCTAssertFalse(isDesktop(900, 700, windows: list))
    }

    func testInvisibleWindowsAreLookedThrough() {
        var list = windows
        list.insert(OnScreenWindow(ownerPID: app, isWindowServer: false, layer: 5,
                                   bounds: CGRect(x: 800, y: 600, width: 300, height: 200), alpha: 0), at: 0)
        list.insert(OnScreenWindow(ownerPID: app, isWindowServer: false, layer: 5,
                                   bounds: CGRect(x: 900, y: 700, width: 0, height: 0), alpha: 1), at: 0)
        XCTAssertTrue(isDesktop(900, 700, windows: list))
    }

    func testSecondDisplayDesktopCounts() {
        var list = windows
        list.append(OnScreenWindow(ownerPID: finder, isWindowServer: false, layer: desktopLayer,
                                   bounds: CGRect(x: 1470, y: 0, width: 1920, height: 1080), alpha: 1))
        XCTAssertTrue(isDesktop(2000, 500, windows: list))
        XCTAssertFalse(isDesktop(5000, 500, windows: list))
    }

    func testClickSettingsDefaultOffForOldSettings() throws {
        let settings = try JSONDecoder().decode(CursorEffectsSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(settings.clickEnabled)
        XCTAssertEqual(settings.clickStyle, .ripple)
        XCTAssertEqual(settings.clickColor, .white)
    }
}

import XCTest

@testable import LiveWallpaper

@MainActor
final class WindowBoundsAccessTests: XCTestCase {
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private func window(pid: Int32, bounds: CGRect?) -> [String: Any] {
        var info: [String: Any] = [kCGWindowOwnerPID as String: NSNumber(value: pid)]
        if let bounds {
            info[kCGWindowBounds as String] = bounds.dictionaryRepresentation
        }
        return info
    }

    func testAnotherAppsWindowWithBoundsMeansReadable() {
        let list = [
            window(pid: ownPID, bounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
            window(pid: ownPID + 1, bounds: CGRect(x: 0, y: 0, width: 800, height: 600)),
        ]
        XCTAssertTrue(WallpaperModel.otherAppWindowBoundsReadable(in: list))
    }

    /// Our own windows are always readable, so they prove nothing.
    func testOnlyOwnWindowsIsNotEnough() {
        let list = [window(pid: ownPID, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))]
        XCTAssertFalse(WallpaperModel.otherAppWindowBoundsReadable(in: list))
    }

    func testWithheldOrEmptyBoundsMeanUnreadable() {
        let list = [
            window(pid: ownPID + 1, bounds: nil),
            window(pid: ownPID + 2, bounds: .zero),
        ]
        XCTAssertFalse(WallpaperModel.otherAppWindowBoundsReadable(in: list))
    }
}

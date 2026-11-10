@testable import LiveWallpaper
import XCTest

@MainActor
final class AutoSwitchIntervalTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PrefsKey.autoSwitchIntervalMinutes)
        super.tearDown()
    }

    func testLargestImportedIntervalDoesNotCrashOnImportOrRelaunch() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("""
        {"formatVersion":1,"autoSwitchIntervalMinutes":\(Int.max)}
        """.utf8).write(to: file)
        let model = WallpaperModel()
        try SettingsTransfer.importSettings(from: file, into: model)
        XCTAssertEqual(model.autoSwitchIntervalMinutes, Int.max)
        let timer = try XCTUnwrap(model.autoSwitchTimer)
        XCTAssertTrue(timer.timeInterval.isFinite)
        XCTAssertEqual(timer.timeInterval, Double(Int.max) * 60)

        let relaunched = WallpaperModel()
        XCTAssertEqual(relaunched.autoSwitchIntervalMinutes, Int.max)
        XCTAssertNotNil(relaunched.autoSwitchTimer)
    }

    func testNormalIntervalAndDisablingItStillWork() throws {
        let model = WallpaperModel()
        model.setAutoSwitchInterval(minutes: 5)
        XCTAssertEqual(try XCTUnwrap(model.autoSwitchTimer).timeInterval, 300)
        model.setAutoSwitchInterval(minutes: 0)
        XCTAssertNil(model.autoSwitchTimer)
    }
}

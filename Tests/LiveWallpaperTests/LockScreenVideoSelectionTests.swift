import XCTest
@testable import LiveWallpaper

@MainActor
final class LockScreenVideoSelectionTests: XCTestCase {
    func testValidatedVideoPathReturnsNilForMissingFile() {
        XCTAssertNil(WallpaperModel.validatedVideoPath("/tmp/does-not-exist-\(UUID().uuidString).mov"))
    }

    func testValidatedVideoPathReturnsNilForEmptyString() {
        XCTAssertNil(WallpaperModel.validatedVideoPath(""))
        XCTAssertNil(WallpaperModel.validatedVideoPath("   "))
        XCTAssertNil(WallpaperModel.validatedVideoPath(nil))
    }

    func testValidatedVideoPathReturnsExistingFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lock-screen-test-\(UUID().uuidString).mov")
        try Data("test".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(WallpaperModel.validatedVideoPath(url.path), url.path)
    }

    func testMigrateLockScreenVideoPathCopiesDesktopOnFirstLaunch() throws {
        let migrationKey = "lockScreenVideoPathMigrated"
        let lockScreenKey = "lockScreenVideoPath"
        let videoKey = "videoPath"
        let previousMigration = UserDefaults.standard.object(forKey: migrationKey)
        let previousLockScreen = UserDefaults.standard.string(forKey: lockScreenKey)
        let previousVideo = UserDefaults.standard.string(forKey: videoKey)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lock-screen-migrate-\(UUID().uuidString).mov")
        try Data("test".utf8).write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            if let previousMigration {
                UserDefaults.standard.set(previousMigration, forKey: migrationKey)
            } else {
                UserDefaults.standard.removeObject(forKey: migrationKey)
            }
            if let previousLockScreen {
                UserDefaults.standard.set(previousLockScreen, forKey: lockScreenKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lockScreenKey)
            }
            if let previousVideo {
                UserDefaults.standard.set(previousVideo, forKey: videoKey)
            } else {
                UserDefaults.standard.removeObject(forKey: videoKey)
            }
        }

        let model = WallpaperModel()
        UserDefaults.standard.removeObject(forKey: migrationKey)
        UserDefaults.standard.removeObject(forKey: lockScreenKey)
        model.currentVideoPath = url.path
        model.restoreLockScreenVideoPath()
        XCTAssertEqual(model.lockScreenVideoPath, url.path)
        XCTAssertEqual(UserDefaults.standard.string(forKey: lockScreenKey), url.path)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: migrationKey))
    }
}

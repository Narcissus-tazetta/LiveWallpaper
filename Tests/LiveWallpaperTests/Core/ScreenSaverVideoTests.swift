@testable import LiveWallpaper
import XCTest

@MainActor
final class ScreenSaverVideoTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenSaverVideo-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: PrefsKey.screenSaverVideoPath)
        try FileManager.default.removeItem(at: directory)
    }

    private func video(_ name: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try Data("video".utf8).write(to: url)
        return url.path
    }

    func testAChosenVideoPlaysOnEveryDisplayInsteadOfTheDesktops() throws {
        let model = WallpaperModel()
        let desktop = try video("desktop.mp4")
        let chosen = try video("saver.mp4")
        model.currentVideoPath = desktop
        model.selectScreenSaverVideo(path: chosen)

        let config = model.makeScreenSaverConfig()
        XCTAssertEqual(config.fallback?.videoPath, chosen)
        XCTAssertTrue(config.displays.values.allSatisfy { $0.videoPath == chosen })
        XCTAssertEqual(UserDefaults.standard.string(forKey: PrefsKey.screenSaverVideoPath), chosen)

        model.useDesktopVideoForScreenSaver()
        XCTAssertEqual(model.makeScreenSaverConfig().fallback?.videoPath, desktop)
    }

    func testRemovingTheChosenVideoFallsBackToTheDesktop() throws {
        let model = WallpaperModel()
        let chosen = try video("saver.mp4")
        model.selectScreenSaverVideo(path: chosen)

        model.clearScreenSaverVideoIfMissing(path: chosen)

        XCTAssertNil(model.screenSaverVideoPath)
        XCTAssertNil(UserDefaults.standard.string(forKey: PrefsKey.screenSaverVideoPath))
    }
}

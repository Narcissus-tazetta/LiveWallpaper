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

    func testVideoPinnedToOneDisplaySurvivesSharedWebWallpaper() throws {
        let model = WallpaperModel()
        let pinned = try video("pinned.mp4")
        let source = try WebWallpaperSource(url: XCTUnwrap(URL(string: "https://example.com")))
        model.screenSaverVideoPath = nil
        model.webWallpaperSources = [source]
        model.webWallpaperFeatureEnabled = true
        model.wallpaperKind = .web
        model.currentWebWallpaperID = source.id
        model.displayScreens = [
            .init(id: "video", name: "Video", frame: .zero),
            .init(id: "web", name: "Web", frame: .zero)
        ]
        model.videoOverrideByScreenID = ["video": pinned]

        let config = model.makeScreenSaverConfig()

        XCTAssertEqual(config.display(forDisplayID: "video")?.videoPath, pinned)
        XCTAssertNil(config.display(forDisplayID: "web"))
        XCTAssertNil(config.fallback)
    }

    func testWebPinnedDisplayDoesNotInheritTheSharedVideoFallback() throws {
        let model = WallpaperModel()
        let desktop = try video("desktop.mp4")
        let source = try WebWallpaperSource(url: XCTUnwrap(URL(string: "https://example.com")))
        model.screenSaverVideoPath = nil
        model.webWallpaperSources = [source]
        model.webWallpaperFeatureEnabled = true
        model.wallpaperKind = .video
        model.currentVideoPath = desktop
        model.displayScreens = [
            .init(id: "video", name: "Video", frame: .zero),
            .init(id: "web", name: "Web", frame: .zero)
        ]
        model.webOverrideByScreenID = ["web": source.id]

        let config = model.makeScreenSaverConfig()
        let decoded = try JSONDecoder().decode(
            ScreenSaverConfig.self,
            from: JSONEncoder().encode(config)
        )

        XCTAssertEqual(decoded.display(forDisplayID: "video")?.videoPath, desktop)
        XCTAssertNil(decoded.display(forDisplayID: "web"))
        XCTAssertEqual(decoded.display(forDisplayID: "new-display")?.videoPath, desktop)

        model.screenSaverVideoPath = desktop
        XCTAssertEqual(
            model.makeScreenSaverConfig().display(forDisplayID: "web")?.videoPath,
            desktop
        )
    }

    func testVersionOneConfigStillDecodesWithoutDisplayExclusions() throws {
        let data = Data(#"{"formatVersion":1,"displays":{},"fallback":null}"#.utf8)
        let config = try JSONDecoder().decode(ScreenSaverConfig.self, from: data)
        XCTAssertNil(config.excludedDisplayIDs)
        XCTAssertNil(config.display(forDisplayID: "any"))
    }
}

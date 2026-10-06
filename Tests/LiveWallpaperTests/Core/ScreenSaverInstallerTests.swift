import XCTest
@testable import LiveWallpaper

final class ScreenSaverInstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenSaverInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeBundledSaver(buildID: String) throws -> URL {
        let saver = root.appendingPathComponent("bundled-\(buildID)/LiveWallpaper.saver", isDirectory: true)
        let contents = saver.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: NSDictionary = ["LWBuildID": buildID, "CFBundleIdentifier": "test.saver"]
        XCTAssertTrue(plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true))
        return saver
    }

    private func installer(bundled: URL?) -> ScreenSaverInstaller {
        var installer = ScreenSaverInstaller()
        installer.home = root.appendingPathComponent("home", isDirectory: true)
        installer.bundledSaverURL = bundled
        installer.reloadsHost = false
        return installer
    }

    func testWithoutBundledSaverItIsUnavailable() {
        XCTAssertEqual(installer(bundled: nil).state(), .unavailable)
    }

    func testInstallThenNewBuildReportsUpdateAndUpdateReplacesIt() throws {
        let first = installer(bundled: try makeBundledSaver(buildID: "A"))
        XCTAssertEqual(first.state(), .notInstalled)
        try first.install()
        XCTAssertEqual(first.state(), .installed)

        let second = installer(bundled: try makeBundledSaver(buildID: "B"))
        XCTAssertEqual(second.state(), .updateAvailable)
        try second.install()
        XCTAssertEqual(second.state(), .installed)
    }

    func testUninstallRemovesBundleAndConfig() throws {
        let installer = installer(bundled: try makeBundledSaver(buildID: "A"))
        try installer.install()
        try installer.writeConfig(ScreenSaverConfig(displays: [:], fallback: nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.configURL.path))

        try installer.uninstall()
        XCTAssertEqual(installer.state(), .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.configURL.path))
    }

    func testConfigRoundTripsAndFallsBackForUnknownDisplays() throws {
        let installer = installer(bundled: nil)
        let display = ScreenSaverConfig.Display(
            videoPath: "/v.mp4", fitMode: .fit, zoom: 1.5, offsetX: 0.2, offsetY: -0.1,
            videoAspectRatio: 16.0 / 9.0, trimStart: 1, trimEnd: 9, loopStart: 3
        )
        let fallback = ScreenSaverConfig.Display(
            videoPath: "/main.mp4", fitMode: .fill, zoom: 1, offsetX: 0, offsetY: 0,
            videoAspectRatio: nil, trimStart: 0, trimEnd: nil, loopStart: nil
        )
        let config = ScreenSaverConfig(displays: ["2": display], fallback: fallback)
        try installer.writeConfig(config)

        let decoded = try JSONDecoder().decode(
            ScreenSaverConfig.self, from: Data(contentsOf: installer.configURL)
        )
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.display(forDisplayID: "2"), display)
        XCTAssertEqual(decoded.display(forDisplayID: "99"), fallback)
        XCTAssertEqual(decoded.display(forDisplayID: nil), fallback)
    }
}

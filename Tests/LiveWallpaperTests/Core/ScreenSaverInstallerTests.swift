@testable import LiveWallpaper
import XCTest

final class ScreenSaverInstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ScreenSaverInstallerTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeBundledSaver(buildID: String) throws -> URL {
        let saver = root.appendingPathComponent(
            "bundled-\(buildID)/LiveWallpaper.saver",
            isDirectory: true
        )
        let contents = saver.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: NSDictionary = ["LWBuildID": buildID, "CFBundleIdentifier": "test.saver"]
        XCTAssertTrue(plist.write(
            to: contents.appendingPathComponent("Info.plist"),
            atomically: true
        ))
        return saver
    }

    private func installer(bundled: URL?) throws -> ScreenSaverInstaller {
        var installer = ScreenSaverInstaller()
        installer.home = root.appendingPathComponent("home", isDirectory: true)
        installer.bundledSaverURL = bundled
        installer.reloadsHost = false
        if !FileManager.default.fileExists(atPath: installer.wallpaperStoreURL.path) {
            try writeStore(Self.store(idle: ["S1": "image-1", "S2": "default"]), to: installer)
        }
        return installer
    }

    private static func idle(provider: String) -> [String: Any] {
        [
            "Content": ["Choices": [[
                "Provider": provider,
                "Files": [Any](),
                "Configuration": Data()
            ]]],
            "LastSet": Date(timeIntervalSince1970: 0)
        ]
    }

    /// One Space per entry, each with a per-display state, plus a system default.
    private static func store(idle providers: [String: String]) -> [String: Any] {
        var spaces: [String: Any] = [:]
        for (space, provider) in providers {
            spaces[space] = [
                "Default": ["Type": "individual", "Idle": idle(provider: provider)],
                "Displays": ["D1": ["Type": "individual", "Idle": idle(provider: provider)]]
            ]
        }
        return [
            "AllSpacesAndDisplays": ["Type": "desktop", "Desktop": [String: Any]()],
            "SystemDefault": ["Type": "individual", "Idle": idle(provider: "system")],
            "Spaces": spaces
        ]
    }

    private func writeStore(_ store: [String: Any], to installer: ScreenSaverInstaller) throws {
        try FileManager.default.createDirectory(
            at: installer.wallpaperStoreURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
            .write(to: installer.wallpaperStoreURL)
    }

    private func readStore(_ installer: ScreenSaverInstaller) throws -> [String: Any] {
        try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: installer.wallpaperStoreURL), format: nil
            ) as? [String: Any]
        )
    }

    private func idleProvider(_ store: [String: Any], _ path: [String]) -> String? {
        var node: Any? = store
        for key in path {
            node = (node as? [String: Any])?[key]
        }
        let idle = (node as? [String: Any])?["Idle"] as? [String: Any]
        let choices = (idle?["Content"] as? [String: Any])?["Choices"] as? [[String: Any]]
        return choices?.first?["Provider"] as? String
    }

    private static let idlePaths: [[String]] = [
        ["SystemDefault"],
        ["Spaces", "S1", "Default"], ["Spaces", "S1", "Displays", "D1"],
        ["Spaces", "S2", "Default"], ["Spaces", "S2", "Displays", "D1"]
    ]

    func testWithoutBundledSaverItIsUnavailable() throws {
        XCTAssertEqual(try installer(bundled: nil).state(), .unavailable)
    }

    func testInstallThenNewBuildReportsUpdateAndUpdateReplacesIt() throws {
        let first = try installer(bundled: makeBundledSaver(buildID: "A"))
        XCTAssertEqual(first.state(), .notInstalled)
        try first.install()
        XCTAssertEqual(first.state(), .installed)

        let second = try installer(bundled: makeBundledSaver(buildID: "B"))
        XCTAssertEqual(second.state(), .updateAvailable)
        try second.install()
        XCTAssertEqual(second.state(), .installed)
    }

    func testUninstallRemovesBundleAndConfig() throws {
        let installer = try installer(bundled: makeBundledSaver(buildID: "A"))
        try installer.install()
        try installer.writeConfig(ScreenSaverConfig(displays: [:], fallback: nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.configURL.path))

        try installer.uninstall()
        XCTAssertEqual(installer.state(), .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.configURL.path))
    }

    func testInstallSelectsTheSaverEverywhereAndUninstallPutsThePreviousOnesBack() throws {
        let installer = try installer(bundled: makeBundledSaver(buildID: "A"))
        try installer.install()
        let selected = try readStore(installer)
        for path in Self.idlePaths {
            XCTAssertEqual(idleProvider(selected, path), ScreenSaverSelection.provider, "\(path)")
        }

        try installer.uninstall()
        let restored = try readStore(installer)
        XCTAssertEqual(idleProvider(restored, ["SystemDefault"]), "system")
        XCTAssertEqual(idleProvider(restored, ["Spaces", "S1", "Displays", "D1"]), "image-1")
        XCTAssertEqual(idleProvider(restored, ["Spaces", "S2", "Default"]), "default")
        XCTAssertNil((restored["AllSpacesAndDisplays"] as? [String: Any])?["Idle"])
    }

    func testReinstallAfterAQuitThatNeverRestoredKeepsTheRealOriginals() throws {
        let installer = try installer(bundled: makeBundledSaver(buildID: "A"))
        try installer.install()
        // Next launch without an uninstall in between (crash / force quit).
        try installer.install()
        try installer.uninstall()
        XCTAssertEqual(
            try idleProvider(readStore(installer), ["Spaces", "S1", "Default"]),
            "image-1"
        )
    }

    func testUninstallKeepsAScreenSaverTheUserPickedMeanwhile() throws {
        let installer = try installer(bundled: makeBundledSaver(buildID: "A"))
        try installer.install()
        var store = try readStore(installer)
        var spaces = try XCTUnwrap(store["Spaces"] as? [String: Any])
        var space = try XCTUnwrap(spaces["S1"] as? [String: Any])
        var state = try XCTUnwrap(space["Default"] as? [String: Any])
        state["Idle"] = Self.idle(provider: "picked")
        space["Default"] = state
        spaces["S1"] = space
        store["Spaces"] = spaces
        try writeStore(store, to: installer)

        try installer.uninstall()
        XCTAssertEqual(
            try idleProvider(readStore(installer), ["Spaces", "S1", "Default"]),
            "picked"
        )
    }

    func testSaverSelectedByHandWithoutABackupFallsBackToTheSystemDefault() throws {
        let installer = try installer(bundled: makeBundledSaver(buildID: "A"))
        try installer.install()
        try FileManager.default.removeItem(at: installer.previousSelectionURL)

        try installer.uninstall()
        let restored = try readStore(installer)
        for path in Self.idlePaths {
            XCTAssertEqual(idleProvider(restored, path), "default", "\(path)")
        }
    }

    func testInstallWithoutAWallpaperStoreFails() throws {
        let installer = try installer(bundled: makeBundledSaver(buildID: "A"))
        try FileManager.default.removeItem(at: installer.wallpaperStoreURL)
        XCTAssertThrowsError(try installer.install())
    }

    func testConfigRoundTripsAndFallsBackForUnknownDisplays() throws {
        let installer = try installer(bundled: nil)
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

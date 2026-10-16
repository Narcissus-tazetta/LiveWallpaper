@testable import LiveWallpaper
import XCTest

@MainActor
final class ExternalWallpaperTests: XCTestCase {
    private var directory: URL!
    private var videoURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ExternalWallpaperTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        videoURL = directory.appendingPathComponent("video.mp4")
        try Data([0]).write(to: videoURL)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func writeManifest(named name: String, pid: Int32, path: String) throws {
        let json: [String: Any] = [
            "processIdentifier": pid,
            "name": "Provider \(name)",
            "wallpapers": [["id": "a", "name": "Rain", "path": path]]
        ]
        let providers = directory.appendingPathComponent("Providers", isDirectory: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json)
            .write(to: providers.appendingPathComponent("\(name).json"), options: .atomic)
    }

    private func launchSleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    func testShowsOnlyLiveProvidersAndDropsOneThatExits() throws {
        let sleeper = try launchSleeper()
        defer { sleeper.terminate() }
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()

        try writeManifest(named: "live", pid: sleeper.processIdentifier, path: videoURL.path)
        try writeManifest(named: "dead", pid: finished.processIdentifier, path: videoURL.path)
        try writeManifest(named: "relative", pid: sleeper.processIdentifier, path: "video.mp4")

        var reports: [[ExternalWallpaper]] = []
        let dropped = expectation(description: "provider exit removes its wallpapers")
        let monitor = ExternalWallpaperProviderMonitor(
            directoryURL: directory.appendingPathComponent("Providers")
        ) { wallpapers in
            reports.append(wallpapers)
            if reports.count > 1, wallpapers.isEmpty {
                dropped.fulfill()
            }
        }
        monitor.start()

        XCTAssertEqual(reports.first?.map(\.id), ["live.json/a"])
        XCTAssertEqual(reports.first?.first?.path, videoURL.path)

        sleeper.terminate()
        wait(for: [dropped], timeout: 5)
    }

    func testExternalWallpaperOverridesDesktopWithoutReachingSavedState() {
        let keys = [
            PrefsKey.libraryVideoPaths,
            PrefsKey.videoOverrideByScreenID,
            PrefsKey.videoPath
        ]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }

        let model = WallpaperModel()
        let wallpaper = ExternalWallpaper(
            id: "p.json/a",
            providerName: "P",
            name: "Rain",
            path: videoURL.path
        )
        model.updateExternalWallpapers([wallpaper])
        model.showExternalWallpaper(id: wallpaper.id)

        XCTAssertEqual(model.resolvedOverridePath(forScreenID: "1"), videoURL.path)
        XCTAssertNil(model.resolvedSavedOverridePath(forScreenID: "1"))
        XCTAssertNotEqual(model.currentlyVisiblePathForMainDisplay, videoURL.path)

        model.persistPlaylistStateImmediately()
        for key in keys {
            let stored = UserDefaults.standard.object(forKey: key).map { "\($0)" } ?? ""
            XCTAssertFalse(stored.contains(videoURL.path), key)
        }

        model.updateExternalWallpapers([])
        XCTAssertNil(model.activeExternalWallpaperID)
        XCTAssertNil(model.resolvedOverridePath(forScreenID: "1"))
    }

    func testAddingCopiesIntoTheLibraryOnceAndOutlivesTheProvider() async throws {
        let keys = [
            PrefsKey.libraryVideoPaths, PrefsKey.registeredVideoPaths, PrefsKey.videoPath,
            PrefsKey.registeredVideoDisplayNames, PrefsKey.importedExternalWallpapers
        ]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        var copiedPath: String?
        defer {
            for (key, value) in zip(keys, saved) {
                UserDefaults.standard.set(value, forKey: key)
            }
            if let copiedPath {
                try? FileManager.default.removeItem(atPath: copiedPath)
            }
        }

        let model = WallpaperModel()
        let wallpaper = ExternalWallpaper(
            id: "p.json/a",
            providerName: "P",
            name: "Rain",
            path: videoURL.path
        )
        model.updateExternalWallpapers([wallpaper])

        let added = await model.importExternalWallpaper(id: wallpaper.id)
        copiedPath = model.libraryPath(forExternalWallpaperID: wallpaper.id)

        XCTAssertTrue(added)
        let path = try XCTUnwrap(copiedPath)
        XCTAssertNotEqual(path, videoURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(model.registeredVideoDisplayName(for: path), "Rain")
        let secondAdd = await model.importExternalWallpaper(id: wallpaper.id)
        XCTAssertFalse(secondAdd)

        model.updateExternalWallpapers([])
        try FileManager.default.removeItem(at: videoURL)
        XCTAssertTrue(model.libraryVideoPaths.contains(path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
}

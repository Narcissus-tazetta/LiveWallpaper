import CoreGraphics
import ImageIO
@testable import LiveWallpaper
import UniformTypeIdentifiers
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

    /// A provider's scene folder with one still image layer.
    private func writeSceneFolder() throws -> URL {
        let folder = directory.appendingPathComponent("offered.scene", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 16, height: 9, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            folder.appendingPathComponent("layer.png") as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let document = SceneDocument(canvasWidth: 16, canvasHeight: 9, layers: [SceneLayer(name: "Sky", imageFile: "layer.png")])
        try SceneStore.encode(document).write(to: folder.appendingPathComponent("scene.json"))
        return folder
    }

    func testReadsSceneItemsAndRefusesItemsWithBothOrNeither() throws {
        let sleeper = try launchSleeper()
        defer { sleeper.terminate() }
        let scene = try writeSceneFolder()
        let json: [String: Any] = [
            "processIdentifier": sleeper.processIdentifier,
            "name": "P",
            "wallpapers": [
                ["id": "scene", "name": "Sky", "scene": scene.path],
                ["id": "both", "name": "Both", "scene": scene.path, "path": videoURL.path],
                ["id": "neither", "name": "Neither"],
                ["id": "missing", "name": "Missing", "scene": directory.appendingPathComponent("none").path]
            ]
        ]
        let providers = directory.appendingPathComponent("Providers", isDirectory: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: providers.appendingPathComponent("p.json"))

        var report: [ExternalWallpaper] = []
        let monitor = ExternalWallpaperProviderMonitor(directoryURL: providers) { report = $0 }
        monitor.start()

        XCTAssertEqual(report.map(\.id), ["p.json/scene"])
        XCTAssertEqual(report.first?.sceneFolderPath, scene.path)
        XCTAssertEqual(report.first?.path, ExternalWallpaperProviderMonitor.bakedScenePath(forID: "p.json/scene"))
        XCTAssertNotNil(report.first?.sceneRevision)
    }

    func testOfferedSceneIsBakedShownAddedWithItsSceneAndCleanedUp() async throws {
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
                try? FileManager.default.removeItem(at: SceneStore.folderURL(forVideoPath: copiedPath))
            }
        }
        let folder = try writeSceneFolder()
        let id = "test-\(UUID().uuidString).json/a"
        let bakedPath = ExternalWallpaperProviderMonitor.bakedScenePath(forID: id)
        let wallpaper = ExternalWallpaper(
            id: id, providerName: "P", name: "Sky", path: bakedPath, sceneFolderPath: folder.path,
            sceneRevision: try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("scene.json").path)[.modificationDate] as? Date
            )
        )

        let model = WallpaperModel()
        model.updateExternalWallpapers([wallpaper])
        XCTAssertFalse(model.isExternalWallpaperReady(wallpaper))
        model.showExternalWallpaper(id: id)
        XCTAssertNil(model.activeExternalWallpaperID, "a scene is not shown before it is baked")

        let deadline = Date().addingTimeInterval(60)
        while !model.isExternalWallpaperReady(wallpaper), !model.didFailToPrepareExternalScene(wallpaper), Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(model.isExternalWallpaperReady(wallpaper))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bakedPath))
        XCTAssertTrue(model.isScene(path: bakedPath))

        model.showExternalWallpaper(id: id)
        XCTAssertEqual(model.resolvedOverridePath(forScreenID: "1"), bakedPath)

        let added = await model.importExternalWallpaper(id: id)
        copiedPath = model.libraryPath(forExternalWallpaperID: id)
        XCTAssertTrue(added)
        let path = try XCTUnwrap(copiedPath)
        XCTAssertTrue(SceneStore.hasScene(videoPath: path))
        XCTAssertTrue(model.isScene(path: path))

        model.updateExternalWallpapers([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: bakedPath).deletingLastPathComponent().path))
        XCTAssertFalse(model.isScene(path: bakedPath))
        XCTAssertTrue(model.isScene(path: path))
    }

    func testCachedBakedSceneIsReusedWhenNeitherSceneNorAppHasChanged() async throws {
        let folder = try writeSceneFolder()
        let id = "test-cached-\(UUID().uuidString).json/a"
        let bakedPath = ExternalWallpaperProviderMonitor.bakedScenePath(forID: id)
        let revision = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("scene.json").path)[.modificationDate] as? Date
        )
        let wallpaper = ExternalWallpaper(
            id: id, providerName: "P", name: "Sky", path: bakedPath, sceneFolderPath: folder.path,
            sceneRevision: revision
        )
        defer {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: bakedPath).deletingLastPathComponent())
        }

        let firstModel = WallpaperModel()
        firstModel.updateExternalWallpapers([wallpaper])
        let deadline = Date().addingTimeInterval(60)
        while !firstModel.isExternalWallpaperReady(wallpaper), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(firstModel.isExternalWallpaperReady(wallpaper))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bakedPath))

        // On a simulated app restart with unchanged scene and app, the baked scene is ready immediately.
        let secondModel = WallpaperModel()
        secondModel.updateExternalWallpapers([wallpaper])
        XCTAssertTrue(secondModel.isExternalWallpaperReady(wallpaper))

        // If the app signature changes, the cache is invalidated and must be rebaked.
        let metaURL = ExternalWallpaperProviderMonitor.bakedSceneMetaURL(forID: id)
        let oldMeta = ExternalWallpaperProviderMonitor.BakedSceneMeta(sceneRevision: revision, appSignature: "outdated-app-version")
        try JSONEncoder().encode(oldMeta).write(to: metaURL)

        let thirdModel = WallpaperModel()
        thirdModel.updateExternalWallpapers([wallpaper])
        XCTAssertFalse(thirdModel.isExternalWallpaperReady(wallpaper), "rebake required when app signature changes")
    }

    func testExternalWallpaperCannotBeSharedToStore() async throws {
        let externalPath = "/Users/test/Library/Application Support/we-import/Wallpapers/we-12345/video.mp4"
        let model = WallpaperModel()
        XCTAssertTrue(model.isExternalOrImportedWallpaper(path: externalPath))

        let importedPath = "/Users/test/Library/Application Support/LiveWallpaper/Videos/imported.mp4"
        model.importedExternalWallpaperPaths["we-12345"] = importedPath
        XCTAssertTrue(model.isExternalOrImportedWallpaper(path: importedPath))

        let localPath = "/Users/test/Movies/local.mp4"
        XCTAssertFalse(model.isExternalOrImportedWallpaper(path: localPath))

        let client = StoreClient(packageExporter: PackageExporter())
        do {
            _ = try await client.submit(
                model: model,
                videoPath: externalPath,
                title: "Test",
                author: "Author",
                license: nil,
                thumbnailCache: DiskThumbnailCache()
            )
            XCTFail("External wallpaper submission should have thrown cannotShareExternalWallpaper")
        } catch let error as StoreClientError {
            guard case .cannotShareExternalWallpaper = error else {
                XCTFail("Expected cannotShareExternalWallpaper, got \(error)")
                return
            }
        }
    }
}

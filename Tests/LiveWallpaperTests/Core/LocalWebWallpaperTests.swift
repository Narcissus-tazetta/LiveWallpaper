import AppKit
import AVFoundation
import Foundation
@testable import LiveWallpaper
import WebKit
import XCTest

@MainActor
final class LocalWebWallpaperTests: XCTestCase {
    private var directory: URL!
    private var folder: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalWebTests-\(UUID().uuidString)")
        folder = directory.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(LocalWebWallpaperPackage(entryPoint: "index.html", warnings: []))
            .write(to: folder.appendingPathComponent(LocalWebWallpaperPackage.fileName))
        try "<html><body>Local wallpaper</body></html>".write(
            to: folder.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testHTTPServesAssetsRangesAndRefusesEscapes() async throws {
        let server = LocalWebWallpaperServer()
        let url = try await server.url(folder: folder)
        let bytes = Data((0 ..< 100).map(UInt8.init))
        try bytes.write(to: folder.appendingPathComponent("clip.mp4"))
        let asset = url.deletingLastPathComponent().appendingPathComponent("clip.mp4")
        var request = URLRequest(url: asset)
        request.setValue("bytes=10-19", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(data, bytes[10 ..< 20])
        XCTAssertEqual(
            (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"),
            "bytes 10-19/100"
        )
        request.setValue("bytes=-5", forHTTPHeaderField: "Range")
        let (suffix, _) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(suffix, bytes.suffix(5))
        request.setValue("bytes=100-", forHTTPHeaderField: "Range")
        let (_, invalid) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((invalid as? HTTPURLResponse)?.statusCode, 416)
        try bytes.write(to: directory.appendingPathComponent("secret"))
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("escape"),
            withDestinationURL: directory.appendingPathComponent("secret")
        )
        let (_, escaped) = try await URLSession.shared
            .data(from: url.deletingLastPathComponent().appendingPathComponent("escape"))
        XCTAssertEqual((escaped as? HTTPURLResponse)?.statusCode, 404)
        let module = "export const value = 1;"
        try module.write(
            to: folder.appendingPathComponent("main.mjs"),
            atomically: true,
            encoding: .utf8
        )
        let (_, mime) = try await URLSession.shared
            .data(from: url.deletingLastPathComponent().appendingPathComponent("main.mjs"))
        XCTAssertEqual(mime.mimeType, "text/javascript")
    }

    func testCopiedPackageSurvivesItsProviderFolderBeingRemoved() async throws {
        let saved = directory.appendingPathComponent("saved")
        try LocalWebWallpaperPackage.copy(from: folder, to: saved)
        try FileManager.default.removeItem(at: folder)
        let server = LocalWebWallpaperServer()
        let url = try await server.url(folder: saved)
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Local wallpaper"))
    }

    func testOriginsAreIsolatedAndStableAcrossServerRestarts() async throws {
        let key = "localWebWallpaperPorts"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let other = directory.appendingPathComponent("other")
        try LocalWebWallpaperPackage.copy(from: folder, to: other)
        let first = LocalWebWallpaperServer(persistPorts: true)
        let a = try await first.url(folder: folder)
        let b = try await first.url(folder: other)
        XCTAssertNotEqual(a.port, b.port, "each package has its own browser storage origin")
        first.remove(folder: folder)
        try await Task.sleep(nanoseconds: 100_000_000)
        let second = LocalWebWallpaperServer(persistPorts: true)
        let restored = try await second.url(folder: folder)
        XCTAssertEqual(restored, a, "restarting must not reset the page's cookies and localStorage")
        let (_, response) = try await URLSession.shared.data(from: restored)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    func testRestoresVideoAfterExternalWebTransitionRetiresItsPlayer() async throws {
        let video = directory.appendingPathComponent("original.mp4")
        var scene = SceneDocument(canvasWidth: 16, canvasHeight: 16, layers: [])
        scene.loopSeconds = 1
        try await SceneVideoBaker.bake(document: scene, videoPath: video.path, to: video) { _ in }
        let model = WallpaperModel()
        defer {
            model.windowRebuildWorkItem?.cancel()
            model.statePersistWorkItem?.cancel()
            model.stopAllPlayers()
            Array(model.transitionHeldPlayers.values).forEach { $0.release() }
        }
        model.wallpaperKind = .video
        model.activeExternalWallpaperID = nil
        model.wallpaperTransitionDuration = 0.5
        model.systemReduceMotionEnabled = false
        model.currentVideoPath = video.path
        model.playVideo(url: video)
        let source = WebWallpaperSource(
            url: folder.appendingPathComponent("index.html"),
            localFolderPath: folder.path
        )
        let external = ExternalWallpaper(
            id: "provider/web",
            providerName: "P",
            name: "Web",
            path: "",
            webSource: source
        )
        model.externalWallpapers = [external]
        model.showExternalWallpaper(id: external.id)
        model.windowRebuildWorkItem?.cancel()
        XCTAssertNil(model.sharedPlayer, "the outgoing player belongs to the transition")
        model.stopExternalWallpaper()
        model.windowRebuildWorkItem?.cancel()
        let player = try XCTUnwrap(model.sharedPlayer)
        let deadline = Date().addingTimeInterval(3)
        while player.currentItem == nil || player.currentItem?.status == .unknown {
            if Date() >= deadline { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let item = try XCTUnwrap(player.currentItem)
        XCTAssertEqual((item.asset as? AVURLAsset)?.url, video)
        XCTAssertEqual(item.status, .readyToPlay, "\(String(describing: item.error))")
        player.play()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertGreaterThan(player.currentTime().seconds, 0)
    }

    func testManifestWebSourceIsStableAndDoesNotChangeTheSavedSelection() throws {
        let manifest: [String: Any] = [
            "processIdentifier": ProcessInfo.processInfo.processIdentifier,
            "name": "Provider",
            "wallpapers": [
                ["id": "web", "name": "Local", "web": folder.path],
                [
                    "id": "mixed",
                    "name": "Invalid",
                    "web": folder.path,
                    "path": folder
                        .appendingPathComponent("index.html").path
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: directory.appendingPathComponent("provider.json"))
        var reports: [[ExternalWallpaper]] = []
        let monitor = ExternalWallpaperProviderMonitor(directoryURL: directory) {
            reports.append($0)
        }
        monitor.start()
        monitor.rescan()
        XCTAssertEqual(reports.first, reports.last)
        XCTAssertEqual(reports.last?.count, 1)
        let wallpaper = try XCTUnwrap(reports.last?.first)
        let saved = try WebWallpaperSource(url: XCTUnwrap(URL(string: "https://example.com")))
        let model = WallpaperModel()
        model.wallpaperKind = .web
        model.webWallpaperSources = [saved]
        model.currentWebWallpaperID = saved.id
        model.externalWallpapers = [wallpaper]
        model.activeExternalWallpaperID = wallpaper.id
        XCTAssertEqual(model.activeWebWallpaperSource?.localFolderPath, folder.path)
        XCTAssertTrue(model.isWebWallpaperActive)
        XCTAssertEqual(model.currentWebWallpaperID, saved.id)
        model.updateExternalWallpapers([])
        XCTAssertEqual(model.activeWebWallpaperSource, saved)
    }

    func testLibraryImportRestoresWithoutTheProvider() async throws {
        let model = WallpaperModel()
        model.wallpaperTransitionDuration = 0
        let keys = [
            PrefsKey.playlistsData,
            PrefsKey.libraryVideoPaths,
            PrefsKey.registeredVideoPaths,
            PrefsKey.selectedPlaylistID,
            PrefsKey.webWallpaperSourcesData,
            PrefsKey.scheduleRulesData,
            PrefsKey.focusFilterIntegrationEnabled,
            PrefsKey.focusModeAssignmentsData,
            PrefsKey.wallpaperKind,
            PrefsKey.currentWebWallpaperID,
            PrefsKey.webWallpaperFeatureEnabled,
            PrefsKey.importedExternalWallpapers,
            model.wallpaperPresentationStorageKey,
            model.wallpaperEditStorageKey
        ]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        var copy: URL?
        defer {
            model.statePersistWorkItem?.cancel()
            model.windowRebuildWorkItem?.cancel()
            for (key, value) in zip(keys, saved) {
                UserDefaults.standard.set(value, forKey: key)
            }
            if let copy { XCTAssertNoThrow(try FileManager.default.removeItem(at: copy)) }
        }
        let source = WebWallpaperSource(
            url: folder.appendingPathComponent("index.html"),
            displayName: "Local",
            localFolderPath: folder.path
        )
        let wallpaper = ExternalWallpaper(
            id: "test.json/web",
            providerName: "P",
            name: "Local",
            path: "",
            webSource: source
        )
        let settings = LocalWebSettings(values: ["count": .number(17)], mediaEnabled: true)
        try settings.save(id: source.id)
        defer {
            UserDefaults.standard.removeObject(forKey: "localWebSettings.\(source.id.uuidString)")
        }
        let originalAsset = directory.appendingPathComponent("selected.txt")
        try Data("selected asset".utf8).write(to: originalAsset)
        let relativeAsset = try await model.importLocalWebPropertyFile(
            originalAsset,
            source: source
        )
        try FileManager.default.removeItem(at: originalAsset)
        model.externalWallpapers = [wallpaper]
        let added = await model.importExternalWallpaper(id: wallpaper.id)
        model.windowRebuildWorkItem?.cancel()
        XCTAssertTrue(added)
        let local = try XCTUnwrap(model.webWallpaperSources.first)
        XCTAssertEqual(try LocalWebSettings.load(id: local.id), settings)
        defer {
            UserDefaults.standard.removeObject(forKey: "localWebSettings.\(local.id.uuidString)")
        }
        copy = try URL(fileURLWithPath: XCTUnwrap(local.localFolderPath))
        XCTAssertEqual(
            try String(contentsOf: XCTUnwrap(copy).appendingPathComponent(relativeAsset)),
            "selected asset"
        )
        XCTAssertTrue(try LocalWebWallpaperPackage.owns(XCTUnwrap(copy)))
        XCTAssertNotEqual(local.localFolderPath, folder.path)
        model.persistPlaylistStateImmediately()
        try FileManager.default.removeItem(at: folder)
        model.externalWallpapers = []
        let restored = WallpaperModel()
        restored.restoreWebWallpaperState()
        XCTAssertEqual(restored.activeWebWallpaperSource?.id, local.id)
        XCTAssertTrue(restored.isWebWallpaperActive)
        let server = LocalWebWallpaperServer()
        let url = try await server.url(folder: XCTUnwrap(copy))
        let (bytes, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertFalse(bytes.isEmpty)
    }

    func testLocalPageAnimationPausesResumesAndReceivesHostSettings() async throws {
        let html = """
        <html><body style="background:#245b82"><script>
        window.framesDrawn = 0;
        function draw() { window.framesDrawn++; requestAnimationFrame(draw); }
        requestAnimationFrame(draw);
        window.context = new AudioContext();
        context.resume();
        </script></body></html>
        """
        try html.write(
            to: folder.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        let server = LocalWebWallpaperServer()
        let url = try await server.url(folder: folder)
        let view = WebPlayerView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        func read<T>(_ script: String) async throws -> T {
            let value = try await view.webView.evaluateJavaScript(script)
            return try XCTUnwrap(value as? T)
        }
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { view.tearDown(); window.close() }
        let loaded = expectation(description: "local document loaded")
        view.onLoadStateChanged = { state in if state == .loaded { loaded.fulfill() } }
        view.setHostEnvironment(volume: 0.25, fps: 30, language: "ja")
        view.load(
            request: .init(
                loadContent: .url(url),
                layoutMode: .generic,
                canonicalKey: "local-test",
                isLocalPackage: true
            ),
            audioEnabled: true
        )
        await fulfillment(of: [loaded], timeout: 10)
        try await Task.sleep(nanoseconds: 250_000_000)
        let visibility: String = try await read("document.visibilityState")
        guard visibility == "visible"
        else {
            throw XCTSkip(
                "WebKit does not deliver animation frames to this test process's hidden page"
            )
        }
        let count: Int = try await read("framesDrawn")
        XCTAssertGreaterThan(count, 0)
        view.setSuspended(true)
        try await Task.sleep(nanoseconds: 150_000_000)
        let paused: Int = try await read("framesDrawn")
        try await Task.sleep(nanoseconds: 150_000_000)
        let unchanged: Int = try await read("framesDrawn")
        XCTAssertEqual(paused, unchanged)
        let audioState: String = try await read("context.state")
        XCTAssertEqual(audioState, "suspended")
        view.setSuspended(false)
        try await Task.sleep(nanoseconds: 200_000_000)
        let resumed: Int = try await read("framesDrawn")
        XCTAssertGreaterThan(resumed, paused)
        view.setHostEnvironment(volume: 0.6, fps: 30, language: "en")
        let volume: Double = try await read("__liveWallpaperState.volume")
        XCTAssertEqual(volume, 0.6, accuracy: 0.001)
        view.setAudioEnabled(false)
        try await Task.sleep(nanoseconds: 100_000_000)
        let muted: String = try await read("context.state")
        XCTAssertEqual(muted, "suspended")
    }
}

import CryptoKit
@testable import LiveWallpaper
import XCTest

/// Web wallpapers, presets and playlists travel in a package and come back on the other
/// side as library entries the receiver can use.
@MainActor
final class SharingPackageTests: XCTestCase {
    private var root: URL!
    private var savedPreferences: [String: Any]?
    private var preferencesDomain: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharingPackageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        preferencesDomain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        savedPreferences = UserDefaults.standard.persistentDomain(forName: preferencesDomain)
    }

    override func tearDown() async throws {
        if let savedPreferences {
            UserDefaults.standard.setPersistentDomain(savedPreferences, forName: preferencesDomain)
        } else {
            UserDefaults.standard.removePersistentDomain(forName: preferencesDomain)
        }
        try FileManager.default.removeItem(at: root)
    }

    private func makeWebFolder() throws -> URL {
        let folder = root.appendingPathComponent("page", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: folder.appendingPathComponent("index.html"))
        let manifest = """
        {"entryPoint": "index.html", "warnings": [], "properties": [
          {"id": "speed", "kind": "slider", "label": {"en": "Speed"}, "value": 1},
          {"id": "photos", "kind": "directory", "label": {"en": "Photos"}, "value": ""}
        ]}
        """
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("web-wallpaper.json"))
        return folder
    }

    private func makePreset(in store: ScenePresetStore) throws -> ScenePreset {
        let sceneFolder = root.appendingPathComponent("scene", isDirectory: true)
        try FileManager.default.createDirectory(at: sceneFolder, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: sceneFolder.appendingPathComponent("mask-a.png"))
        var effect = SceneEffect(kind: .waves)
        effect.maskFile = "mask-a.png"
        let preset = ScenePreset(
            name: "Ripples",
            effects: [ScenePresetEffect(effect, wantsMask: true)]
        )
        try store.save(preset, filesFrom: sceneFolder)
        return preset
    }

    private func manifest(of packageURL: URL) async throws -> PackageManifest {
        try await PackageImporter().preview(of: packageURL).manifest
    }

    func testWebWallpapersPresetsAndPlaylistsRoundTrip() async throws {
        let sender = WallpaperModel()
        let senderStore = ScenePresetStore(directory: root.appendingPathComponent("sent"))
        sender.scenePresetStore = senderStore
        let preset = try makePreset(in: senderStore)
        sender.userScenePresets = [preset]

        let local = try WebWallpaperSource(
            url: root.appendingPathComponent("page/index.html"),
            displayName: "Local page",
            localFolderPath: makeWebFolder().path
        )
        let remote = try WebWallpaperSource(
            url: XCTUnwrap(URL(string: "https://example.com/wall")),
            displayName: "Remote page"
        )
        sender.webWallpaperSources = [local, remote]
        try LocalWebSettings(values: [
            "speed": .number(3),
            "photos": .string("/Users/sender/Pictures"),
            "gone": .string("left over")
        ]).save(id: local.id)
        let playlist = WallpaperPlaylist(
            id: UUID(),
            name: "Evening",
            videoPaths: [],
            webWallpaperIDs: [remote.id]
        )

        let packageURL = root.appendingPathComponent("shared.lwpkg")
        try await PackageExporter().exportPackage(
            model: sender,
            selection: PackageSelection(
                name: "Mix",
                description: "test",
                webWallpaperIDs: [local.id, remote.id],
                scenePresetIDs: [preset.id],
                playlists: [playlist]
            ),
            outputURL: packageURL
        )
        // Older versions would import such a package as empty, so they must refuse it.
        let sentManifest = try await manifest(of: packageURL)
        XCTAssertEqual(sentManifest.version, "1.2")
        XCTAssertEqual(sentManifest.webWallpapers?.count, 2)
        XCTAssertEqual(sentManifest.scenePresets?.count, 1)

        let receiver = WallpaperModel()
        receiver.setWebWallpaperFeatureEnabled(false)
        receiver.webWallpaperSources = []
        receiver.playlists = []
        let receiverStore = ScenePresetStore(directory: root.appendingPathComponent("received"))
        receiver.scenePresetStore = receiverStore
        receiver.userScenePresets = []
        let webDirectory = root.appendingPathComponent("web-library")
        try await PackageImporter(
            videosDirectory: root.appendingPathComponent("videos"),
            webWallpapersDirectory: webDirectory,
            scenePresetStore: receiverStore
        ).importPackage(from: packageURL, into: receiver)

        XCTAssertEqual(receiver.webWallpaperSources.count, 2)
        XCTAssertTrue(
            receiver.webWallpaperFeatureEnabled,
            "Imported Web wallpapers must be visible"
        )
        let importedLocal = try XCTUnwrap(receiver.webWallpaperSources
            .first { $0.displayName == "Local page" })
        let folder = try XCTUnwrap(importedLocal.localFolderPath)
        XCTAssertTrue(folder.hasPrefix(webDirectory.path + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedLocal.url.path))
        // Only values that mean something on another Mac come along.
        XCTAssertEqual(
            try LocalWebSettings.load(id: importedLocal.id).values,
            ["speed": .number(3)]
        )
        let importedRemote = try XCTUnwrap(receiver.webWallpaperSources
            .first { $0.displayName == "Remote page" })
        XCTAssertEqual(importedRemote.url.absoluteString, "https://example.com/wall")

        let importedPreset = try XCTUnwrap(receiver.userScenePresets?.first)
        XCTAssertEqual(importedPreset.name, "Ripples")
        XCTAssertNotEqual(importedPreset.id, preset.id)
        XCTAssertEqual(try receiverStore.loadAll().presets.map(\.name), ["Ripples"])
        XCTAssertEqual(
            try Data(contentsOf: receiverStore.folderURL(of: importedPreset.id)
                .appendingPathComponent("mask-a.png")),
            Data([1, 2, 3])
        )

        let importedPlaylist = try XCTUnwrap(receiver.playlists.first { $0.name == "Evening" })
        XCTAssertEqual(importedPlaylist.webWallpaperIDs, [importedRemote.id])
    }

    func testVideoOnlyPackageStaysReadableByOlderVersions() async throws {
        let video = root.appendingPathComponent("clip.mp4")
        try Data("stand-in".utf8).write(to: video)
        let packageURL = try await PackageExporter().exportSingleWallpaperPackage(
            model: WallpaperModel(),
            videoPath: video.path,
            outputFolderURL: root,
            baseFileName: "clip"
        )
        let manifest = try await manifest(of: packageURL)
        XCTAssertEqual(manifest.version, "1.1")
        XCTAssertNil(manifest.webWallpapers)
        XCTAssertNil(manifest.scenePresets)
    }

    func testPresetNamingFilesOutsideItsFolderIsRefused() async throws {
        let content = root.appendingPathComponent("content", isDirectory: true)
        let presetFolder = content.appendingPathComponent("presets/p", isDirectory: true)
        try FileManager.default.createDirectory(at: presetFolder, withIntermediateDirectories: true)
        var effect = SceneEffect(kind: .waves)
        effect.maskFile = "../../../escape.png"
        let preset = ScenePreset(name: "Bad", effects: [ScenePresetEffect(effect, wantsMask: true)])
        try StoredFormat.scenePreset.encode(preset, using: JSONEncoder())
            .write(to: presetFolder.appendingPathComponent("preset.json"))
        let manifest = PackageManifest(
            version: "1.2",
            manifest: .init(
                name: "Bad", author: "", createdAt: "2026-11-06T00:00:00Z",
                description: "", license: nil
            ),
            videos: [],
            playlists: [],
            packaging: .init(videosIncluded: true, packageSizeBytes: 0),
            scenePresets: [.init(id: "p", name: "Bad", folder: "presets/p")]
        )
        try JSONEncoder().encode(manifest)
            .write(to: content.appendingPathComponent("metadata.json"))
        let packageURL = root.appendingPathComponent("bad.lwpkg")
        try await ProcessRunner.run("/usr/bin/ditto", arguments: [
            "-c", "-k", "--keepParent", content.path, packageURL.path
        ])

        let store = ScenePresetStore(directory: root.appendingPathComponent("received"))
        let receiver = WallpaperModel()
        receiver.scenePresetStore = store
        do {
            try await PackageImporter(scenePresetStore: store)
                .importPackage(from: packageURL, into: receiver)
            XCTFail("A preset may only name files next to it")
        } catch let PackageImporter.ImportError.unsafeFileReference(name) {
            XCTAssertEqual(name, "../../../escape.png")
        }
        XCTAssertEqual(try store.loadAll().presets, [])
    }

    func testPreviewShowsContentsWithoutImporting() async throws {
        let video = root.appendingPathComponent("clip.mp4")
        try Data("stand-in".utf8).write(to: video)
        let model = WallpaperModel()
        let packageURL = try await PackageExporter().exportSingleWallpaperPackage(
            model: model,
            videoPath: video.path,
            outputFolderURL: root,
            baseFileName: "clip",
            license: "CC0"
        )
        let preview = try await PackageImporter().preview(of: packageURL)
        XCTAssertEqual(preview.manifest.videos.count, 1)
        XCTAssertEqual(preview.manifest.manifest.license, "CC0")
        XCTAssertEqual(preview.packageBytes, try Int64(packageURL.regularFileSize()))
    }
}

/// Store downloads are capped and checked before anything is imported.
final class StoreDownloaderTests: XCTestCase {
    private final class Stub: URLProtocol {
        nonisolated(unsafe) static var body = Data()

        override static func canInit(with _: URLRequest) -> Bool {
            true
        }

        override static func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Length": "\(Self.body.count)"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return URLSession(configuration: config)
    }

    private let url = URL(string: "https://store.invalid/download/x")!

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testDownloadsAndVerifies() async throws {
        Stub.body = Data(repeating: 7, count: 300_000)
        let file = try await StoreDownloader.download(
            from: url, session: session, maxBytes: 1_000_000,
            expectedSHA256: sha256(Stub.body)
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), Stub.body)
        XCTAssertEqual(file.pathExtension, "lwpkg")
    }

    func testRejectsAChecksumMismatch() async throws {
        Stub.body = Data(repeating: 1, count: 1000)
        do {
            _ = try await StoreDownloader.download(
                from: url, session: session, maxBytes: 1_000_000,
                expectedSHA256: sha256(Data([0]))
            ) { _ in }
            XCTFail("A package whose checksum differs must not be imported")
        } catch StoreClientError.checksumMismatch {}
    }

    func testStopsAtTheSizeCap() async throws {
        Stub.body = Data(repeating: 1, count: 200_000)
        do {
            _ = try await StoreDownloader.download(
                from: url, session: session, maxBytes: 100_000,
                expectedSHA256: sha256(Stub.body)
            ) { _ in }
            XCTFail("A body over the cap must be refused")
        } catch let StoreClientError.fileTooLarge(size, maxBytes) {
            XCTAssertGreaterThan(size, maxBytes)
            XCTAssertEqual(maxBytes, 100_000)
        }
    }
}

final class ExportFileNameTests: XCTestCase {
    func testDropsTheMediaExtensionTheExportAddsAgain() {
        XCTAssertEqual(ExportFileNameSanitizer.sanitizedExportFileName("aurora.mp4"), "aurora")
        XCTAssertEqual(ExportFileNameSanitizer.sanitizedExportFileName("Clip.MOV"), "Clip")
        XCTAssertEqual(ExportFileNameSanitizer.sanitizedExportFileName("v1.2 final"), "v1.2 final")
        XCTAssertEqual(ExportFileNameSanitizer.sanitizedExportFileName("a/b:c.mp4"), "a b c")
    }
}

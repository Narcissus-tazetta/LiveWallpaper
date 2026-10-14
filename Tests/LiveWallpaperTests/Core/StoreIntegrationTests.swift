import AppKit
import AVFoundation
import CryptoKit
@testable import LiveWallpaper
import XCTest

private final class RejectExternalStoreRequests: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host != "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }

    override func stopLoading() {}
}

@MainActor
final class StoreIntegrationTests: XCTestCase {
    func testSceneSubmissionApprovalDownloadAndImport() async throws {
        guard let address = ProcessInfo.processInfo.environment["LIVEWALLPAPER_STORE_TEST_URL"]
        else {
            throw XCTSkip("Run scripts/test_store_integration.sh to start the isolated Worker")
        }
        let endpoint = try XCTUnwrap(URL(string: address))
        XCTAssertEqual(endpoint.scheme, "http")
        XCTAssertEqual(endpoint.host, "127.0.0.1")
        guard endpoint.scheme == "http", endpoint.host == "127.0.0.1" else {
            throw URLError(.unsupportedURL)
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreIntegrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Integration test cleanup failed: \(error)") }
        }
        let defaults = UserDefaults.standard
        let previousArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let previousPreferences = defaults.persistentDomain(forName: domain)
        defaults.setVolatileDomain(previousArguments.merging([
            PrefsKey.libraryVideoPaths: [String](), PrefsKey.registeredVideoPaths: [String](),
            PrefsKey.lockScreenSyncEnabled: false, PrefsKey.videoPath: ""
        ]) { _, isolated in isolated }, forName: UserDefaults.argumentDomain)
        defer {
            defaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain)
            if let preferences = previousPreferences {
                defaults.setPersistentDomain(preferences, forName: domain)
            } else {
                defaults.removePersistentDomain(forName: domain)
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RejectExternalStoreRequests.self]
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var external =
            try URLRequest(url: XCTUnwrap(URL(string: "https://must-not-connect.invalid/upload")))
        external.httpMethod = "PUT"
        do {
            _ = try await session.upload(for: external, from: Data([1]))
            XCTFail("External uploads must be blocked")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .unsupportedURL)
        }
        let source = WallpaperModel()
        let recipient = WallpaperModel()
        defer {
            for model in [source, recipient] {
                for path in model.sceneDocumentsByPath.keys {
                    model.cancelSceneBake(path: path)
                }
                model.stopAllPlayers()
                model.stopAllDedicatedPlayers()
            }
        }
        let video = root.appendingPathComponent("scene-\(UUID().uuidString).mp4")
        let context = try XCTUnwrap(try CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try XCTUnwrap(context.makeImage())
        let file = try SceneStore.writeImage(image, prefix: "layer", videoPath: video.path)
        var layer = SceneLayer(name: "integration-layer", imageFile: file)
        var effect = SceneEffect(kind: .waves)
        effect.maskFile = try SceneStore.writePaintImage(
            [UInt8](repeating: 128, count: 64 * 48),
            width: 64,
            height: 48,
            target: .mask,
            videoPath: video.path
        )
        layer.effects = [effect]
        layer.transform.offsetX = 0.1
        layer.transform.rotation = 15
        layer.opacity = 0.6
        var scene = SceneDocument(canvasWidth: 64, canvasHeight: 48, layers: [layer])
        scene.loopSeconds = 1
        try SceneStore.save(scene, videoPath: video.path)
        try await SceneVideoBaker.bake(document: scene, videoPath: video.path, to: video) { _ in }
        source.registerImportedScene(scene, path: video.path)
        source.libraryVideoPaths = [video.path]
        source.registeredVideoPaths = [video.path]
        scene.layers[0].opacity = 0.4
        source.updateScene(scene, path: video.path)
        let cache = DiskThumbnailCache()
        cache.initializationState = .ready
        let result = try await StoreClient(
            packageExporter: PackageExporter(),
            session: session,
            baseURL: endpoint
        ).submit(
            model: source, videoPath: video.path, title: "Scene integration",
            author: "Integration test",
            license: "CC0", thumbnailCache: cache
        )
        XCTAssertEqual(result.status, "requested")
        XCTAssertNil(result.downloadURL)
        XCTAssertFalse(result.withdrawToken.isEmpty)
        let importer = PackageImporter(videosDirectory: root.appendingPathComponent("imported"))
        let catalog = StoreCatalogController(
            session: session,
            baseURL: endpoint,
            packageImporter: importer
        )
        await catalog.reload()
        XCTAssertNil(catalog.errorMessage)
        XCTAssertTrue(catalog.entries.isEmpty)
        let (_, pendingResponse) = try await session
            .data(from: endpoint.appendingPathComponent("download/\(result.id)"))
        XCTAssertEqual((pendingResponse as? HTTPURLResponse)?.statusCode, 404)
        var approve = URLRequest(url: endpoint
            .appendingPathComponent("admin/entries/\(result.id)/approve"))
        approve.httpMethod = "POST"
        let (_, unauthorized) = try await session.data(for: approve)
        XCTAssertEqual((unauthorized as? HTTPURLResponse)?.statusCode, 401)
        approve.setValue("integration-admin", forHTTPHeaderField: "x-admin-key")
        let (_, approved) = try await session.data(for: approve)
        XCTAssertEqual((approved as? HTTPURLResponse)?.statusCode, 200)
        await catalog.reload()
        XCTAssertNil(catalog.errorMessage)
        let entry = try XCTUnwrap(catalog.entries.first)
        XCTAssertEqual(entry.id, result.id)
        XCTAssertEqual(entry.title, "Scene integration")
        XCTAssertEqual(entry.license, "CC0")
        XCTAssertEqual(URL(string: entry.downloadURL)?.host, "127.0.0.1")
        XCTAssertNotNil(entry.thumbnailURL)
        let (thumbnail, thumbnailResponse) = try await session
            .data(from: XCTUnwrap(try URL(string: XCTUnwrap(entry.thumbnailURL))))
        XCTAssertEqual((thumbnailResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertNotNil(NSImage(data: thumbnail))
        let (package, downloadResponse) = try await session
            .data(from: XCTUnwrap(URL(string: entry.downloadURL)))
        XCTAssertEqual((downloadResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(package.count, entry.sizeBytes)
        XCTAssertEqual(
            SHA256.hash(data: package).map { String(format: "%02x", $0) }.joined(),
            entry.sha256
        )
        await catalog.download(entry: entry, into: recipient)
        XCTAssertEqual(catalog.downloadResultMessage, recipient.localizedString("追加しました"))
        let importedPath = try XCTUnwrap(recipient.libraryVideoPaths.first)
        XCTAssertTrue(importedPath.hasPrefix(root.path + "/imported/"))
        let importedScene = try XCTUnwrap(recipient.sceneDocumentsByPath[importedPath])
        XCTAssertEqual(importedScene, scene)
        for name in SceneStore.referencedFiles(of: scene) {
            let originalURL = SceneStore.folderURL(forVideoPath: video.path)
                .appendingPathComponent(name)
            let importedURL = SceneStore.folderURL(forVideoPath: importedPath)
                .appendingPathComponent(name)
            XCTAssertEqual(try Data(contentsOf: originalURL), try Data(contentsOf: importedURL))
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: importedPath))
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, Double(scene.loopSeconds), accuracy: 0.02)
        XCTAssertEqual(entry.durationSeconds ?? 0, duration, accuracy: 0.02)
        let decodedFrame = try XCTUnwrap(VideoFrameCapture.capture(path: importedPath, time: .zero))
        let editedFrame = try SceneRenderer(document: scene, videoPath: video.path).renderStill()
        let actualPixel = try centerPixel(decodedFrame)
        let expectedPixel = try centerPixel(editedFrame)
        for channel in 0 ..< 3 {
            XCTAssertEqual(
                Double(actualPixel[channel]),
                Double(expectedPixel[channel]),
                accuracy: 12
            )
        }

        let entriesBefore = recipient.libraryVideoPaths
        let incorrect = StoreEntry(
            id: entry.id, title: entry.title, author: entry.author, description: entry.description,
            sha256: String(repeating: "0", count: 64), sizeBytes: entry.sizeBytes,
            durationSeconds: entry.durationSeconds, hasAudio: entry.hasAudio,
            license: entry.license,
            createdAt: entry.createdAt, downloadCount: entry.downloadCount,
            downloadURL: entry.downloadURL, thumbnailURL: entry.thumbnailURL
        )
        await catalog.download(entry: incorrect, into: recipient)
        XCTAssertEqual(
            catalog.downloadResultMessage,
            StoreClientError.checksumMismatch.localizedDescription
        )
        XCTAssertEqual(recipient.libraryVideoPaths, entriesBefore)
        let (stats, _) = try await session
            .data(from: endpoint.appendingPathComponent("__test/stats"))
        let counts = try XCTUnwrap(JSONSerialization.jsonObject(with: stats) as? [String: Int])
        XCTAssertEqual(counts["uploads"], 2)
        XCTAssertEqual(counts["pendingUploads"], 0)
    }

    private func centerPixel(_ image: CGImage) throws -> [UInt8] {
        let pixel = try XCTUnwrap(image.cropping(to: CGRect(
            x: image.width / 2,
            y: image.height / 2,
            width: 1,
            height: 1
        )))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
}

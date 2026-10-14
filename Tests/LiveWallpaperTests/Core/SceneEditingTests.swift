import AppKit
import AVFoundation
import CryptoKit
@testable import LiveWallpaper
import Metal
import XCTest

@MainActor
final class SceneEditingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneEditingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func makeScene(videoURL: URL) throws -> SceneDocument {
        var pixels = [UInt8](repeating: 255, count: 64 * 64 * 4)
        for y in 0 ..< 64 {
            for x in 0 ..< 64 {
                let index = (y * 64 + x) * 4
                pixels[index] = UInt8(x * 4)
                pixels[index + 1] = UInt8(y * 4)
                pixels[index + 2] = 0
            }
        }
        let image = CGImage(
            width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )!
        let file = try SceneStore.writeImage(image, prefix: "layer", videoPath: videoURL.path)
        var layer = SceneLayer(name: "gradient", imageFile: file)
        layer.effects = [SceneEffect(kind: .spin)]
        return SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [layer])
    }

    private func frame(_ renderer: SceneRenderer, time: Double) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let command = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
        try renderer.encode(
            into: texture,
            commandBuffer: command,
            input: SceneFrameInput(time: time)
        )
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        texture.getBytes(
            &pixels,
            bytesPerRow: 256,
            from: MTLRegionMake2D(0, 0, 64, 64),
            mipmapLevel: 0
        )
        return pixels
    }

    func testSoftMaskedSpinHasNoJumpAtLoopBoundary() throws {
        let video = directory.appendingPathComponent("spin.mp4")
        var scene = try makeScene(videoURL: video)
        scene.layers[0].effects[0].maskFile = try SceneStore.writePaintImage(
            [UInt8](repeating: 128, count: 64 * 64), width: 64, height: 64,
            target: .mask, videoPath: video.path
        )
        let renderer = try SceneRenderer(document: scene, videoPath: video.path)
        for singlePass in [true, false] {
            renderer.allowsSinglePassComposite = singlePass
            let first = try frame(renderer, time: 0)
            let last = try frame(renderer, time: Double(scene.loopSeconds) - 1.0 / 60)
            var totalDifference = 0
            for (a, b) in zip(first, last) {
                totalDifference += abs(Int(a) - Int(b))
            }
            let meanDifference = Double(totalDifference) / Double(first.count)
            XCTAssertLessThan(
                meanDifference,
                1,
                "Loop seam must be comparable to a normal frame step"
            )
        }
    }

    func testCancellingBakeAfterLastFramePreservesNewerVideo() async throws {
        let video = directory.appendingPathComponent("cancel.mp4")
        var scene = try makeScene(videoURL: video)
        scene.loopSeconds = 2
        let oldScene = scene
        let lastFrame = expectation(description: "Old bake rendered its last frame")
        let release = DispatchSemaphore(value: 0)
        let oldBake = Task {
            try await SceneVideoBaker
                .bake(document: oldScene, videoPath: video.path, to: video) { progress in
                    if progress == 1 {
                        lastFrame.fulfill()
                        release.wait()
                    }
                }
        }
        defer { release.signal(); oldBake.cancel() }
        await fulfillment(of: [lastFrame], timeout: 10)
        oldBake.cancel()
        scene.loopSeconds = 1
        try await SceneVideoBaker.bake(document: scene, videoPath: video.path, to: video) { _ in }
        let newerBytes = try Data(contentsOf: video)
        release.signal()
        do {
            try await oldBake.value
            XCTFail("Cancelled bake must throw")
        } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: video), newerBytes)
        let duration = try await AVURLAsset(url: video).load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.01)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testCancelledStillBakeLeavesExistingVideoUntouched() async throws {
        let video = directory.appendingPathComponent("still.mp4")
        var scene = try makeScene(videoURL: video)
        scene.layers[0].effects = []
        let previous = Data("existing video".utf8)
        try previous.write(to: video)
        let stillScene = scene
        let task = Task {
            try await SceneVideoBaker
                .bake(document: stillScene, videoPath: video.path, to: video) { _ in }
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled still bake must throw")
        } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: video), previous)
    }

    private final class WeakLayer { weak var value: SceneMetalLayer? }

    private func disposedPreview(scene: SceneDocument, path: String) -> WeakLayer {
        let reference = WeakLayer()
        autoreleasepool {
            let preview = ScenePreviewNSView(frame: .zero)
            preview.show(scene, videoPath: path)
            reference.value = preview.sceneLayer
            XCTAssertNotNil(reference.value?.renderer)
        }
        return reference
    }

    func testDisposedAnimatedPreviewReleasesItsLayer() async throws {
        let video = directory.appendingPathComponent("preview.mp4")
        let scene = try makeScene(videoURL: video)
        let reference = disposedPreview(scene: scene, path: video.path)
        for _ in 0 ..< 20 where reference.value != nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(reference.value)
    }

    func testForegroundKeepsPlacementAndMotionWithIndependentSelection() throws {
        let video = directory.appendingPathComponent("separate.mp4")
        var layer = try makeScene(videoURL: video).layers[0]
        layer.transform.offsetX = 0.2
        layer.transform.offsetY = -0.1
        layer.transform.scale = 0.6
        layer.transform.rotation = 35
        layer.opacity = 0.4
        layer.parallaxDepth = 0.7
        layer.isVisible = false
        layer.cursorMask = SceneCursorMask()
        layer.keyframes = [
            SceneKeyframe(time: 0, transform: layer.transform, opacity: 0.3),
            SceneKeyframe(time: 0.5, transform: .identity, opacity: 0.8)
        ]
        layer.effects[0].pins = [ScenePin(x: 0.4, y: 0.5, isAnchor: true)]
        let foreground = layer.separatedForeground(name: "subject", imageFile: "foreground.png")
        XCTAssertNotEqual(foreground.id, layer.id)
        XCTAssertEqual(foreground.transform, layer.transform)
        XCTAssertEqual(foreground.opacity, layer.opacity)
        XCTAssertEqual(foreground.parallaxDepth, layer.parallaxDepth)
        XCTAssertEqual(foreground.isVisible, layer.isVisible)
        XCTAssertEqual(foreground.cursorMask, layer.cursorMask)
        for phase in [0.0, 0.25, 0.5, 0.75] {
            XCTAssertEqual(foreground.pose(at: phase).transform, layer.pose(at: phase).transform)
            XCTAssertEqual(foreground.pose(at: phase).opacity, layer.pose(at: phase).opacity)
        }
        XCTAssertNotEqual(foreground.keyframes[0].id, layer.keyframes[0].id)
        XCTAssertNotEqual(foreground.effects[0].id, layer.effects[0].id)
        XCTAssertNotEqual(foreground.effects[0].pins[0].id, layer.effects[0].pins[0].id)
    }

    private final class RewritingFileManager: FileManager, @unchecked Sendable {
        let source: URL
        init(source: URL) {
            self.source = source; super.init()
        }

        override func copyItem(atPath srcPath: String, toPath dstPath: String) throws {
            try super.copyItem(atPath: srcPath, toPath: dstPath)
            if srcPath == source.path {
                try Data("newer source with a different size".utf8).write(
                    to: source,
                    options: .atomic
                )
            }
        }
    }

    func testSingleAndBulkPackagesDescribeCopiedVideoAfterSourceChanges() async throws {
        let source = directory.appendingPathComponent("source.mp4")
        let original = Data("original video".utf8)
        let exporter = PackageExporter(fileManager: RewritingFileManager(source: source))
        let model = WallpaperModel()
        try original.write(to: source)
        model.libraryVideoPaths = []
        model.playlists = []
        model.selectedPlaylistID = nil
        XCTAssertTrue(model.addVideoPathToLibrary(source.path))
        for bulk in [false, true] {
            try original.write(to: source)
            let packageURL: URL
            if bulk {
                packageURL = directory.appendingPathComponent("bulk.lwpkg")
                try await exporter.exportPackage(
                    model: model,
                    includeVideos: true,
                    outputURL: packageURL
                )
            } else {
                packageURL = try await exporter.exportSingleWallpaperPackage(
                    model: model, videoPath: source.path, outputFolderURL: directory,
                    baseFileName: "single"
                )
            }
            let extracted = try extract(packageURL)
            let manifest = try JSONDecoder().decode(
                PackageManifest.self,
                from: Data(contentsOf: extracted.appendingPathComponent("metadata.json"))
            )
            let entry = try XCTUnwrap(manifest.videos.first)
            let packed = try Data(contentsOf: extracted
                .appendingPathComponent("videos/\(entry.id).mp4"))
            XCTAssertEqual(packed, original)
            XCTAssertEqual(entry.source.size, UInt64(packed.count))
            XCTAssertEqual(
                entry.sha256,
                SHA256.hash(data: packed).map { String(format: "%02x", $0) }.joined()
            )
            XCTAssertEqual(manifest.packaging.packageSizeBytes, UInt64(packed.count))
            XCTAssertNotEqual(try Data(contentsOf: source), packed)
        }
    }

    func testExportBakesPendingSceneFromCapturedAssets() async throws {
        let video = directory.appendingPathComponent("pending.mp4")
        var scene = try makeScene(videoURL: video)
        scene.loopSeconds = 1
        try SceneStore.save(scene, videoPath: video.path)
        try Data("old baked video".utf8).write(to: video)
        let model = WallpaperModel()
        model.registerImportedScene(scene, path: video.path)
        scene.layers[0].opacity = 0.4
        model.updateScene(scene, path: video.path)
        defer {
            model.cancelSceneBake(path: video.path)
            model.discardSceneSave(path: video.path)
        }
        let packageURL = try await PackageExporter().exportSingleWallpaperPackage(
            model: model, videoPath: video.path, outputFolderURL: directory, baseFileName: "pending"
        )
        let extracted = try extract(packageURL)
        let manifest = try JSONDecoder().decode(
            PackageManifest.self,
            from: Data(contentsOf: extracted.appendingPathComponent("metadata.json"))
        )
        let entry = try XCTUnwrap(manifest.videos.first)
        XCTAssertEqual(entry.scene, true)
        let restored = try JSONDecoder().decode(
            SceneDocument.self,
            from: Data(contentsOf: extracted
                .appendingPathComponent("scenes/\(entry.id)/scene.json"))
        )
        XCTAssertEqual(restored, scene)
        let packedURL = extracted.appendingPathComponent("videos/\(entry.id).mp4")
        let playable = try await AVURLAsset(url: packedURL).load(.isPlayable)
        XCTAssertTrue(playable)
        XCTAssertEqual(
            entry.sha256,
            try SHA256.hash(data: Data(contentsOf: packedURL)).map { String(format: "%02x", $0) }
                .joined()
        )
    }

    private func extract(_ package: URL) throws -> URL {
        let output = directory.appendingPathComponent(UUID().uuidString)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", package.path, output.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return output.appendingPathComponent("content")
    }
}

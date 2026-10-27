import AppKit
@testable import LiveWallpaper
import XCTest

@MainActor
final class SceneAsyncSaveTests: XCTestCase {
    private var directory: URL!
    private var video: URL!
    private var model: WallpaperModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneAsyncSaveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        video = directory.appendingPathComponent("scene.mp4")
        let scene = SceneDocument(canvasWidth: 8, canvasHeight: 8, layers: [
            SceneLayer(name: "bottom", imageFile: try writeImage()),
            SceneLayer(name: "top", imageFile: try writeImage())
        ])
        try SceneStore.save(scene, videoPath: video.path)
        model = WallpaperModel()
        model.registerImportedScene(scene, path: video.path)
    }

    override func tearDownWithError() throws {
        model.cancelSceneBake(path: video.path)
        model.discardSceneSave(path: video.path)
        try FileManager.default.removeItem(at: directory)
    }

    private func writeImage() throws -> String {
        let image = CGImage(
            width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(repeating: 200, count: 8 * 8 * 4) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )!
        return try SceneStore.writeImage(image, prefix: "layer", videoPath: video.path)
    }

    private var scene: SceneDocument {
        model.sceneDocumentsByPath[video.path]!
    }

    private func fileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(
            atPath: SceneStore.folderURL(forVideoPath: video.path).appendingPathComponent(name).path
        )
    }

    func testAsyncSaveOffloadsEncodeAndWrite() throws {
        var edited = scene
        edited.layers[1].opacity = 0.42
        model.updateScene(edited, path: video.path)

        XCTAssertTrue(model.scenesSaving.contains(video.path))

        model.flushSceneSave(path: video.path)

        XCTAssertFalse(model.scenesSaving.contains(video.path))
        let loaded = try XCTUnwrap(SceneStore.load(videoPath: video.path))
        XCTAssertEqual(loaded.layers[1].opacity, 0.42)
    }

    func testFlushSceneSaveGuaranteesDiskPersistenceAndImmediateStatus() throws {
        var edited = scene
        edited.canvasWidth = 128
        edited.canvasHeight = 96
        model.updateScene(edited, path: video.path)

        model.flushSceneSave(path: video.path)

        XCTAssertFalse(model.scenesSaving.contains(video.path))
        XCTAssertNil(model.sceneSaveFailures[video.path])
        let loaded = try XCTUnwrap(SceneStore.load(videoPath: video.path))
        XCTAssertEqual(loaded.canvasWidth, 128)
        XCTAssertEqual(loaded.canvasHeight, 96)
    }

    func testRapidEditsSupersedeOlderGenerations() throws {
        for val in [0.9, 0.8, 0.7, 0.6, 0.25] {
            var edited = scene
            edited.layers[1].opacity = val
            model.updateScene(edited, path: video.path)
            model.retrySceneSave(path: video.path)
        }

        model.flushSceneSave(path: video.path)

        XCTAssertFalse(model.scenesSaving.contains(video.path))
        let loaded = try XCTUnwrap(SceneStore.load(videoPath: video.path))
        XCTAssertEqual(loaded.layers[1].opacity, 0.25)
    }

    func testDiscardSceneSavePreventsLateWrites() throws {
        var edited = scene
        edited.layers[1].opacity = 0.11
        model.updateScene(edited, path: video.path)
        model.retrySceneSave(path: video.path)

        model.discardSceneSave(path: video.path)
        let folder = SceneStore.folderURL(forVideoPath: video.path)
        try FileManager.default.removeItem(at: folder)

        model.flushAllSceneSaves()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testPruningRemovesUnusedFilesOffMainActor() throws {
        let folder = SceneStore.folderURL(forVideoPath: video.path)
        let unreferenced = folder.appendingPathComponent("garbage.png")
        try Data("dummy".utf8).write(to: unreferenced)
        let sidecar = folder.appendingPathComponent("properties.json")
        try Data("[]".utf8).write(to: sidecar)

        XCTAssertTrue(FileManager.default.fileExists(atPath: unreferenced.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))

        model.pruneSceneFiles(scene, path: video.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: unreferenced.path), "unreferenced file should be removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path), "properties sidecar should be kept")
        XCTAssertTrue(fileExists(scene.layers[0].imageFile), "scene layers should be kept")
    }

    func testPruningPreservesComparisonAndHistorySnapshots() throws {
        model.recordSceneComparison(path: video.path)
        let removed = scene.layers[1]
        model.removeSceneLayer(id: removed.id, path: video.path)

        // Clear undo history so only comparison snapshot retains the layer
        model.sceneHistories[video.path] = EditHistory()

        model.pruneSceneFiles(scene, path: video.path)

        XCTAssertTrue(fileExists(removed.imageFile), "comparison snapshot protects removed layer image")
    }

    func testRetainedFileSurvivesPruningUntilReleased() throws {
        let folder = SceneStore.folderURL(forVideoPath: video.path)
        let trialFile = folder.appendingPathComponent("trial_layer.png")
        try Data("trial".utf8).write(to: trialFile)

        model.retainSceneFile(trialFile)
        model.pruneSceneFiles(scene, path: video.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trialFile.path), "retained file survives pruning")

        model.releaseSceneFile(trialFile)
        model.pruneSceneFiles(scene, path: video.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trialFile.path), "released file is pruned")
    }

    func testQuantitativeMeasurementReal3662790108() throws {
        let realPath = ("~/Library/Application Support/we-import/Wallpapers/we-3662790108/wallpaper.mp4" as NSString).expandingTildeInPath
        let folder = SceneStore.folderURL(forVideoPath: realPath)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("scene.json").path) else {
            return
        }

        let document = try XCTUnwrap(SceneStore.load(videoPath: realPath))

        // Measure old synchronous cost: encode time
        let encodeStart = CFAbsoluteTimeGetCurrent()
        let encodedData = try SceneStore.encode(document)
        let encodeDurationMs = (CFAbsoluteTimeGetCurrent() - encodeStart) * 1000

        // Measure old synchronous cost: prune analysis time on real directory
        let pruneStart = CFAbsoluteTimeGetCurrent()
        let inUsePaths = Set<String>()
        var used = SceneStore.referencedFiles(of: document)
        used.insert("scene.json")
        used.insert("properties.json")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        _ = names.filter { !used.contains($0) && !$0.hasPrefix(".") }
            .map { folder.appendingPathComponent($0) }
            .filter { !inUsePaths.contains($0.path) }
        let pruneDurationMs = (CFAbsoluteTimeGetCurrent() - pruneStart) * 1000

        // Measure new asynchronous MainActor blocking cost in WallpaperModel
        let tempVideo = directory.appendingPathComponent("benchmark_3662790108.mp4")
        let testModel = WallpaperModel()
        testModel.registerImportedScene(document, path: tempVideo.path)

        var edited = document
        edited.canvasWidth += 1

        let mainThreadStart = CFAbsoluteTimeGetCurrent()
        testModel.updateScene(edited, path: tempVideo.path, coalescing: false)
        testModel.retrySceneSave(path: tempVideo.path)
        let mainThreadDurationMs = (CFAbsoluteTimeGetCurrent() - mainThreadStart) * 1000

        // Flush and verify data integrity
        testModel.flushSceneSave(path: tempVideo.path)
        let loaded = try XCTUnwrap(SceneStore.load(videoPath: tempVideo.path))
        XCTAssertEqual(loaded.canvasWidth, document.canvasWidth + 1)
        XCTAssertEqual(loaded.layers.count, document.layers.count)

        print("""
        [QUANTITATIVE_MEASUREMENT_3662790108]
        Document size: \(encodedData.count) bytes
        Files in directory: \(names.count)
        Old MainActor Blocking Time (Encode): \(String(format: "%.2f", encodeDurationMs)) ms
        Old MainActor Blocking Time (Prune):  \(String(format: "%.2f", pruneDurationMs)) ms
        Old Total MainActor Freeze:           \(String(format: "%.2f", encodeDurationMs + pruneDurationMs)) ms
        New MainActor Blocking Time:          \(String(format: "%.2f", mainThreadDurationMs)) ms
        MainActor Freeze Reduction:           \(String(format: "%.1f", (encodeDurationMs + pruneDurationMs) / max(mainThreadDurationMs, 0.01)))x
        """)
    }
}

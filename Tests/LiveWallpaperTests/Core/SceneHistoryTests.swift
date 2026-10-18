import AppKit
@testable import LiveWallpaper
import XCTest

@MainActor
final class SceneHistoryTests: XCTestCase {
    private var directory: URL!
    private var video: URL!
    private var model: WallpaperModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneHistoryTests-\(UUID().uuidString)")
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

    private func edit(_ change: (inout SceneDocument) -> Void) {
        var document = scene
        change(&document)
        model.updateScene(document, path: video.path)
    }

    private func fileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(
            atPath: SceneStore.folderURL(forVideoPath: video.path).appendingPathComponent(name).path
        )
    }

    func testOneDragIsOneStepAndTheNextDragIsAnother() {
        for value in [0.9, 0.7, 0.5] {
            edit { $0.layers[1].opacity = value }
        }
        model.breakSceneHistoryCoalescing()
        for value in [0.4, 0.2] {
            edit { $0.layers[1].opacity = value }
        }

        model.undoScene(path: video.path)
        XCTAssertEqual(scene.layers[1].opacity, 0.5)
        model.undoScene(path: video.path)
        XCTAssertEqual(scene.layers[1].opacity, 1)
        XCTAssertFalse(model.canUndoScene(path: video.path))

        model.redoScene(path: video.path)
        XCTAssertEqual(scene.layers[1].opacity, 0.5)
        model.flushSceneSave(path: video.path)
        XCTAssertEqual(try SceneStore.load(videoPath: video.path), scene)
    }

    func testSavingWaitsForEditsAndWritesTheLatest() throws {
        let saved = try SceneStore.load(videoPath: video.path)
        for value in stride(from: 0.9, through: 0.1, by: -0.1) {
            edit { $0.layers[1].opacity = value }
        }
        XCTAssertEqual(try SceneStore.load(videoPath: video.path), saved, "a drag is not written per step")
        XCTAssertTrue(model.scenesSaving.contains(video.path))

        model.flushSceneSave(path: video.path)
        XCTAssertEqual(try SceneStore.load(videoPath: video.path), scene)
    }

    func testPruningLeavesWritesInProgressAlone() throws {
        let partial = SceneStore.folderURL(forVideoPath: video.path).appendingPathComponent(".scene.json.partial")
        try Data("{".utf8).write(to: partial)
        edit { $0.layers[1].opacity = 0.3 }
        model.flushSceneSave(path: video.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
    }

    func testRemovedSceneIsNotWrittenBack() {
        edit { $0.layers[1].opacity = 0.3 }
        model.discardSceneSave(path: video.path)
        try? FileManager.default.removeItem(at: SceneStore.folderURL(forVideoPath: video.path))

        model.flushAllSceneSaves()
        XCTAssertFalse(FileManager.default.fileExists(atPath: SceneStore.folderURL(forVideoPath: video.path).path))
    }

    func testEditsToDifferentFieldsAreSeparateSteps() {
        edit { $0.layers[1].opacity = 0.5 }
        edit { $0.layers[0].opacity = 0.5 }

        model.undoScene(path: video.path)
        XCTAssertEqual(scene.layers[0].opacity, 1)
        XCTAssertEqual(scene.layers[1].opacity, 0.5)
    }

    func testNewEditAfterUndoDropsRedo() {
        edit { $0.layers[1].opacity = 0.5 }
        model.undoScene(path: video.path)
        XCTAssertTrue(model.canRedoScene(path: video.path))

        edit { $0.loopSeconds = 10 }
        XCTAssertFalse(model.canRedoScene(path: video.path))
    }

    func testUndoingLayerRemovalBringsBackItsImage() {
        let removed = scene.layers[1]
        model.removeSceneLayer(id: removed.id, path: video.path)
        XCTAssertTrue(fileExists(removed.imageFile), "history still needs the image")

        model.undoScene(path: video.path)
        XCTAssertEqual(scene.layers.last, removed)
    }

    func testEachPaintedStrokeIsAStepAndKeepsEarlierMasks() throws {
        let layerID = scene.layers[1].id
        edit { $0.layers[1].effects = [SceneEffect(kind: .sway)] }
        let effectID = scene.layers[1].effects[0].id
        var files: [String] = []
        for value: UInt8 in [100, 200] {
            let file = try SceneStore.writePaintImage(
                [UInt8](repeating: value, count: 64), width: 8, height: 8, target: .mask, videoPath: video.path
            )
            files.append(file)
            model.setScenePaintFile(file, kind: .mask, effectID: effectID, layerID: layerID, path: video.path)
        }

        model.undoScene(path: video.path)
        XCTAssertEqual(scene.layers[1].effects[0].maskFile, files[0])
        XCTAssertTrue(fileExists(files[0]))
        XCTAssertTrue(fileExists(files[1]), "redo still needs the later stroke")
    }
    func testDuplicateIsIndependentAndOneStep() throws {
        edit { $0.layers[1].effects = [SceneEffect(kind: .puppet)] }
        edit { $0.layers[1].effects[0].pins = [ScenePin(x: 0.2, y: 0.2, isAnchor: true)] }
        let original = scene.layers[1]
        let copyID = try XCTUnwrap(model.duplicateSceneLayer(id: original.id, path: video.path))

        let copy = try XCTUnwrap(scene.layers.first { $0.id == copyID })
        XCTAssertEqual(scene.layers.firstIndex { $0.id == copyID }, 2, "the copy goes right above")
        XCTAssertNotEqual(copy.effects[0].id, original.effects[0].id)
        XCTAssertNotEqual(copy.effects[0].pins[0].id, original.effects[0].pins[0].id)
        edit { $0.layers[2].effects[0].strength = 0.9 }
        XCTAssertEqual(scene.layers[1], original)

        model.undoScene(path: video.path)
        model.undoScene(path: video.path)
        XCTAssertFalse(scene.layers.contains { $0.id == copyID })
    }

    func testMovingALayerPutsItAtTheDestination() {
        let bottom = scene.layers[0].id
        model.moveSceneLayer(id: bottom, to: 1, path: video.path)
        XCTAssertEqual(scene.layers.last?.id, bottom)
    }

    func testComparisonKeepsItsImagesAfterTheLayerIsGone() {
        model.recordSceneComparison(path: video.path)
        let removed = scene.layers[1]
        model.removeSceneLayer(id: removed.id, path: video.path)
        // Leaves the undo history, which also protects the image.
        model.sceneHistories[video.path] = EditHistory()
        edit { $0.layers[0].opacity = 0.5 }
        model.flushSceneSave(path: video.path)
        XCTAssertTrue(fileExists(removed.imageFile))
    }

    func testScenesSavedBeforeLockingOpenUnlocked() throws {
        let json = #"{"id":"6F1C2A4E-9D38-4B57-9C3A-1E2D3F4A5B6C","name":"old","imageFile":"a.png"}"#
        let layer = try JSONDecoder().decode(SceneLayer.self, from: Data(json.utf8))
        XCTAssertFalse(layer.isLocked)
    }

    func testRenamingOrLockingLeavesTheVideoCurrent() {
        edit { $0.layers[1].name = "renamed" }
        edit { $0.layers[1].isLocked = true }
        XCTAssertFalse(model.sceneStaleVideoPaths.contains(video.path))
        XCTAssertFalse(model.scenesBaking.contains(video.path))
    }

    /// Edits only mark the video out of date; the desktop draws the scene live. The
    /// video is baked once the scene is chosen for the lock screen or screen saver.
    func testEditsBakeOnlyForTheLockScreenOrScreenSaver() {
        edit { $0.layers[1].opacity = 0.5 }
        XCTAssertTrue(model.sceneStaleVideoPaths.contains(video.path))
        XCTAssertFalse(model.scenesBaking.contains(video.path))

        model.lockScreenVideoPath = video.path
        XCTAssertTrue(model.scenesBaking.contains(video.path))
        model.cancelSceneBake(path: video.path)
        model.lockScreenVideoPath = nil

        model.screenSaverVideoPath = video.path
        XCTAssertTrue(model.scenesBaking.contains(video.path))
        model.cancelSceneBake(path: video.path)
        model.screenSaverVideoPath = nil

        edit { $0.layers[1].opacity = 0.25 }
        XCTAssertFalse(model.scenesBaking.contains(video.path))
    }
}

import Foundation
@testable import LiveWallpaper
import XCTest

@MainActor
final class SceneSavePruningRegressionTests: XCTestCase {
    private var directory: URL!
    private var video: URL!
    private var model: WallpaperModel!
    private var document: SceneDocument!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SceneSavePruning-\(UUID().uuidString)")
        video = directory.appendingPathComponent("scene.mp4")
        var layer = SceneLayer(name: "model", imageFile: "")
        layer.kind = .model
        layer.model = SceneStaticModel(material: 0, components: 1,
                                       vertices: Data(repeating: 0, count: 12_000_000), indices: Data())
        document = SceneDocument(canvasWidth: 32, canvasHeight: 32, layers: [layer])
        try SceneStore.save(document, videoPath: video.path)
        model = WallpaperModel()
        model.registerImportedScene(document, path: video.path)
    }

    override func tearDownWithError() throws {
        model.discardSceneSave(path: video.path)
        model.cancelSceneBake(path: video.path)
        try FileManager.default.removeItem(at: directory)
    }

    private func writeTrialFile() throws -> URL {
        let file = SceneStore.folderURL(forVideoPath: video.path).appendingPathComponent("trial.png")
        try Data([1, 2, 3]).write(to: file)
        model.retainSceneFile(file)
        return file
    }

    func testFlushPreservesFileRetainedAfterSaveStarted() throws {
        model.retrySceneSave(path: video.path)
        let trial = try writeTrialFile()
        model.flushSceneSave(path: video.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trial.path))
        XCTAssertEqual(model.sceneFilesInUse[trial.path], 1)

        model.releaseSceneFile(trial)
        model.pruneSceneFiles(document, path: video.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trial.path))
    }

    func testBackgroundCompletionPreservesNewlyRetainedFile() async throws {
        model.retrySceneSave(path: video.path)
        let trial = try writeTrialFile()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while model.scenesSaving.contains(video.path), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.scenesSaving.contains(video.path))
        XCTAssertNil(model.sceneSaveFailures[video.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: trial.path))
        model.releaseSceneFile(trial)
    }

    func testManualPruneDefersDeletionUntilPendingSaveSucceeds() throws {
        let oldFile = SceneStore.folderURL(forVideoPath: video.path).appendingPathComponent("old.png")
        let newFile = oldFile.deletingLastPathComponent().appendingPathComponent("new.png")
        try Data([1]).write(to: oldFile)
        try Data([2]).write(to: newFile)
        var saved = document!
        saved.layers.append(SceneLayer(name: "image", imageFile: oldFile.lastPathComponent))
        try SceneStore.save(saved, videoPath: video.path)
        model.registerImportedScene(saved, path: video.path)

        var edited = saved
        edited.layers[1].imageFile = newFile.lastPathComponent
        model.updateScene(edited, path: video.path, coalescing: false)
        model.sceneHistories[video.path] = EditHistory()
        model.pruneSceneFiles(edited, path: video.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))

        model.flushSceneSave(path: video.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newFile.path))
        let loaded = try XCTUnwrap(SceneStore.load(videoPath: video.path))
        XCTAssertEqual(loaded.layers[1].imageFile, newFile.lastPathComponent)
    }
}

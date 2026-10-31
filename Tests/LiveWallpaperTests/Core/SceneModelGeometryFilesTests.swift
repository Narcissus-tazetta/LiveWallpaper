import Foundation
@testable import LiveWallpaper
import XCTest

final class SceneModelGeometryFilesTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SceneModelGeometryFiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func document(vertexBytes: Int) -> SceneDocument {
        var layer = SceneLayer(name: "model", imageFile: "")
        layer.kind = .model
        let vertices = Data((0 ..< vertexBytes).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        layer.model = SceneStaticModel(material: 0, components: 1, vertices: vertices, indices: Data(count: 12))
        return SceneDocument(canvasWidth: 32, canvasHeight: 32, layers: [layer])
    }

    private func sceneJSON(_ video: URL) throws -> [String: Any] {
        let url = SceneStore.folderURL(forVideoPath: video.path).appendingPathComponent("scene.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func storedModel(_ json: [String: Any]) throws -> [String: Any] {
        let layers = try XCTUnwrap(json["layers"] as? [[String: Any]])
        return try XCTUnwrap(layers.first?["model"] as? [String: Any])
    }

    func testALargeModelIsSavedBesideSceneJSONAndReadBack() throws {
        let video = directory.appendingPathComponent("a.mp4")
        let original = document(vertexBytes: 200_004)
        try SceneStore.save(original, videoPath: video.path)

        let stored = try storedModel(sceneJSON(video))
        XCTAssertNil(stored["vertices"])
        let names = try XCTUnwrap(stored["geometryFiles"] as? [String: String])
        let folder = SceneStore.folderURL(forVideoPath: video.path)
        for name in names.values {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path))
        }

        let loaded = try XCTUnwrap(SceneStore.load(videoPath: video.path))
        XCTAssertEqual(loaded, original)
        XCTAssertFalse(loaded.hasInlineModelGeometry)
        XCTAssertEqual(SceneStore.referencedFiles(of: loaded), Set(names.values))
    }

    func testASmallModelStaysInline() throws {
        let video = directory.appendingPathComponent("b.mp4")
        try SceneStore.save(document(vertexBytes: 1200), videoPath: video.path)
        let stored = try storedModel(sceneJSON(video))
        XCTAssertNotNil(stored["vertices"])
        XCTAssertNil(stored["geometryFiles"])
    }

    func testAnInlineSceneMovesItsGeometryAndKeepsItsDate() throws {
        let video = directory.appendingPathComponent("c.mp4")
        let original = document(vertexBytes: 200_004)
        let folder = SceneStore.folderURL(forVideoPath: video.path)
        try SceneStore.write(SceneStore.encode(original, folder: nil), videoPath: video.path)
        let documentURL = folder.appendingPathComponent("scene.json")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: documentURL.path)

        let inline = try XCTUnwrap(SceneStore.load(videoPath: video.path))
        XCTAssertTrue(inline.hasInlineModelGeometry)
        let moved = try SceneStore.movingGeometryToFiles(inline, videoPath: video.path)

        XCTAssertEqual(moved, original)
        XCTAssertFalse(moved.hasInlineModelGeometry)
        XCTAssertNotNil(try storedModel(sceneJSON(video))["geometryFiles"])
        let movedDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: documentURL.path)[.modificationDate] as? Date)
        XCTAssertEqual(movedDate.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }

    func testACopyForAPackageHoldsItsGeometryInline() throws {
        let video = directory.appendingPathComponent("d.mp4")
        let original = document(vertexBytes: 200_004)
        try SceneStore.save(original, videoPath: video.path)
        let copy = directory.appendingPathComponent("copy", isDirectory: true)
        try SceneStore.copyScene(videoPath: video.path, to: copy)

        let names = try FileManager.default.contentsOfDirectory(atPath: copy.path)
        XCTAssertEqual(names, ["scene.json"])
        let decoded = try JSONDecoder().decode(SceneDocument.self, from: Data(contentsOf: copy.appendingPathComponent("scene.json")))
        XCTAssertEqual(decoded, original)
    }

    func testImportingAnInlineSceneStoresItsGeometryInFiles() throws {
        let source = directory.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let original = document(vertexBytes: 200_004)
        try SceneStore.encode(original, folder: nil).write(to: source.appendingPathComponent("scene.json"))
        let video = directory.appendingPathComponent("e.mp4")

        let imported = try SceneStore.importScene(from: source, videoPath: video.path)

        XCTAssertEqual(imported, original)
        XCTAssertFalse(imported.hasInlineModelGeometry)
        let names = try XCTUnwrap(try storedModel(sceneJSON(video))["geometryFiles"] as? [String: String])
        let folder = SceneStore.folderURL(forVideoPath: video.path)
        for name in names.values {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path))
        }
        // A scene folder of the app's own, read again as a package source, brings its files along.
        let again = try SceneStore.importScene(from: folder, videoPath: directory.appendingPathComponent("f.mp4").path)
        XCTAssertEqual(again, original)
    }

    func testGeometryFilesWithoutAFolderDoNotDecode() throws {
        let video = directory.appendingPathComponent("g.mp4")
        try SceneStore.save(document(vertexBytes: 200_004), videoPath: video.path)
        let url = SceneStore.folderURL(forVideoPath: video.path).appendingPathComponent("scene.json")
        XCTAssertThrowsError(try JSONDecoder().decode(SceneDocument.self, from: Data(contentsOf: url)))
    }
}

@testable import LiveWallpaper
import Metal
import simd
import XCTest

final class SceneImportedModelTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("imported-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func bytes(_ floats: [Float]) -> Data {
        floats.withUnsafeBytes { Data($0) }
    }

    /// A unit square facing +z (two triangles, red), optionally turned about y by an animation
    /// of one second on its node.
    private func writeSquare(animated: Bool, extra: [String: Any] = [:]) throws -> URL {
        let positions: [Float] = [-0.5, -0.5, 0, 0.5, -0.5, 0, 0.5, 0.5, 0, -0.5, 0.5, 0]
        let indices: [UInt16] = [0, 1, 2, 0, 2, 3]
        let times: [Float] = [0, 1]
        let half = Float(0.5).squareRoot()
        let rotations: [Float] = [0, 0, 0, 1, 0, half, 0, half]
        var buffer = bytes(positions)
        buffer.append(indices.withUnsafeBytes { Data($0) })
        let timesOffset = buffer.count
        buffer.append(bytes(times))
        buffer.append(bytes(rotations))
        var json: [String: Any] = [
            "asset": ["version": "2.0"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0, "name": "square"]],
            "meshes": [["primitives": [["attributes": ["POSITION": 0], "indices": 1, "material": 0]]]],
            "materials": [["pbrMetallicRoughness": ["baseColorFactor": [1, 0, 0, 1], "metallicFactor": 0, "roughnessFactor": 1]]],
            "buffers": [["byteLength": buffer.count, "uri": "data:application/octet-stream;base64," + buffer.base64EncodedString()]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": 48],
                ["buffer": 0, "byteOffset": 48, "byteLength": 12],
                ["buffer": 0, "byteOffset": timesOffset, "byteLength": 8],
                ["buffer": 0, "byteOffset": timesOffset + 8, "byteLength": 32],
            ],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3", "min": [-0.5, -0.5, 0], "max": [0.5, 0.5, 0]],
                ["bufferView": 1, "componentType": 5123, "count": 6, "type": "SCALAR"],
                ["bufferView": 2, "componentType": 5126, "count": 2, "type": "SCALAR"],
                ["bufferView": 3, "componentType": 5126, "count": 2, "type": "VEC4"],
            ],
        ]
        if animated {
            json["animations"] = [[
                "name": "turn",
                "channels": [["sampler": 0, "target": ["node": 0, "path": "rotation"]]],
                "samplers": [["input": 2, "output": 3]],
            ]]
        }
        json.merge(extra) { _, new in new }
        let url = folder.appendingPathComponent("square.gltf")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return url
    }

    func testAStillSquareBecomesOneShadedPartCentredOnTheCanvas() throws {
        let result = try SceneModelImporter.importModel(at: writeSquare(animated: false), canvasWidth: 1000, canvasHeight: 500)
        XCTAssertNil(result.rig)
        XCTAssertEqual(result.layer.kind, .model)
        let model = try XCTUnwrap(result.layer.model)
        XCTAssertNil(result.layer.modelParts)
        XCTAssertEqual(model.surface?.baseColor, [1, 0, 0, 1])
        XCTAssertEqual(model.shape.indices, [0, 1, 2, 3, 4, 5])
        // No normals in the file: each triangle gets its own corners, facing +z.
        XCTAssertEqual(model.shape.vertices.count, 6 * 6)
        XCTAssertEqual(Array(model.shape.vertices[3 ..< 6]), [0, 0, 1])
        let placement = try XCTUnwrap(result.layer.modelPlacement)
        // 60 % of the shorter fit: the square is 300 pixels at scale 1.
        XCTAssertEqual(placement.unitScale, 300, accuracy: 1e-6)
        XCTAssertEqual(placement.size, [300, 300])
        let world = placement.world(transform: SceneTransform(), canvasWidth: 1000, canvasHeight: 500)
        XCTAssertEqual(world * SIMD4(0.5, 0.5, 0, 1), SIMD4(650, 400, 0, 1))
    }

    func testAnAnimatedNodeBecomesARigWithItsClipSampled() throws {
        let result = try SceneModelImporter.importModel(at: writeSquare(animated: true), canvasWidth: 1000, canvasHeight: 500)
        let rig = try XCTUnwrap(result.rig)
        XCTAssertEqual(result.layer.model?.skeleton, rig.id)
        XCTAssertEqual(rig.skeleton.clips.map(\.name), ["turn"])
        XCTAssertEqual(rig.skeleton.clips[0].frameCount, 30)
        XCTAssertEqual(rig.skeleton.playback.first?.clip, 0)
        // Half way the node has turned 45° about y.
        let pose = try SceneSkeletonEvaluator(rig.skeleton).evaluate(time: 0.5)
        let turned = pose.matrices[0] * SIMD4<Float>(1, 0, 0, 0)
        XCTAssertEqual(turned.x, cos(.pi / 4), accuracy: 1e-3)
        XCTAssertEqual(turned.z, -sin(.pi / 4), accuracy: 1e-3)
    }

    func testAFileThatNeedsAnUnknownExtensionIsRefused() throws {
        let url = try writeSquare(animated: false, extra: ["extensionsRequired": ["KHR_draco_mesh_compression"]])
        XCTAssertThrowsError(try SceneModelImporter.importModel(at: url, canvasWidth: 100, canvasHeight: 100)) { error in
            XCTAssertTrue(error.localizedDescription.contains("KHR_draco_mesh_compression"))
        }
    }

    func testABufferOutsideTheModelsFolderIsRefused() throws {
        let url = try writeSquare(animated: false, extra: ["buffers": [["byteLength": 4, "uri": "../secret.bin"]]])
        XCTAssertThrowsError(try SceneModelImporter.importModel(at: url, canvasWidth: 100, canvasHeight: 100))
    }

    func testMalformedAccessorsAreRefusedInsteadOfTrapping() throws {
        let positions: [Float] = [-0.5, -0.5, 0, 0.5, -0.5, 0, 0.5, 0.5, 0]
        let buffer = bytes(positions)
        func write(_ accessor: [String: Any], view: [String: Any] = [:]) throws -> URL {
            let json: [String: Any] = [
                "asset": ["version": "2.0"],
                "nodes": [["mesh": 0]],
                "meshes": [["primitives": [["attributes": ["POSITION": 0]]]]],
                "buffers": [["byteLength": buffer.count, "uri": "data:application/octet-stream;base64," + buffer.base64EncodedString()]],
                "bufferViews": [["buffer": 0, "byteLength": buffer.count].merging(view) { _, new in new }],
                "accessors": [["bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"].merging(accessor) { _, new in new }],
            ]
            let url = folder.appendingPathComponent("broken-\(UUID().uuidString).gltf")
            try JSONSerialization.data(withJSONObject: json).write(to: url)
            return url
        }
        for url in try [
            write(["count": -1]),
            write(["count": Int.max]),
            write(["byteOffset": -12]),
            write([:], view: ["byteStride": -12]),
            write([:], view: ["byteOffset": Int.max]),
        ] {
            XCTAssertThrowsError(try SceneModelImporter.importModel(at: url, canvasWidth: 100, canvasHeight: 100))
        }
        XCTAssertNoThrow(try SceneModelImporter.importModel(at: write([:]), canvasWidth: 100, canvasHeight: 100))
    }

    func testAnImportedModelSurvivesTheSceneFileAndIsDrawnLit() throws {
        let result = try SceneModelImporter.importModel(at: writeSquare(animated: true), canvasWidth: 200, canvasHeight: 100)
        var document = SceneDocument(canvasWidth: 200, canvasHeight: 100, layers: [result.layer])
        document.rigs[result.rig!.id] = result.rig!.skeleton
        var stage = SceneModelStage()
        stage.lights = [.init(kind: .directional, color: [1, 1, 1], intensity: 1, azimuth: 0, elevation: 0)]
        stage.skyColor = [0, 0, 0]
        stage.groundColor = [0, 0, 0]
        document.modelStage = stage
        let decoded = try JSONDecoder().decode(SceneDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded, document)
        XCTAssertTrue(decoded.isAnimated)

        let videoPath = folder.appendingPathComponent("scene.mp4").path
        let renderer = try SceneRenderer(document: decoded, videoPath: videoPath)
        let image = try renderer.renderStill()
        let pixels = try XCTUnwrap(image.dataProvider?.data as Data?)
        let center = (image.height / 2 * image.bytesPerRow) + image.width / 2 * 4
        // BGRA: a red diffuse square lit head-on by a white light of intensity 1 shows red.
        XCTAssertGreaterThan(pixels[center + 2], 200)
        XCTAssertLessThan(pixels[center + 1], 30)
        let corner = 2 * image.bytesPerRow + 2 * 4
        XCTAssertLessThan(pixels[corner + 2], 30)
    }

    @MainActor
    func testRemovingTheLastImportedModelDropsItsRigAndTheStage() throws {
        let result = try SceneModelImporter.importModel(at: writeSquare(animated: true), canvasWidth: 200, canvasHeight: 100)
        let still = SceneLayer(name: "picture", imageFile: "picture.png")
        var document = SceneDocument(canvasWidth: 200, canvasHeight: 100, layers: [still, result.layer])
        document.rigs[result.rig!.id] = result.rig!.skeleton
        document.modelStage = SceneModelStage()
        XCTAssertTrue(SceneStore.referencedFiles(of: document).contains("picture.png"))
        let path = folder.appendingPathComponent("scene.mp4").path
        try SceneStore.save(document, videoPath: path)
        let model = WallpaperModel()
        model.registerImportedScene(document, path: path)
        defer {
            model.cancelSceneBake(path: path)
            model.discardSceneSave(path: path)
        }
        model.removeSceneLayer(id: result.layer.id, path: path)
        let after = try XCTUnwrap(model.sceneDocumentsByPath[path])
        XCTAssertTrue(after.rigs.isEmpty)
        XCTAssertNil(after.modelStage)
    }
}

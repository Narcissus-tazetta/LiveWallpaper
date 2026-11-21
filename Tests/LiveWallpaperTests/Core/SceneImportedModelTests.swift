@testable import LiveWallpaper
import Metal
import simd
import XCTest

final class SceneImportedModelTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("imported-model-\(UUID().uuidString)")
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
            "meshes": [["primitives": [[
                "attributes": ["POSITION": 0],
                "indices": 1,
                "material": 0
            ]]]],
            "materials": [["pbrMetallicRoughness": [
                "baseColorFactor": [1, 0, 0, 1],
                "metallicFactor": 0,
                "roughnessFactor": 1
            ]]],
            "buffers": [[
                "byteLength": buffer.count,
                "uri": "data:application/octet-stream;base64," + buffer.base64EncodedString()
            ]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": 48],
                ["buffer": 0, "byteOffset": 48, "byteLength": 12],
                ["buffer": 0, "byteOffset": timesOffset, "byteLength": 8],
                ["buffer": 0, "byteOffset": timesOffset + 8, "byteLength": 32]
            ],
            "accessors": [
                [
                    "bufferView": 0,
                    "componentType": 5126,
                    "count": 4,
                    "type": "VEC3",
                    "min": [-0.5, -0.5, 0],
                    "max": [0.5, 0.5, 0]
                ],
                ["bufferView": 1, "componentType": 5123, "count": 6, "type": "SCALAR"],
                ["bufferView": 2, "componentType": 5126, "count": 2, "type": "SCALAR"],
                ["bufferView": 3, "componentType": 5126, "count": 2, "type": "VEC4"]
            ]
        ]
        if animated {
            json["animations"] = [[
                "name": "turn",
                "channels": [["sampler": 0, "target": ["node": 0, "path": "rotation"]]],
                "samplers": [["input": 2, "output": 3]]
            ]]
        }
        json.merge(extra) { _, new in new }
        let url = folder.appendingPathComponent("square.gltf")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return url
    }

    func testMorphCurvePreservesStepAndScalesCubicTangentsByKeyInterval() {
        let step = SceneMorphCurve(times: [0, 2], values: [0, 1], interpolation: "STEP", width: 1)
        XCTAssertTrue(step.isValid)
        XCTAssertEqual(step.sample(at: 1.999), [0])
        XCTAssertEqual(step.sample(at: 2), [1])
        let cubic = SceneMorphCurve(
            times: [0, 2], values: [0, 0, 1, 0, 1, 0], interpolation: "CUBICSPLINE", width: 1
        )
        XCTAssertTrue(cubic.isValid)
        XCTAssertEqual(cubic.sample(at: 1), [0.75])
    }

    func testAnimatedMorphCameraAndLightsFollowTheirImportedClip() throws {
        let url = try writeSquare(animated: false)
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var accessors = try XCTUnwrap(manifest["accessors"] as? [[String: Any]])
        var views = try XCTUnwrap(manifest["bufferViews"] as? [[String: Any]])
        let source = try XCTUnwrap((manifest["buffers"] as? [[String: Any]])?
            .first?["uri"] as? String)
        var binary =
            try XCTUnwrap(try Data(base64Encoded: String(XCTUnwrap(source.split(separator: ",")
                        .last))))
        func accessor(_ values: [Float], width: Int) -> Int {
            let data = bytes(values)
            let index = accessors.count
            accessors.append([
                "bufferView": views.count, "componentType": 5126,
                "type": width == 1 ? "SCALAR" : "VEC3", "count": values.count / width
            ])
            views.append(["buffer": 0, "byteOffset": binary.count, "byteLength": data.count])
            binary.append(data)
            return index
        }
        let delta = accessor(
            Array(repeating: [Float(0.6), 0, 0], count: 4).flatMap { $0 },
            width: 3
        )
        let weights = accessor([0, 1], width: 1)
        let slide = accessor([0, 0, 2, 1, 0, 2], width: 3)
        let extent = "KHR_lights_punctual"
        manifest["scenes"] = [["nodes": [0, 1]]]
        manifest["nodes"] = [
            ["mesh": 0],
            ["camera": 0, "translation": [0, 0, 2], "children": [2]],
            ["extensions": [extent: ["light": 0]], "scale": [2, 1, 1]]
        ]
        manifest["cameras"] = [["type": "orthographic", "orthographic": [
            "xmag": 1, "ymag": 0.5, "znear": 0, "zfar": 10
        ]]]
        manifest["extensions"] = [extent: ["lights": [["type": "spot", "intensity": 32]]]]
        manifest["meshes"] = [["primitives": [[
            "attributes": ["POSITION": 0], "indices": 1, "material": 0,
            "targets": [["POSITION": delta]]
        ]]]]
        manifest["animations"] = [[
            "samplers": [
                ["input": 2, "output": weights],
                ["input": 2, "output": slide],
                ["input": 2, "output": 3]
            ],
            "channels": [
                ["sampler": 0, "target": ["node": 0, "path": "weights"]],
                ["sampler": 1, "target": ["node": 1, "path": "translation"]],
                ["sampler": 2, "target": ["node": 2, "path": "rotation"]]
            ]
        ]]
        manifest["accessors"] = accessors
        manifest["bufferViews"] = views
        manifest["buffers"] = [[
            "byteLength": binary.count,
            "uri": "data:application/octet-stream;base64," + binary.base64EncodedString()
        ]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
        let result = try SceneModelImporter.importModel(
            at: url,
            canvasWidth: 200,
            canvasHeight: 100
        )
        let rig = try XCTUnwrap(result.rig)
        let stage = try XCTUnwrap(result.stage)
        var scene = SceneDocument(canvasWidth: 200, canvasHeight: 100, layers: [result.layer])
        scene.rigs[rig.id] = rig.skeleton
        scene.modelStage = stage
        let restored = try JSONDecoder().decode(
            SceneDocument.self,
            from: JSONEncoder().encode(scene)
        )
        XCTAssertEqual(scene, restored)
        let registry = try SceneSkeletonRegistry(restored.rigs)
        let animated = try stage.posed(rigs: registry, time: 0.5, canvasSize: SIMD2(200, 100))
        XCTAssertEqual(animated.importedCamera?.eye, [130, 50, 120])
        XCTAssertEqual(animated.lights[0].position[0], 0.65, accuracy: 1e-6)
        XCTAssertEqual(animated.lights[0].azimuth, 45, accuracy: 1e-3)

        var held = animated
        held.importedCamera?.binding = nil
        held.lights[0].binding = nil
        let frame = SceneFrameInput(time: 0.5, isRealTime: true)
        let animatedRenderer = try SceneRenderer(document: restored, videoPath: folder.path)
        var matched = restored
        matched.modelStage = held
        let heldRenderer = try SceneRenderer(document: matched, videoPath: folder.path)
        XCTAssertEqual(
            try animatedRenderer.renderStill(input: frame).dataProvider?.data as Data?,
            try heldRenderer.renderStill(input: frame).dataProvider?.data as Data?
        )

        scene.modelStage = SceneModelStage()
        let renderer = try SceneRenderer(document: scene, videoPath: folder.path)
        func red(time: Double, x: Int) throws -> UInt8 {
            let image = try renderer.renderStill(input: .init(time: time, isRealTime: true))
            let data = try XCTUnwrap(image.dataProvider?.data as Data?)
            return data[image.bytesPerRow * 50 + x * 4 + 2]
        }
        XCTAssertEqual(try red(time: 0, x: 140), 0)
        XCTAssertGreaterThan(try red(time: 0.5, x: 140), 40)
        XCTAssertEqual(try red(time: 1, x: 140), 0)

        var clone = result.layer
        clone.id = UUID()
        let evaluated = SceneEvaluatedFrame(
            instances: [clone.id: result.layer.id], input: frame,
            layers: [clone.id: .init(
                layer: clone, transform: SceneTransform(), opacity: 1, color: SceneLinkValues(),
                world: nil
            )], issues: [], logs: [:]
        )
        let cloneFrame = try renderer.staticModelFrame(clone, evaluated: evaluated, time: 0.5)
        let template = try XCTUnwrap(renderer.importedShapes[result.layer.id]?.morphed[0]?.shape)
        XCTAssertEqual(cloneFrame.shapes.first, template)
        XCTAssertTrue(cloneFrame.shapes.first?.vertexBuffer === template.vertexBuffer)

        manifest["nodes"] = [
            ["mesh": 0, "weights": [0.5]],
            ["camera": 0, "translation": [0, 0, 2], "children": [2]],
            ["extensions": [extent: ["light": 0]], "scale": [2, 1, 1]]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
        let weighted = try SceneModelImporter.importModel(
            at: url,
            canvasWidth: 200,
            canvasHeight: 100
        )
        let center = try XCTUnwrap(weighted.layer.modelPlacement?.center.first)
        XCTAssertEqual(center, 0.3, accuracy: 1e-6)
    }

    func testSparseMorphTargetUsesNodeWeightBeforeTransform() throws {
        let url = try writeSquare(animated: false)
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let buffers = try XCTUnwrap(manifest["buffers"] as? [[String: Any]])
        let uri = try XCTUnwrap(buffers[0]["uri"] as? String)
        var binary =
            try XCTUnwrap(try Data(base64Encoded: String(XCTUnwrap(uri.split(separator: ",")
                        .last))))
        let extraOffset = binary.count
        binary.append(contentsOf: [2, 0, 0, 0])
        binary.append(bytes([0, 0, 0.5]))
        manifest["buffers"] = [[
            "byteLength": binary.count,
            "uri": "data:application/octet-stream;base64," + binary.base64EncodedString()
        ]]
        var views = try XCTUnwrap(manifest["bufferViews"] as? [[String: Any]])
        views += [
            ["buffer": 0, "byteOffset": extraOffset, "byteLength": 1],
            ["buffer": 0, "byteOffset": extraOffset + 4, "byteLength": 12]
        ]
        manifest["bufferViews"] = views
        var accessors = try XCTUnwrap(manifest["accessors"] as? [[String: Any]])
        accessors.append([
            "componentType": 5126, "type": "VEC3", "count": 4, "min": [0, 0, 0], "max": [0, 0, 0.5],
            "sparse": [
                "count": 1,
                "indices": ["bufferView": 4, "componentType": 5121],
                "values": ["bufferView": 5]
            ]
        ])
        manifest["accessors"] = accessors
        manifest["nodes"] = [["mesh": 0, "weights": [0.5], "translation": [2, 1, 1]]]
        manifest["meshes"] = [["weights": [0], "primitives": [[
            "attributes": ["POSITION": 0], "indices": 1, "material": 0, "targets": [["POSITION": 4]]
        ]]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
        let morphed = try SceneModelImporter.importModel(
            at: url,
            canvasWidth: 200,
            canvasHeight: 100
        )
        XCTAssertEqual(morphed.layer.modelPlacement?.center[2], 1.125)

        let wrongIndex = binary.startIndex + extraOffset
        binary[wrongIndex] = 4
        manifest["buffers"] = [[
            "byteLength": binary.count,
            "uri": "data:application/octet-stream;base64," + binary.base64EncodedString()
        ]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
        XCTAssertThrowsError(try GLTFAsset.read(url: url))

        binary.replaceSubrange(32 ..< 36, with: bytes([0.25]))
        manifest["buffers"] = [[
            "byteLength": binary.count,
            "uri": "data:application/octet-stream;base64," + binary.base64EncodedString()
        ]]
        manifest["nodes"] = [["mesh": 0, "translation": [2, 1, 1]]]
        manifest["meshes"] = [["primitives": [[
            "attributes": ["POSITION": 0], "indices": 1, "material": 0
        ]]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
        let expanded = try SceneModelImporter.importModel(
            at: url,
            canvasWidth: 200,
            canvasHeight: 100
        )
        XCTAssertEqual(morphed.layer.model, expanded.layer.model)
        XCTAssertEqual(try pixels(morphed.layer), try pixels(expanded.layer))
    }

    @MainActor
    func testImportedCameraFramesTheMeshAndPointLightStopsAtItsRange() async throws {
        let extensionName = "KHR_lights_punctual"
        let url = try writeSquare(animated: false, extra: [
            "scenes": [["nodes": [0, 1]]],
            "nodes": [
                ["mesh": 0],
                ["translation": [0, 0, 2], "children": [2], "camera": 0],
                ["extensions": [extensionName: ["light": 0]]]
            ],
            "cameras": [["type": "orthographic", "orthographic": [
                "xmag": 1, "ymag": 0.5, "znear": 0, "zfar": 10
            ]]],
            "extensionsRequired": [extensionName],
            "extensions": [extensionName: ["lights": [[
                "type": "point",
                "range": 3,
                "intensity": 32
            ]]]]
        ])
        let result = try SceneModelImporter.importModel(
            at: url,
            canvasWidth: 200,
            canvasHeight: 100
        )
        var stage = try XCTUnwrap(result.stage)
        XCTAssertEqual(stage.importedCamera?.eye, [100, 50, 120])
        XCTAssertEqual(stage.lights.first?.position, [0.5, 0.5, 120])
        let document = SceneDocument(canvasWidth: 200, canvasHeight: 100, layers: [result.layer])
        var lit = document
        lit.modelStage = stage
        let model = WallpaperModel()
        let path = folder.appendingPathComponent("scene.mp4").path
        model.sceneDocumentsByPath[path] = SceneDocument(
            canvasWidth: 200,
            canvasHeight: 100,
            layers: []
        )
        let first = await model.addSceneModelLayer(from: url, path: path)
        XCTAssertNotNil(first)
        XCTAssertEqual(
            model.sceneDocumentsByPath[path]?.modelStage?.importedCamera,
            stage.importedCamera
        )
        let existingStage = try XCTUnwrap(model.sceneDocumentsByPath[path]?.modelStage)
        let second = await model.addSceneModelLayer(from: url, path: path)
        XCTAssertNotNil(second)
        XCTAssertEqual(model.sceneDocumentsByPath[path]?.modelStage, existingStage)

        let decoded = try JSONDecoder().decode(SceneDocument.self, from: JSONEncoder().encode(lit))
        XCTAssertEqual(decoded.modelStage, stage)
        func red(_ document: SceneDocument, x: Int) throws -> UInt8 {
            let renderer = try SceneRenderer(document: document, videoPath: folder.path)
            let image = try renderer.renderStill()
            let bytes = try XCTUnwrap(image.dataProvider?.data as Data?)
            return bytes[50 * image.bytesPerRow + x * 4 + 2]
        }
        XCTAssertGreaterThan(try red(lit, x: 140), 100)
        stage.importedCameraEnabled = false
        var defaultView = document
        defaultView.modelStage = stage
        XCTAssertEqual(try red(defaultView, x: 140), 0)
        stage.importedCameraEnabled = true
        stage.importedCamera?.projection = .perspective(
            verticalFOV: 2 * atan(0.25), aspect: 2, near: 1, far: nil
        )
        var perspective = document
        perspective.modelStage = stage
        XCTAssertEqual(try red(perspective, x: 140), try red(lit, x: 140))

        stage.importedCamera?.projection = .perspective(
            verticalFOV: 2 * atan(0.25), aspect: 2, near: 130, far: 200
        )
        var clipped = document
        clipped.modelStage = stage
        XCTAssertEqual(try red(clipped, x: 100), 0)

        stage = try XCTUnwrap(result.stage)
        stage.lights[0].range = 0.6
        var outOfRange = document
        outOfRange.modelStage = stage
        XCTAssertEqual(try red(outOfRange, x: 100), 0)

        stage = try XCTUnwrap(result.stage)
        stage.lights[0].kind = .spot
        stage.lights[0].coneAngle = 5
        var spot = document
        spot.modelStage = stage
        XCTAssertGreaterThan(try red(spot, x: 100), 100)
        XCTAssertEqual(try red(spot, x: 140), 0)

        stage.lights[0].kind = .directional
        var directional = document
        directional.modelStage = stage
        XCTAssertGreaterThan(try red(directional, x: 140), 100)
    }

    func testDracoSquareMatchesUncompressedRendering() throws {
        let url = try writeSquare(animated: false)
        let plain = try SceneModelImporter.importModel(at: url, canvasWidth: 200, canvasHeight: 100)
        let data = try XCTUnwrap(Data(base64Encoded:
            "RFJBQ08CAgEAAAACBAEAAQIAAgMBAQAJAwAAAAAAAL8AAAC/AAAAAAAAAD8AAAC/AAAAAAAAAD8AAAA/AAAAAAAAAL8AAAA/AAAAAA=="))
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let name = "KHR_draco_mesh_compression"
        manifest["extensionsUsed"] = [name]
        manifest["extensionsRequired"] = [name]
        manifest["buffers"] = [[
            "byteLength": data.count,
            "uri": "data:application/octet-stream;base64," + data.base64EncodedString()
        ]]
        manifest["bufferViews"] = [["buffer": 0, "byteLength": data.count]]
        manifest["accessors"] = [
            [
                "componentType": 5126,
                "count": 4,
                "type": "VEC3",
                "min": [-0.5, -0.5, 0],
                "max": [0.5, 0.5, 0]
            ],
            ["componentType": 5123, "count": 6, "type": "SCALAR"]
        ]
        manifest["meshes"] = [["primitives": [[
            "attributes": ["POSITION": 0], "indices": 1, "material": 0,
            "extensions": [name: ["bufferView": 0, "attributes": ["POSITION": 0]]]
        ]]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
        let imported = try SceneModelImporter.importModel(
            at: url,
            canvasWidth: 200,
            canvasHeight: 100
        )
        XCTAssertEqual(try pixels(imported.layer), try pixels(plain.layer))

        manifest["buffers"] = [[
            "byteLength": 1,
            "uri": "data:application/octet-stream;base64,AA=="
        ]]
        manifest["bufferViews"] = [["buffer": 0, "byteLength": 1]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
        XCTAssertThrowsError(try GLTFAsset.read(url: url))
    }

    private func pixels(_ layer: SceneLayer) throws -> Data {
        let document = SceneDocument(canvasWidth: 200, canvasHeight: 100, layers: [layer])
        let renderer = try SceneRenderer(document: document, videoPath: folder.path)
        return try XCTUnwrap(renderer.renderStill().dataProvider?.data as Data?)
    }

    func testMeshoptSquareMatchesUncompressedGeometryAndRendering() throws {
        let url = try writeSquare(animated: false)
        let reference = try GLTFAsset.read(url: url)
        let plain = try SceneModelImporter.importModel(at: url, canvasWidth: 200, canvasHeight: 100)
        let vertices = try XCTUnwrap(Data(base64Encoded:
            "oAAAAAEzAAAA//8AAAABDAAAAP8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAC/AAAAvwAAAAA="))
        let indices = try XCTUnwrap(Data(base64Encoded: "4fAAAHaHVmd4qYZliWiYAWkAAA=="))
        let source = vertices + indices
        let original = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let expectedPixels = try pixels(plain.layer)
        for name in ["EXT_meshopt_compression", "KHR_meshopt_compression"] {
            var manifest = original
            manifest["extensionsUsed"] = [name]
            manifest["extensionsRequired"] = [name]
            manifest["buffers"] = [
                [
                    "byteLength": source.count,
                    "uri": "data:application/octet-stream;base64," + source.base64EncodedString()
                ],
                ["byteLength": 60, "extensions": [name: ["fallback": true]]]
            ]
            let positionView: [String: Any] = [
                "buffer": 1, "byteLength": 48, "byteStride": 12,
                "extensions": [name: [
                    "buffer": 0, "byteLength": vertices.count, "byteStride": 12,
                    "mode": "ATTRIBUTES", "count": 4
                ]]
            ]
            var indexView: [String: Any] = [
                "buffer": 1, "byteOffset": 48, "byteLength": 12,
                "extensions": [name: [
                    "buffer": 0, "byteOffset": vertices.count, "byteLength": indices.count,
                    "byteStride": 2, "mode": "TRIANGLES", "count": 6
                ]]
            ]
            manifest["bufferViews"] = [positionView, indexView]
            try JSONSerialization.data(withJSONObject: manifest).write(to: url)
            let compressed = try GLTFAsset.read(url: url)
            XCTAssertEqual(compressed.meshes[0][0].positions, reference.meshes[0][0].positions)
            XCTAssertEqual(compressed.meshes[0][0].indices, reference.meshes[0][0].indices)
            let imported = try SceneModelImporter.importModel(
                at: url,
                canvasWidth: 200,
                canvasHeight: 100
            )
            XCTAssertEqual(try pixels(imported.layer), expectedPixels)

            indexView["byteLength"] = Int.max
            manifest["bufferViews"] = [positionView, indexView]
            try JSONSerialization.data(withJSONObject: manifest).write(to: url)
            XCTAssertThrowsError(try GLTFAsset.read(url: url))
        }
    }

    func testExtremeAccessorStridesAndOffsetsAreRejectedForFloatsAndIntegers() throws {
        for index in [0, 1] {
            for value in [Int.max, Int.min] {
                for field in ["byteStride", "byteOffset"] {
                    let url = try writeSquare(animated: false)
                    var json = try XCTUnwrap(
                        JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
                    )
                    let key = field == "byteStride" ? "bufferViews" : "accessors"
                    var items = try XCTUnwrap(json[key] as? [[String: Any]])
                    items[index][field] = value
                    json[key] = items
                    try JSONSerialization.data(withJSONObject: json).write(to: url)

                    XCTAssertThrowsError(try SceneModelImporter.importModel(
                        at: url, canvasWidth: 1000, canvasHeight: 500
                    )) { error in
                        XCTAssertTrue(error is GLTFAsset.ReadError, "Unexpected error: \(error)")
                    }
                }
            }
        }
    }

    func testAStillSquareBecomesOneShadedPartCentredOnTheCanvas() throws {
        let result = try SceneModelImporter.importModel(
            at: writeSquare(animated: false),
            canvasWidth: 1000,
            canvasHeight: 500
        )
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
        let world = placement.world(
            transform: SceneTransform(),
            canvasWidth: 1000,
            canvasHeight: 500
        )
        XCTAssertEqual(world * SIMD4(0.5, 0.5, 0, 1), SIMD4(650, 400, 0, 1))
    }

    func testAnAnimatedNodeBecomesARigWithItsClipSampled() throws {
        let result = try SceneModelImporter.importModel(
            at: writeSquare(animated: true),
            canvasWidth: 1000,
            canvasHeight: 500
        )
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
        let url = try writeSquare(
            animated: false,
            extra: ["extensionsRequired": ["KHR_texture_basisu"]]
        )
        XCTAssertThrowsError(try SceneModelImporter.importModel(
            at: url,
            canvasWidth: 100,
            canvasHeight: 100
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("KHR_texture_basisu"))
        }
    }

    func testABufferOutsideTheModelsFolderIsRefused() throws {
        let url = try writeSquare(
            animated: false,
            extra: ["buffers": [["byteLength": 4, "uri": "../secret.bin"]]]
        )
        XCTAssertThrowsError(try SceneModelImporter.importModel(
            at: url,
            canvasWidth: 100,
            canvasHeight: 100
        ))
    }

    func testMalformedAccessorsAreRefusedInsteadOfTrapping() throws {
        let positions: [Float] = [-0.5, -0.5, 0, 0.5, -0.5, 0, 0.5, 0.5, 0]
        let buffer = bytes(positions)
        func write(_ accessor: [String: Any], view: [String: Any] = [:]) throws -> URL {
            let json: [String: Any] = [
                "asset": ["version": "2.0"],
                "nodes": [["mesh": 0]],
                "meshes": [["primitives": [["attributes": ["POSITION": 0]]]]],
                "buffers": [[
                    "byteLength": buffer.count,
                    "uri": "data:application/octet-stream;base64," + buffer.base64EncodedString()
                ]],
                "bufferViews": [["buffer": 0, "byteLength": buffer.count].merging(view) { _, new in
                    new
                }],
                "accessors": [["bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"]
                    .merging(accessor) { _, new in new }]
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
            write([:], view: ["byteOffset": Int.max])
        ] {
            XCTAssertThrowsError(try SceneModelImporter.importModel(
                at: url,
                canvasWidth: 100,
                canvasHeight: 100
            ))
        }
        XCTAssertNoThrow(try SceneModelImporter.importModel(
            at: write([:]),
            canvasWidth: 100,
            canvasHeight: 100
        ))
    }

    func testAnImportedModelSurvivesTheSceneFileAndIsDrawnLit() throws {
        let result = try SceneModelImporter.importModel(
            at: writeSquare(animated: true),
            canvasWidth: 200,
            canvasHeight: 100
        )
        var document = SceneDocument(canvasWidth: 200, canvasHeight: 100, layers: [result.layer])
        try document.rigs[XCTUnwrap(result.rig?.id)] = try XCTUnwrap(result.rig?.skeleton)
        var stage = SceneModelStage()
        stage.lights = [.init(
            kind: .directional,
            color: [1, 1, 1],
            intensity: 1,
            azimuth: 0,
            elevation: 0
        )]
        stage.skyColor = [0, 0, 0]
        stage.groundColor = [0, 0, 0]
        document.modelStage = stage
        let decoded = try JSONDecoder().decode(
            SceneDocument.self,
            from: JSONEncoder().encode(document)
        )
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
        let result = try SceneModelImporter.importModel(
            at: writeSquare(animated: true),
            canvasWidth: 200,
            canvasHeight: 100
        )
        let still = SceneLayer(name: "picture", imageFile: "picture.png")
        var document = SceneDocument(
            canvasWidth: 200,
            canvasHeight: 100,
            layers: [still, result.layer]
        )
        try document.rigs[XCTUnwrap(result.rig?.id)] = try XCTUnwrap(result.rig?.skeleton)
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

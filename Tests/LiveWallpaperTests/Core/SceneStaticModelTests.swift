@testable import LiveWallpaper
import Metal
import simd
import XCTest

final class SceneStaticModelTests: XCTestCase {
    private func data<T>(_ values: [T]) -> Data {
        values.withUnsafeBytes { Data($0) }
    }

    /// Position and normal only: six floats a vertex.
    private func model(indices: [UInt32]) -> SceneStaticModel {
        let components: UInt32 = 0b00011
        let vertices: [Float] = [0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 1]
        return SceneStaticModel(material: 0, components: components, vertices: data(vertices), indices: data(indices))
    }

    private func layer(_ model: SceneStaticModel) -> SceneLayer {
        var layer = SceneLayer(name: "Sphere", imageFile: "")
        layer.kind = .model
        layer.model = model
        return layer
    }

    func testAModelLayerSurvivesEncodingAndGivesItsShape() throws {
        let original = layer(model(indices: [0, 1, 2]))
        let decoded = try JSONDecoder().decode(SceneLayer.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.kind, .model)
        let shape = try XCTUnwrap(decoded.model).shape
        XCTAssertEqual(shape.vertices.count, 18)
        XCTAssertEqual(shape.vertices[5], 1)
        XCTAssertEqual(shape.indices, [0, 1, 2])
        XCTAssertEqual(shape.stride, 6)
    }

    func testATriangleOutsideTheVerticesIsRefused() throws {
        let encoded = try JSONEncoder().encode(layer(model(indices: [0, 1, 3])))
        XCTAssertThrowsError(try JSONDecoder().decode(SceneLayer.self, from: encoded))
    }

    func testIndicesThatAreNotWholeTrianglesAreRefused() throws {
        let encoded = try JSONEncoder().encode(layer(model(indices: [0, 1])))
        XCTAssertThrowsError(try JSONDecoder().decode(SceneLayer.self, from: encoded))
    }

    func testShapeEquatableIgnoresBuffers() throws {
        var s1 = SceneModelLayerFrame.Shape(material: 0, components: 1, vertices: [1, 2, 3], indices: [0])
        let s2 = SceneModelLayerFrame.Shape(material: 0, components: 1, vertices: [1, 2, 3], indices: [0])
        XCTAssertEqual(s1, s2)
        let device = MTLCreateSystemDefaultDevice()
        s1.vertexBuffer = device?.makeBuffer(length: 16, options: .storageModeShared)
        XCTAssertEqual(s1, s2)
        s1.indexBuffer = device?.makeBuffer(length: 16, options: .storageModeShared)
        XCTAssertEqual(s1, s2)
    }

    func testBufferPregenerationAndReuse() throws {
        let m = model(indices: [0, 1, 2])
        let l = layer(m)
        let doc = SceneDocument(canvasWidth: 100, canvasHeight: 100, layers: [l])
        let renderer = try SceneRenderer(document: doc, videoPath: "/tmp/fake.mp4")

        let cached = try XCTUnwrap(renderer.staticShapes[l.id])
        XCTAssertEqual(cached.model, m)
        let vertexBuffer = try XCTUnwrap(cached.shape.vertexBuffer)
        let indexBuffer = try XCTUnwrap(cached.shape.indexBuffer)

        // Updating document with unchanged model preserves cached buffers
        var docSame = doc
        docSame.canvasWidth = 120
        try renderer.update(document: docSame)
        let cachedAfterUpdate = try XCTUnwrap(renderer.staticShapes[l.id])
        XCTAssertTrue(cachedAfterUpdate.shape.vertexBuffer === vertexBuffer)
        XCTAssertTrue(cachedAfterUpdate.shape.indexBuffer === indexBuffer)

        // Encoding a frame does not allocate new buffers or mutate cache
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 100, height: 100, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        let target = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let command = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
        try renderer.encode(into: target, commandBuffer: command, input: .rest)
        command.commit()
        command.waitUntilCompleted()

        let cachedAfterRender = try XCTUnwrap(renderer.staticShapes[l.id])
        XCTAssertTrue(cachedAfterRender.shape.vertexBuffer === vertexBuffer)
        XCTAssertTrue(cachedAfterRender.shape.indexBuffer === indexBuffer)
    }

    func testModelUpdateReflected() throws {
        let m1 = model(indices: [0, 1, 2])
        let l = layer(m1)
        let doc = SceneDocument(canvasWidth: 100, canvasHeight: 100, layers: [l])
        let renderer = try SceneRenderer(document: doc, videoPath: "/tmp/fake.mp4")

        let cachedInitial = try XCTUnwrap(renderer.staticShapes[l.id])
        let initialVertexBuffer = try XCTUnwrap(cachedInitial.shape.vertexBuffer)

        // Update model vertices
        var m2 = m1
        let updatedVertices: [Float] = [2, 0, 0, 0, 0, 1, 0, 2, 0, 0, 0, 1, 0, 0, 2, 0, 0, 1]
        m2.vertices = data(updatedVertices)
        var lUpdated = l
        lUpdated.model = m2
        let docUpdated = SceneDocument(canvasWidth: 100, canvasHeight: 100, layers: [lUpdated])
        try renderer.update(document: docUpdated)

        let cachedUpdated = try XCTUnwrap(renderer.staticShapes[l.id])
        XCTAssertEqual(cachedUpdated.model, m2)
        XCTAssertEqual(cachedUpdated.shape.vertices, updatedVertices)
        XCTAssertFalse(cachedUpdated.shape.vertexBuffer === initialVertexBuffer)
    }

    func testCacheDiscardedOnLayerRemovalOrModelRemoval() throws {
        let m = model(indices: [0, 1, 2])
        let l = layer(m)
        let doc = SceneDocument(canvasWidth: 100, canvasHeight: 100, layers: [l])
        let renderer = try SceneRenderer(document: doc, videoPath: "/tmp/fake.mp4")
        XCTAssertNotNil(renderer.staticShapes[l.id])

        // When layer is removed from document
        let docEmpty = SceneDocument(canvasWidth: 100, canvasHeight: 100, layers: [])
        try renderer.update(document: docEmpty)
        XCTAssertNil(renderer.staticShapes[l.id])

        // When layer is re-added
        try renderer.update(document: doc)
        XCTAssertNotNil(renderer.staticShapes[l.id])

        // When layer model is set to nil
        var lNoModel = l
        lNoModel.model = nil
        let docNoModel = SceneDocument(canvasWidth: 100, canvasHeight: 100, layers: [lNoModel])
        try renderer.update(document: docNoModel)
        XCTAssertNil(renderer.staticShapes[l.id])
    }

    func testModelLayerWithoutMeshMaterialsDoesNotCrash() throws {
        let m = model(indices: [0, 1, 2])
        let l = layer(m)
        let doc = SceneDocument(canvasWidth: 100, canvasHeight: 100, layers: [l])
        XCTAssertNil(doc.meshMaterials)

        let renderer = try SceneRenderer(document: doc, videoPath: "/tmp/fake.mp4")
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 100, height: 100, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        let target = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let command = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())

        XCTAssertNoThrow(try renderer.encode(into: target, commandBuffer: command, input: .rest))
        command.commit()
        command.waitUntilCompleted()
    }

    func testShadowRendererPrunesTargetsAndUsesBuffers() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return }
        let modelRenderer = try SceneModelRenderer(materials: [], device: device)
        let light1 = SceneShadowLight(kind: .spot, origin: [0, 0, 100], axis: [0, 0, -1], outerCone: 30, cascadeDistance: 100)
        let light2 = SceneShadowLight(kind: .spot, origin: [0, 0, 200], axis: [0, 0, -1], outerCone: 30, cascadeDistance: 100)

        var shape = model(indices: [0, 1, 2]).shape
        let vertexBuffer = device.makeBuffer(bytes: shape.vertices, length: shape.vertices.count * 4, options: .storageModeShared)
        shape.vertexBuffer = vertexBuffer
        let frame = SceneModelLayerFrame(serial: 0, order: 0, alpha: 1, color: .one, world: matrix_identity_float4x4, perspective: false, shapes: [shape])

        let cmd1 = try XCTUnwrap(queue.makeCommandBuffer())
        _ = try modelRenderer.renderShadows(lights: [light1, light2], casters: [frame], commandBuffer: cmd1)
        XCTAssertEqual(modelRenderer.shadowState.targets.count, 2)

        // Pruning when lights count drops to 1
        let cmd2 = try XCTUnwrap(queue.makeCommandBuffer())
        _ = try modelRenderer.renderShadows(lights: [light1], casters: [frame], commandBuffer: cmd2)
        XCTAssertEqual(modelRenderer.shadowState.targets.count, 1)
        XCTAssertNotNil(modelRenderer.shadowState.targets[0])
        XCTAssertNil(modelRenderer.shadowState.targets[1])

        // Pruning when lights count drops to 0
        let cmd3 = try XCTUnwrap(queue.makeCommandBuffer())
        _ = try modelRenderer.renderShadows(lights: [], casters: [frame], commandBuffer: cmd3)
        XCTAssertEqual(modelRenderer.shadowState.targets.count, 0)
    }

    func testNonCastingModelDoesNotChangeDirectionalShadow() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let light = SceneShadowLight(kind: .directional, origin: [0, 0, 100], axis: [0, 0, -1], outerCone: 30, cascadeDistance: 100)
        let caster = SceneModelLayerFrame(serial: 0, order: 0, alpha: 1, color: .one,
            world: matrix_identity_float4x4, perspective: false, shapes: [model(indices: [0, 1, 2]).shape])
        var background = caster
        background.world.columns.3 = SIMD4(10000, 10000, 10000, 1)
        background.castsShadow = false
        func snapshot(_ layers: [SceneModelLayerFrame]) throws -> (simd_float4x4, Data) {
            let renderer = try SceneModelRenderer(materials: [], device: device)
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let result = try renderer.renderShadows(lights: [light], casters: layers, commandBuffer: command)
            let texture = try XCTUnwrap(result.textures.first)
            let buffer = try XCTUnwrap(device.makeBuffer(length: texture.width * texture.height * 4, options: .storageModeShared))
            let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                to: buffer, destinationOffset: 0, destinationBytesPerRow: texture.width * 4,
                destinationBytesPerImage: texture.width * texture.height * 4)
            blit.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            if let error = command.error { throw error }
            return (result.matrices[0], Data(bytes: buffer.contents(), count: buffer.length))
        }
        let baseline = try snapshot([caster])
        let withBackground = try snapshot([caster, background])
        XCTAssertEqual(baseline.0, withBackground.0)
        XCTAssertEqual(baseline.1, withBackground.1)
        background.castsShadow = true
        XCTAssertNotEqual(try snapshot([caster, background]).0, baseline.0)
        var encodedLayer = layer(model(indices: [0, 1, 2]))
        encodedLayer.castsShadow = false
        let decoded = try JSONDecoder().decode(SceneLayer.self, from: JSONEncoder().encode(encodedLayer))
        XCTAssertEqual(decoded.castsShadow, false)
    }

    func testMultipleLayersSharingSameModelReuseBuffers() throws {
        let m = model(indices: [0, 1, 2])
        let l1 = layer(m)
        let l2 = layer(m)
        let doc = SceneDocument(canvasWidth: 100, canvasHeight: 100, layers: [l1, l2])
        let renderer = try SceneRenderer(document: doc, videoPath: "/tmp/fake.mp4")

        let cache1 = try XCTUnwrap(renderer.staticShapes[l1.id])
        let cache2 = try XCTUnwrap(renderer.staticShapes[l2.id])
        XCTAssertTrue(cache1.shape.vertexBuffer === cache2.shape.vertexBuffer)
        XCTAssertTrue(cache1.shape.indexBuffer === cache2.shape.indexBuffer)
    }

    func testScriptInstantiatedLayerReusesTemplateBuffers() throws {
        let m = model(indices: [0, 1, 2])
        let l = layer(m)
        let doc = SceneDocument(canvasWidth: 100, canvasHeight: 100, layers: [l])
        let renderer = try SceneRenderer(document: doc, videoPath: "/tmp/fake.mp4")

        let cached = try XCTUnwrap(renderer.staticShapes[l.id])
        _ = try XCTUnwrap(cached.shape.vertexBuffer)
        _ = try XCTUnwrap(cached.shape.indexBuffer)

        let copyID = UUID()
        var copyLayer = l
        copyLayer.id = copyID
        let evaluated = SceneEvaluatedFrame(
            instances: [copyID: l.id],
            input: .rest,
            layers: [
                l.id: SceneEvaluatedFrame.Layer(layer: l, transform: SceneTransform(), opacity: 1, color: SceneLinkValues(), world: nil),
                copyID: SceneEvaluatedFrame.Layer(layer: copyLayer, transform: SceneTransform(), opacity: 1, color: SceneLinkValues(), world: nil)
            ],
            issues: [],
            logs: [:]
        )

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 100, height: 100, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        let target = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let command = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())

        XCTAssertNoThrow(try renderer.encode(into: target, commandBuffer: command, input: .rest, frame: evaluated))
        command.commit()
        command.waitUntilCompleted()
    }

    func testDegenerateShapesDoNotCrashOrFail() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let modelRenderer = try SceneModelRenderer(materials: [], device: device)

        // Empty vertices
        let shapeEmpty = SceneModelLayerFrame.Shape(material: 0, components: 1, vertices: [], indices: nil)
        let frameEmpty = SceneModelLayerFrame(serial: 0, order: 0, alpha: 1, color: .one, world: matrix_identity_float4x4, perspective: false, shapes: [shapeEmpty])
        // Fewer than 3 indices
        let shapeFewIndices = SceneModelLayerFrame.Shape(material: 0, components: 1, vertices: [1, 2, 3], indices: [0, 1])
        let frameFewIndices = SceneModelLayerFrame(serial: 0, order: 0, alpha: 1, color: .one, world: matrix_identity_float4x4, perspective: false, shapes: [shapeFewIndices])
        // Stride 0 (components: 0)
        let shapeStrideZero = SceneModelLayerFrame.Shape(material: 0, components: 0, vertices: [1, 2, 3], indices: nil)
        let frameStrideZero = SceneModelLayerFrame(serial: 0, order: 0, alpha: 1, color: .one, world: matrix_identity_float4x4, perspective: false, shapes: [shapeStrideZero])

        let light = SceneShadowLight(kind: .spot, origin: [0, 0, 100], axis: [0, 0, -1], outerCone: 30, cascadeDistance: 100)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cmd = try XCTUnwrap(queue.makeCommandBuffer())

        XCTAssertNoThrow(try modelRenderer.renderShadows(lights: [light], casters: [frameEmpty, frameFewIndices, frameStrideZero], commandBuffer: cmd))
    }

    func testPerspectiveCompositePrunesShadowTargetsWhenLightsRemoved() throws {
        let m = model(indices: [0, 1, 2])
        let l = layer(m)
        let light = SceneShadowLight(kind: .spot, origin: [0, 0, 100], axis: [0, 0, -1], outerCone: 30, cascadeDistance: 100)
        let camera = SceneCamera(
            perspective: true,
            eye: [0, 0, 100],
            center: [0, 0, 0],
            up: [0, 1, 0],
            fov: 60,
            nearZ: 0.1,
            farZ: 1000,
            ambientColor: [0.1, 0.1, 0.1],
            skylightColor: [0.2, 0.2, 0.2],
            shadowLights: [light]
        )
        var doc = SceneDocument(canvasWidth: 100, canvasHeight: 100, layers: [l])
        doc.camera = camera
        let renderer = try SceneRenderer(document: doc, videoPath: "/tmp/fake.mp4")

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 100, height: 100, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        let target = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))

        // Render with 1 light
        let cmd1 = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
        try renderer.encode(into: target, commandBuffer: cmd1, input: .rest)
        cmd1.commit()
        cmd1.waitUntilCompleted()

        // Now remove lights
        var cameraNoLights = camera
        cameraNoLights.shadowLights = []
        doc.camera = cameraNoLights
        try renderer.update(document: doc)

        let cmd2 = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
        try renderer.encode(into: target, commandBuffer: cmd2, input: .rest)
        cmd2.commit()
        cmd2.waitUntilCompleted()
    }

    func testCapturingLayerInASceneSeenThroughItsCameraKeepsWhatWasDrawnBefore() throws {
        var capture = SceneLayer(name: "Post", imageFile: "")
        capture.capturesCanvas = true
        var doc = SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [layer(model(indices: [0, 1, 2])), capture])
        doc.backgroundColor = [0.2, 0.4, 0.6]
        doc.camera = SceneCamera(
            perspective: true, eye: [0, 0, 100], center: [0, 0, 0], up: [0, 1, 0], fov: 60, nearZ: 0.1, farZ: 1000,
            ambientColor: [0.1, 0.1, 0.1], skylightColor: [0.2, 0.2, 0.2]
        )
        let renderer = try SceneRenderer(document: doc, videoPath: "/tmp/fake.mp4")
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let command = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
        try renderer.encode(into: target, commandBuffer: command, input: .rest)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertNil(command.error)
        var pixel = [UInt8](repeating: 0, count: 4)
        target.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(60, 60, 1, 1), mipmapLevel: 0)
        // BGRA: the background survives the copy through the capture.
        XCTAssertEqual(Int(pixel[2]), 51, accuracy: 2)
        XCTAssertEqual(Int(pixel[1]), 102, accuracy: 2)
        XCTAssertEqual(Int(pixel[0]), 153, accuracy: 2)
    }
}

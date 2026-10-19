import CoreGraphics
@testable import LiveWallpaper
import Metal
import simd
import XCTest

final class ScenePlacementTests: XCTestCase {
    private let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

    private func affine(x: Float = 0, y: Float = 0, scale: Float = 1) -> [Float] {
        [scale, 0, 0, 0, 0, scale, 0, 0, 0, 0, 1, 0, x, y, 0, 1]
    }

    private func rig() -> SceneSkeleton {
        .init(bones: [.init(name: "root", rest: .init(), inverseBind: identity)], clips: [
            .init(name: "move", framesPerSecond: 1, frameCount: 1, tracks: [
                .init(bone: 0, transforms: [.init(), .init(translation: [0.5, 0, 0])])
            ])
        ], playback: [.init(clip: 0, loops: false)], attachments: [
            .init(name: "tip", bone: 0, transform: identity)
        ])
    }

    private func layer(rigID: UUID) -> SceneLayer {
        var layer = SceneLayer(name: "child", imageFile: "child.png")
        layer.placement = .init(steps: [
            .init(matrix: affine(x: 0.25, y: 0.5), skeletonID: rigID, attachment: "tip"),
            .init(matrix: affine(x: -0.125, y: -0.125, scale: 0.25))
        ], referenceTransform: .identity)
        return layer
    }

    func testNestedSocketsUseTheirOwnRigAndSurviveWithoutParentImage() throws {
        let parent = UUID(), child = UUID()
        var layer = layer(rigID: parent)
        layer.placement?.steps.insert(
            .init(matrix: affine(y: 0.1), skeletonID: child, attachment: "tip"),
            at: 1
        )
        let registry = try SceneSkeletonRegistry([parent: rig(), child: rig()])
        let evaluator = try ScenePlacementEvaluator(layers: [layer], rigs: registry)
        let first = try XCTUnwrap(evaluator.evaluate(time: 0)[layer.id]) * SIMD3(0.5, 0.5, 1)
        let last = try XCTUnwrap(evaluator.evaluate(time: 1)[layer.id]) * SIMD3(0.5, 0.5, 1)
        XCTAssertEqual(first.x, 0.25, accuracy: 0.00001)
        XCTAssertEqual(first.y, 0.6, accuracy: 0.00001)
        XCTAssertEqual(last.x, 1.25, accuracy: 0.00001)
        XCTAssertEqual(last.y, 0.6, accuracy: 0.00001)
    }

    func testUnknownSocketAndRigAndSingularPlacementFailBeforeDrawing() throws {
        let id = UUID()
        var layer = layer(rigID: id)
        XCTAssertThrowsError(try ScenePlacementEvaluator(
            layers: [layer],
            rigs: SceneSkeletonRegistry()
        ))
        let registry = try SceneSkeletonRegistry([id: rig()])
        layer.placement?.steps[0].attachment = "missing"
        XCTAssertThrowsError(try ScenePlacementEvaluator(layers: [layer], rigs: registry))
        layer.placement?.steps[0].attachment = "tip"
        layer.placement?.steps[1].matrix[0] = 0
        XCTAssertThrowsError(try ScenePlacementEvaluator(layers: [layer], rigs: registry))
    }

    func testSavedAttachmentMovesPixelsAndPickingAndAcceptsEditorOffset() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("scene.mp4")
        let bytes: [UInt8] = [0, 255, 0, 255]
        let image = try XCTUnwrap(try CGImage(
            width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        ))
        let file = try SceneStore.writeImage(image, prefix: "child", videoPath: video.path)
        let id = UUID()
        var layer = layer(rigID: id)
        layer.imageFile = file
        var document = SceneDocument(canvasWidth: 32, canvasHeight: 32, layers: [layer])
        document.rigs[id] = rig()
        try SceneStore.save(document, videoPath: video.path)
        let restored = try XCTUnwrap(SceneStore.load(videoPath: video.path))
        XCTAssertEqual(restored.rigs, document.rigs)
        XCTAssertEqual(restored.layers[0].placement, layer.placement)
        XCTAssertTrue(restored.requiresRealTimePlayback)
        let renderer = try SceneRenderer(document: restored, videoPath: video.path)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 32,
            height: 32,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        func draw(time: Double) throws -> [UInt8] {
            let command = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
            try renderer.encode(
                into: texture,
                commandBuffer: command,
                input: .init(time: time, isRealTime: true)
            )
            command.commit()
            command.waitUntilCompleted()
            if let error = command.error { throw error }
            var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
            pixels.withUnsafeMutableBytes {
                texture.getBytes(
                    $0.baseAddress!,
                    bytesPerRow: 128,
                    from: MTLRegionMake2D(0, 0, 32, 32),
                    mipmapLevel: 0
                )
            }
            return pixels
        }
        let first = try draw(time: 0)
        let last = try draw(time: 1)
        XCTAssertEqual(first[(16 * 32 + 8) * 4 + 1], 255)
        XCTAssertEqual(first[(16 * 32 + 24) * 4 + 1], 0)
        XCTAssertEqual(last[(16 * 32 + 8) * 4 + 1], 0)
        XCTAssertEqual(last[(16 * 32 + 24) * 4 + 1], 255)
        let center = try XCTUnwrap(renderer.canvasUV(layerUV: SIMD2(0.5, 0.5), layerID: layer.id))
        XCTAssertEqual(center.x, 0.75, accuracy: 0.00001)
        XCTAssertEqual(center.y, 0.5, accuracy: 0.00001)
        let picked = try XCTUnwrap(renderer.layerUV(canvasUV: center, layerID: layer.id))
        XCTAssertEqual(picked.x, 0.5, accuracy: 0.00001)
        XCTAssertEqual(picked.y, 0.5, accuracy: 0.00001)
        document.layers[0].transform.offsetY = -0.25
        try renderer.update(document: document)
        let movedPixels = try draw(time: 1)
        let moved = try XCTUnwrap(renderer.canvasUV(layerUV: SIMD2(0.5, 0.5), layerID: layer.id))
        XCTAssertEqual(moved.y, 0.25, accuracy: 0.00001)

        let original = document.layers[0].transform
        for scale in [1e-36, 1e-42, 0] {
            document.layers[0].transform.scale = scale
            document.layers[0].transform.scaleY = original.scale
            try renderer.update(document: document)
            let collapsed = try draw(time: 1)
            XCTAssertFalse(stride(from: 1, to: collapsed.count, by: 4).contains { collapsed[$0] != 0 })
            if let point = renderer.layerUV(canvasUV: SIMD2(0.5, 0.5), layerID: layer.id) {
                XCTAssertTrue(point.x.isFinite && point.y.isFinite)
            }
        }
        document.layers[0].transform = original
        try renderer.update(document: document)
        XCTAssertEqual(try draw(time: 1), movedPixels)
    }

    func testNonUniformScaleTransform() throws {
        var a = SceneTransform.identity
        a.scale = 2.0
        a.scaleY = 0.5
        var b = SceneTransform.identity
        b.scale = 4.0
        b.scaleY = 2.0
        let mid = a.interpolated(to: b, 0.5)
        XCTAssertEqual(mid.scale, sqrt(2.0 * 4.0), accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(mid.scaleY), sqrt(0.5 * 2.0), accuracy: 0.0001)

        let encoded = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(SceneTransform.self, from: encoded)
        XCTAssertEqual(decoded.scale, 2.0)
        XCTAssertEqual(decoded.scaleY, 0.5)
    }
}

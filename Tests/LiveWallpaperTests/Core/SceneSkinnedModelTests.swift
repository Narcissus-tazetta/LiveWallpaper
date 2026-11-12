import CoreGraphics
import Metal
import simd
import XCTest
@testable import LiveWallpaper

final class SceneSkinnedModelTests: XCTestCase {
    private let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

    func testABoneMovesTheVerticesItWeighs() async throws {
        let vertex = """
        #include <metal_stdlib>
        using namespace metal;
        struct Input { float3 position [[attribute(0)]]; uint4 joints [[attribute(1)]]; float4 weights [[attribute(2)]]; };
        struct Uniforms { float4x4 mvp; float4x3 bones[1]; };
        vertex float4 vertexMain(Input v [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
            float3 p = (u.bones[v.joints[0]] * float4(v.position, 1)) * v.weights[0];
            return u.mvp * float4(p, 1);
        }
        """
        let fragment = """
        #include <metal_stdlib>
        using namespace metal;
        fragment float4 fragmentMain() { return float4(1, 0, 0, 1); }
        """
        let material = SceneMeshMaterial(path: "fixture", draw: .init(
            vertex: .init(source: vertex, entryPoint: "vertexMain", uniforms: Data(count: 128),
                          updates: [.init(offset: 0, value: .modelViewProjection), .init(offset: 64, value: .boneMatrices, stride: 64)]),
            fragment: .init(source: fragment, entryPoint: "fragmentMain", uniforms: Data(), updates: []),
            vertices: Data(), vertexStride: 0, vertexCount: 0,
            attributes: [
                .init(location: 0, offset: 0, format: .float3, semantic: .position),
                .init(location: 1, offset: 0, format: .uint4, semantic: .joints),
                .init(location: 2, offset: 0, format: .float4, semantic: .weights)
            ], textures: []
        ), images: [:])
        // Position, then joint 0 and weight 1 (the joint as a raw 32-bit word).
        func corner(_ x: Float, _ y: Float) -> [Float] { [x, y, 0, Float(bitPattern: 0), 0, 0, 0, 1, 0, 0, 0] }
        let vertices = corner(0, 0) + corner(64, 0) + corner(0, 64) + corner(64, 64)
        let rigID = UUID()
        var layer = SceneLayer(name: "model", imageFile: "")
        layer.kind = .model
        layer.model = .init(
            material: 0, components: 0b110_0001, vertices: vertices.withUnsafeBytes { Data($0) },
            indices: ([0, 1, 2, 2, 1, 3] as [UInt32]).withUnsafeBytes { Data($0) }, skeleton: rigID
        )
        var document = SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [layer])
        document.meshMaterials = [material]
        let bone = SceneSkeleton.Bone(name: "root", rest: .init(translation: [32, 0, 0]), inverseBind: identity)
        document.rigs = [rigID: SceneSkeleton(bones: [bone], clips: [], playback: [])]
        let image = try await Task.detached { [document] in
            try SceneRenderer(document: document, videoPath: "/tmp/skinned-model-fixture.mp4").renderStill()
        }.value
        // The quad's left half is moved off the canvas: only the right half stays red.
        let (left, right) = try Self.halves(image)
        XCTAssertLessThan(left, 10)
        XCTAssertGreaterThan(right, 245)
    }

    func testAModelWithoutItsRigIsRefused() async throws {
        var layer = SceneLayer(name: "model", imageFile: "")
        layer.kind = .model
        layer.model = .init(
            material: 0, components: 0b110_0001,
            vertices: ([0, 0, 0, Float(bitPattern: 3), 0, 0, 0, 1, 0, 0, 0] as [Float]).withUnsafeBytes { Data($0) },
            indices: ([0, 0, 0] as [UInt32]).withUnsafeBytes { Data($0) }, skeleton: UUID()
        )
        var document = SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [layer])
        document.meshMaterials = [nil]
        try await Task.detached { [document] in
            XCTAssertThrowsError(try SceneRenderer(document: document, videoPath: "/tmp/skinned-model-fixture.mp4"))
        }.value
    }

    private static func halves(_ image: CGImage) throws -> (Double, Double) {
        var pixels = [UInt8](repeating: 0, count: 16)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 4, height: 1, bitsPerComponent: 8, bytesPerRow: 16,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 4, height: 1))
        return (Double(pixels[0]), Double(pixels[12]))
    }
}

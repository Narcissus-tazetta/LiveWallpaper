import CoreGraphics
import Metal
import simd
import XCTest
@testable import LiveWallpaper

final class SceneModelMaterialValuesTests: XCTestCase {
    func testScriptChangesTheRenderedMaterialAndAbsentOverridesKeepDefaults() async throws {
        let vertex = """
        #include <metal_stdlib>
        using namespace metal;
        struct Input { float3 position [[attribute(0)]]; };
        vertex float4 vertexMain(Input v [[stage_in]], constant float4x4 &matrix [[buffer(0)]]) {
            return matrix * float4(v.position, 1);
        }
        """
        let fragment = """
        #include <metal_stdlib>
        using namespace metal;
        fragment float4 fragmentMain(constant float &strength [[buffer(0)]]) {
            return float4(strength, 0, 0, 1);
        }
        """
        var initial: Float = 0.25
        let material = SceneMeshMaterial(path: "fixture", draw: .init(
            vertex: .init(source: vertex, entryPoint: "vertexMain", uniforms: Data(count: 64),
                          updates: [.init(offset: 0, value: .modelViewProjection)]),
            fragment: .init(source: fragment, entryPoint: "fragmentMain", uniforms: withUnsafeBytes(of: &initial) { Data($0) },
                            updates: [.init(offset: 0, value: .effectValue, key: "strength", components: 1)]),
            vertices: Data(), vertexStride: 0, vertexCount: 0,
            attributes: [.init(location: 0, offset: 0, format: .float3, semantic: .position)], textures: []
        ), images: [:], values: ["strength": 0.25])
        let vertices: [Float] = [0,0,0, 64,0,0, 0,64,0, 64,64,0]
        let indices: [UInt32] = [0,1,2,2,1,3]
        var layer = SceneLayer(name: "model", imageFile: "")
        layer.kind = .model
        layer.model = .init(material: 0, components: 1, vertices: vertices.withUnsafeBytes { Data($0) }, indices: indices.withUnsafeBytes { Data($0) })
        var document = SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [layer])
        document.meshMaterials = [material]
        var script = SceneScript(source: "function update(c){return [{id:c.targets[0].id,modelValues:{strength:0.75}}]}", layerIDs: [layer.id])
        script.isAuthorized = true
        document.scripts = [script]
        let scripted = try await Task.detached { [document] in
            try Self.red(SceneRenderer(document: document, videoPath: "/tmp/material-values-fixture.mp4").renderStill())
        }.value
        document.scripts = []
        let defaults = try await Task.detached { [document] in
            try Self.red(SceneRenderer(document: document, videoPath: "/tmp/material-values-fixture.mp4").renderStill())
        }.value
        XCTAssertEqual(scripted, 191, accuracy: 2)
        XCTAssertEqual(defaults, 64, accuracy: 2)
    }

    private static func red(_ image: CGImage) throws -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Double(pixel[0])
    }
}

import Foundation

/// A glow over the finished canvas, made of the scene's own finishing passes: the bright parts
/// are kept, blurred and added back. `SceneDocument.finishing` holds the graph it makes.
struct SceneBloom: Codable, Equatable {
    static let strengthRange = 0.0 ... 2.0
    static let thresholdRange = 0.0 ... 1.5
    static let radiusRange = 1.0 ... 6.0

    /// How much of the blurred bright part is added.
    var strength = 0.6
    /// The brightness (largest colour channel) above which a pixel glows.
    var threshold = 0.7
    /// The blur's reach in texels of the half-size copy the blur runs on.
    var radius = 2.5

    private static let vertex = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 position [[position]]; float2 uv; };
    vertex V vertexMain(uint id [[vertex_id]]) {
        float2 p[] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
        return {float4(p[id],0,1), float2(p[id].x * 0.5 + 0.5, 0.5 - p[id].y * 0.5)};
    }
    """

    private static let brightPass = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 position [[position]]; float2 uv; };
    fragment float4 fragmentMain(V in [[stage_in]], constant float& threshold [[buffer(0)]],
                                 texture2d<float> image [[texture(0)]], sampler s [[sampler(0)]]) {
        float3 c = image.sample(s, in.uv).rgb;
        float level = max(c.r, max(c.g, c.b));
        return float4(c * smoothstep(threshold, threshold + 0.3, level), 1);
    }
    """

    private static let blurPass = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 position [[position]]; float2 uv; };
    struct U { float2 texel; float2 direction; float radius; };
    constant float w[5] = {0.2270270, 0.1945946, 0.1216216, 0.0540541, 0.0162162};
    fragment float4 fragmentMain(V in [[stage_in]], constant U& u [[buffer(0)]],
                                 texture2d<float> image [[texture(0)]], sampler s [[sampler(0)]]) {
        float3 sum = image.sample(s, in.uv).rgb * w[0];
        for (int i = 1; i < 5; i++) {
            float2 offset = u.texel * u.direction * (float(i) * u.radius);
            sum += image.sample(s, in.uv + offset).rgb * w[i];
            sum += image.sample(s, in.uv - offset).rgb * w[i];
        }
        return float4(sum, 1);
    }
    """

    private static let compositePass = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 position [[position]]; float2 uv; };
    fragment float4 fragmentMain(V in [[stage_in]], constant float& strength [[buffer(0)]],
                                 texture2d<float> image [[texture(0)]], texture2d<float> glow [[texture(1)]],
                                 sampler s [[sampler(0)]], sampler g [[sampler(1)]]) {
        float4 c = image.sample(s, in.uv);
        return float4(c.rgb + glow.sample(g, in.uv).rgb * strength, c.a);
    }
    """

    private static func floats(_ values: [Float]) -> Data {
        values.withUnsafeBytes { Data($0) }
    }

    var graph: SceneRenderGraph {
        func draw(
            _ fragment: String, uniforms: Data, updates: [SceneRenderGraph.UniformUpdate] = [], textures: [String]
        ) -> SceneRenderGraph.Draw {
            SceneRenderGraph.Draw(
                vertex: .init(source: Self.vertex, entryPoint: "vertexMain"),
                fragment: .init(source: fragment, entryPoint: "fragmentMain", uniforms: uniforms, updates: updates),
                vertices: Data(repeating: 0, count: 12), vertexStride: 4, vertexCount: 3, attributes: [],
                textures: textures.enumerated().map { .init(index: $0.offset, source: $0.element) }
            )
        }
        // Half-float targets keep colours above white until the glow is added.
        func target(_ name: String, fit: Int? = nil) -> SceneRenderGraph.Target {
            var target = SceneRenderGraph.Target(name: name, format: .rgba16Float)
            target.fit = fit
            return target
        }
        func blur(_ source: String, direction: [Float]) -> SceneRenderGraph.Draw {
            draw(
                Self.blurPass,
                uniforms: Self.floats([0, 0] + direction + [Float(radius), 0]),
                updates: [.init(offset: 0, value: .texelSize, texture: source)],
                textures: [source]
            )
        }
        let horizontal = blur("bright", direction: [1, 0])
        let vertical = blur("blurH", direction: [0, 1])
        return SceneRenderGraph(
            targets: [target("bright", fit: 640), target("blurH", fit: 640), target("blurV", fit: 640), target("out")],
            passes: [
                .init(operation: .draw, target: "bright", draw: draw(
                    Self.brightPass, uniforms: Self.floats([Float(threshold), 0, 0, 0]), textures: ["input"]
                )),
                .init(operation: .draw, target: "blurH", draw: horizontal),
                .init(operation: .draw, target: "blurV", draw: vertical),
                .init(operation: .draw, target: "out", draw: draw(
                    Self.compositePass, uniforms: Self.floats([Float(strength), 0, 0, 0]), textures: ["input", "blurV"]
                )),
            ],
            output: "out"
        )
    }
}

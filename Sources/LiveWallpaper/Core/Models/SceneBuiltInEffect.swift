import Foundation

/// Image effects the editor offers that are made from the scene's own shader passes. They are
/// `SceneEffectKind.shader` effects whose render graph reads its settings from `SceneEffect.values`.
enum SceneBuiltInEffect: String, CaseIterable, Identifiable {
    case colorAdjust, blur, glow, chromaticAberration, pixelate, glitch

    var id: String { rawValue }

    struct Parameter {
        var key: String
        var title: String
        var range: ClosedRange<Double>
        var initial: Double
    }

    var title: String {
        switch self {
        case .colorAdjust: "色調補正"
        case .blur: "ぼかし(画像)"
        case .glow: "グロー"
        case .chromaticAberration: "色ずれ"
        case .pixelate: "モザイク"
        case .glitch: "グリッチ"
        }
    }

    var parameters: [Parameter] {
        switch self {
        case .colorAdjust: [
            .init(key: "brightness", title: "明るさ", range: -1 ... 1, initial: 0),
            .init(key: "contrast", title: "コントラスト", range: 0 ... 2, initial: 1),
            .init(key: "saturation", title: "彩度", range: 0 ... 2, initial: 1),
            .init(key: "hue", title: "色相", range: -0.5 ... 0.5, initial: 0),
        ]
        case .blur: [.init(key: "radius", title: "ぼかしの半径", range: 0 ... 20, initial: 4)]
        case .glow: [
            .init(key: "strength", title: "強さ", range: 0 ... 2, initial: 0.8),
            .init(key: "threshold", title: "しきい値", range: 0 ... 1.5, initial: 0.6),
            .init(key: "radius", title: "広がり", range: 1 ... 6, initial: 2.5),
        ]
        case .chromaticAberration: [
            .init(key: "amount", title: "ずれの大きさ", range: 0 ... 0.05, initial: 0.006),
            .init(key: "angle", title: "ずれの向き(度)", range: 0 ... 360, initial: 0),
        ]
        case .pixelate: [.init(key: "size", title: "ブロックの大きさ", range: 1 ... 128, initial: 12)]
        case .glitch: [
            .init(key: "amount", title: "量", range: 0 ... 1, initial: 0.4),
            .init(key: "speed", title: "速さ", range: 0.5 ... 30, initial: 8),
        ]
        }
    }

    var initialValues: [String: Double] {
        Dictionary(uniqueKeysWithValues: parameters.map { ($0.key, $0.initial) })
    }

    func makeEffect() -> SceneEffect {
        var effect = SceneEffect(kind: .shader)
        effect.builtIn = rawValue
        effect.values = initialValues
        effect.renderGraph = graph
        return effect
    }

    private static let header = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 position [[position]]; float2 uv; };
    """

    private static let vertex = header + """

    vertex V vertexMain(uint id [[vertex_id]]) {
        float2 p[] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
        return {float4(p[id],0,1), float2(p[id].x * 0.5 + 0.5, 0.5 - p[id].y * 0.5)};
    }
    """

    private static let colorAdjustSource = header + """

    fragment float4 fragmentMain(V in [[stage_in]], constant float4& p [[buffer(0)]],
                                 texture2d<float> image [[texture(0)]], sampler s [[sampler(0)]]) {
        float4 c = image.sample(s, in.uv);
        float3 rgb = c.a > 0 ? c.rgb / c.a : c.rgb;
        rgb += p.x;
        rgb = (rgb - 0.5) * p.y + 0.5;
        float grey = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        rgb = mix(float3(grey), rgb, p.z);
        // Hue turns the colour around the grey axis.
        float angle = p.w * 6.2831853;
        float3 k = float3(0.57735);
        rgb = rgb * cos(angle) + cross(k, rgb) * sin(angle) + k * dot(k, rgb) * (1 - cos(angle));
        return float4(max(rgb, 0.0) * c.a, c.a);
    }
    """

    private static let blurSource = header + """

    struct U { float2 texel; float2 direction; float radius; };
    constant float w[5] = {0.2270270, 0.1945946, 0.1216216, 0.0540541, 0.0162162};
    fragment float4 fragmentMain(V in [[stage_in]], constant U& u [[buffer(0)]],
                                 texture2d<float> image [[texture(0)]], sampler s [[sampler(0)]]) {
        float4 sum = image.sample(s, in.uv) * w[0];
        for (int i = 1; i < 5; i++) {
            float2 offset = u.texel * u.direction * (float(i) * u.radius * 0.25);
            sum += image.sample(s, in.uv + offset) * w[i];
            sum += image.sample(s, in.uv - offset) * w[i];
        }
        return sum;
    }
    """

    private static let chromaticSource = header + """

    fragment float4 fragmentMain(V in [[stage_in]], constant float2& p [[buffer(0)]],
                                 texture2d<float> image [[texture(0)]], sampler s [[sampler(0)]]) {
        float angle = p.y * 0.01745329;
        float2 shift = float2(cos(angle), sin(angle)) * p.x;
        float4 r = image.sample(s, in.uv + shift);
        float4 g = image.sample(s, in.uv);
        float4 b = image.sample(s, in.uv - shift);
        return float4(r.r, g.g, b.b, max(r.a, max(g.a, b.a)));
    }
    """

    private static let pixelateSource = header + """

    fragment float4 fragmentMain(V in [[stage_in]], constant float& size [[buffer(0)]],
                                 texture2d<float> image [[texture(0)]], sampler s [[sampler(0)]]) {
        float2 dim = float2(image.get_width(), image.get_height());
        float2 cell = max(size, 1.0) / dim;
        return image.sample(s, (floor(in.uv / cell) + 0.5) * cell);
    }
    """

    private static let glitchSource = header + """

    float hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
    fragment float4 fragmentMain(V in [[stage_in]], constant float4& p [[buffer(0)]],
                                 texture2d<float> image [[texture(0)]], sampler s [[sampler(0)]]) {
        float step = floor(p.z * p.y);
        float band = floor(in.uv.y * 24.0);
        float on = hash(float2(band, step)) > 1.0 - p.x * 0.5 ? 1.0 : 0.0;
        float shift = (hash(float2(step, band)) - 0.5) * 0.2 * on;
        float split = 0.01 * on * p.x;
        float4 r = image.sample(s, in.uv + float2(shift + split, 0));
        float4 g = image.sample(s, in.uv + float2(shift, 0));
        float4 b = image.sample(s, in.uv + float2(shift - split, 0));
        return float4(r.r, g.g, b.b, max(r.a, max(g.a, b.a)));
    }
    """

    private static func data(_ values: [Float]) -> Data { values.withUnsafeBytes { Data($0) } }

    private static func effect(_ key: String, at offset: Int) -> SceneRenderGraph.UniformUpdate {
        .init(offset: offset, value: .effectValue, key: key, components: 1)
    }

    private static func draw(
        _ source: String, bytes: Int, updates: [SceneRenderGraph.UniformUpdate], textures: [String]
    ) -> SceneRenderGraph.Draw {
        SceneRenderGraph.Draw(
            vertex: .init(source: vertex, entryPoint: "vertexMain"),
            fragment: .init(
                source: source, entryPoint: "fragmentMain", uniforms: Data(count: bytes), updates: updates
            ),
            vertices: Data(repeating: 0, count: 12), vertexStride: 4, vertexCount: 3, attributes: [],
            textures: textures.enumerated().map { .init(index: $0.offset, source: $0.element) }
        )
    }

    private static func target(_ name: String, fit: Int? = nil) -> SceneRenderGraph.Target {
        var target = SceneRenderGraph.Target(name: name, format: .rgba16Float)
        target.fit = fit
        return target
    }

    private static func single(_ source: String, bytes: Int, updates: [SceneRenderGraph.UniformUpdate]) -> SceneRenderGraph {
        SceneRenderGraph(
            targets: [target("out")],
            passes: [.init(operation: .draw, target: "out", draw: draw(source, bytes: bytes, updates: updates, textures: ["input"]))],
            output: "out"
        )
    }

    private var graph: SceneRenderGraph {
        func effect(_ key: String, at offset: Int) -> SceneRenderGraph.UniformUpdate { Self.effect(key, at: offset) }
        switch self {
        case .colorAdjust:
            return Self.single(Self.colorAdjustSource, bytes: 16, updates: [
                effect("brightness", at: 0), effect("contrast", at: 4), effect("saturation", at: 8), effect("hue", at: 12),
            ])
        case .chromaticAberration:
            return Self.single(Self.chromaticSource, bytes: 8, updates: [effect("amount", at: 0), effect("angle", at: 4)])
        case .pixelate:
            return Self.single(Self.pixelateSource, bytes: 4, updates: [effect("size", at: 0)])
        case .glitch:
            return Self.single(Self.glitchSource, bytes: 16, updates: [
                effect("amount", at: 0), effect("speed", at: 4), .init(offset: 8, value: .time),
            ])
        case .blur:
            func pass(_ from: String, _ to: String, direction: [Float]) -> SceneRenderGraph.Pass {
                var data = Self.draw(Self.blurSource, bytes: 24, updates: [
                    .init(offset: 0, value: .texelSize, texture: from), effect("radius", at: 16),
                ], textures: [from])
                data.fragment.uniforms.replaceSubrange(8 ..< 16, with: Self.data(direction))
                return .init(operation: .draw, target: to, draw: data)
            }
            return SceneRenderGraph(
                targets: [Self.target("blurH"), Self.target("out")],
                passes: [pass("input", "blurH", direction: [1, 0]), pass("blurH", "out", direction: [0, 1])],
                output: "out"
            )
        case .glow:
            var bright = Self.draw(SceneBloom.brightPass, bytes: 4, updates: [effect("threshold", at: 0)], textures: ["input"])
            bright.vertex.source = SceneBloom.vertex
            func blur(_ from: String, direction: [Float]) -> SceneRenderGraph.Draw {
                var blur = Self.draw(SceneBloom.blurPass, bytes: 24, updates: [
                    .init(offset: 0, value: .texelSize, texture: from), effect("radius", at: 16),
                ], textures: [from])
                blur.fragment.uniforms.replaceSubrange(8 ..< 16, with: Self.data(direction))
                return blur
            }
            let composite = Self.draw(SceneBloom.compositePass, bytes: 4, updates: [effect("strength", at: 0)], textures: ["input", "blurV"])
            return SceneRenderGraph(
                targets: [Self.target("bright", fit: 640), Self.target("blurH", fit: 640), Self.target("blurV", fit: 640), Self.target("out")],
                passes: [
                    .init(operation: .draw, target: "bright", draw: bright),
                    .init(operation: .draw, target: "blurH", draw: blur("bright", direction: [1, 0])),
                    .init(operation: .draw, target: "blurV", draw: blur("blurH", direction: [0, 1])),
                    .init(operation: .draw, target: "out", draw: composite),
                ],
                output: "out"
            )
        }
    }
}

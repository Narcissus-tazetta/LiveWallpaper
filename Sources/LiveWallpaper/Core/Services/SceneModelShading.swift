import Foundation
import simd

/// The app's own material for the models the editor imports: glTF's metallic-roughness
/// shading (GGX, Smith, Schlick, Lambert) with light from all round taken from the sky
/// and ground colours, up to four lights with shadow maps, the Khronos PBR Neutral tone
/// curve, and sRGB out, which is how the canvas holds colour.
enum SceneModelShading {
    static let maximumLights = SceneModelStage.maximumLights
    /// Resource names of the material images, in the order of their texture indices.
    static let imageSlots = ["baseColor", "metallicRoughness", "normal", "occlusion", "emissive"]
    private static let shadowTextureIndex = 8

    // Fragment uniform offsets.
    private static let lightsOffset = 112
    private static let lightStride = 64
    private static let shadowMatricesOffset = 368
    private static let floorOffset = 624
    private static let fragmentSize = 640
    private static let bonesOffset = 192

    static func material(surface: SceneModelSurface, boneCount: Int?) -> SceneMeshMaterial {
        let images: [String: String] = Dictionary(uniqueKeysWithValues: zip(imageSlots, [
            surface.baseColorImage, surface.metallicRoughnessImage, surface.normalImage, surface.occlusionImage, surface.emissiveImage
        ]).compactMap { name, file in file.map { (name, $0) } })
        var defines = images.keys.sorted().map { "#define HAS_\($0.uppercased()) 1" }
        if boneCount != nil { defines.append("#define SKINNED 1") }
        if surface.alphaMode == .mask { defines.append("#define ALPHA_MASK 1") }
        if surface.alphaMode == .blend { defines.append("#define ALPHA_BLEND 1") }
        if surface.unlit { defines.append("#define UNLIT 1") }
        if surface.doubleSided { defines.append("#define DOUBLE_SIDED 1") }
        let source = defines.joined(separator: "\n") + "\n" + shaderSource

        var fragment = Data(count: fragmentSize)
        func put(_ values: [Float], at offset: Int) {
            values.withUnsafeBytes { fragment.replaceSubrange(offset ..< offset + $0.count, with: $0) }
        }
        put(surface.baseColor.map(Float.init), at: 64)
        put(surface.emissive.map(Float.init) + [Float(surface.alphaCutoff)], at: 80)
        put([surface.metallic, surface.roughness, surface.normalScale, surface.occlusionStrength].map(Float.init), at: 96)
        var fragmentUpdates: [SceneRenderGraph.UniformUpdate] = [
            .init(offset: 0, value: .eyePosition),
            .init(offset: 16, value: .ambientColor),
            .init(offset: 32, value: .skylightColor),
            .init(offset: 48, value: .layerColor),
            .init(offset: 60, value: .layerAlpha),
        ]
        fragmentUpdates += lightUpdates()

        var vertexUpdates: [SceneRenderGraph.UniformUpdate] = [
            .init(offset: 0, value: .modelViewProjection),
            .init(offset: 64, value: .model),
            .init(offset: 128, value: .normalModel),
        ]
        var attributes: [SceneRenderGraph.Attribute] = [
            .init(location: 0, offset: 0, format: .float3, semantic: .position),
            .init(location: 1, offset: 0, format: .float3, semantic: .normal),
            .init(location: 2, offset: 0, format: .float4, semantic: .tangentSigned),
            .init(location: 3, offset: 0, format: .float2, semantic: .uv),
            .init(location: 4, offset: 0, format: .float4, semantic: .color),
        ]
        if boneCount != nil {
            vertexUpdates.append(.init(offset: bonesOffset, value: .boneMatrices, stride: 64))
            attributes += [
                .init(location: 5, offset: 0, format: .uint4, semantic: .joints),
                .init(location: 6, offset: 0, format: .float4, semantic: .weights),
            ]
        }
        let textures = imageSlots.enumerated().compactMap { index, name in
            images[name] == nil ? nil : SceneRenderGraph.Texture(index: index, source: name, repeats: surface.repeats, linear: true)
        } + shadowTextures
        let draw = SceneRenderGraph.Draw(
            vertex: .init(source: source, entryPoint: "surfaceVertex",
                          uniforms: Data(count: bonesOffset + 64 * max(boneCount ?? 0, 1)), updates: vertexUpdates),
            fragment: .init(source: source, entryPoint: "surfaceFragment", uniforms: fragment, updates: fragmentUpdates),
            vertices: Data(), vertexStride: 0, vertexCount: 0, attributes: attributes, textures: textures,
            blend: .sourceOver, depthTest: true, depthWrite: surface.alphaMode != .blend,
            cull: surface.doubleSided ? nil : .back
        )
        return SceneMeshMaterial(path: "surface", draw: draw, images: images)
    }

    /// A floor that shows only the shadows on it, drawn black with their darkness as alpha.
    static func floorMaterial() -> SceneMeshMaterial {
        let source = "#define FLOOR 1\n" + shaderSource
        let draw = SceneRenderGraph.Draw(
            vertex: .init(source: source, entryPoint: "surfaceVertex", uniforms: Data(count: bonesOffset + 64), updates: [
                .init(offset: 0, value: .modelViewProjection),
                .init(offset: 64, value: .model),
                .init(offset: 128, value: .normalModel),
            ]),
            fragment: .init(source: source, entryPoint: "floorFragment", uniforms: Data(count: fragmentSize), updates: lightUpdates()),
            vertices: Data(), vertexStride: 0, vertexCount: 0,
            attributes: [
                .init(location: 0, offset: 0, format: .float3, semantic: .position),
                .init(location: 1, offset: 0, format: .float3, semantic: .normal),
                .init(location: 2, offset: 0, format: .float4, semantic: .tangentSigned),
                .init(location: 3, offset: 0, format: .float2, semantic: .uv),
                .init(location: 4, offset: 0, format: .float4, semantic: .color),
            ],
            textures: shadowTextures, blend: .sourceOver, depthTest: true, depthWrite: false, cull: nil
        )
        return SceneMeshMaterial(path: "floor", draw: draw, images: [:])
    }

    private static var shadowTextures: [SceneRenderGraph.Texture] {
        (0 ..< maximumLights).map { .init(index: shadowTextureIndex + $0, source: "_shadow\($0)", repeats: false, linear: false) }
    }

    private static func lightUpdates() -> [SceneRenderGraph.UniformUpdate] {
        var updates: [SceneRenderGraph.UniformUpdate] = []
        for light in 0 ..< maximumLights {
            let base = lightsOffset + light * lightStride
            updates += [
                .init(offset: base, value: .lightOrigin, key: "\(light)"),
                .init(offset: base + 16, value: .lightAxis, key: "\(light)"),
                .init(offset: base + 32, value: .lightColor, key: "\(light)"),
                .init(offset: base + 48, value: .effectValue, key: "light\(light)", components: 4),
                .init(offset: shadowMatricesOffset + light * 64, value: .shadowMatrix, key: "\(light)"),
            ]
        }
        updates.append(.init(offset: floorOffset, value: .effectValue, key: "floor", components: 4))
        return updates
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float3 position [[attribute(0)]];
        float3 normal [[attribute(1)]];
        float4 tangent [[attribute(2)]];
        float2 uv [[attribute(3)]];
        float4 color [[attribute(4)]];
    #ifdef SKINNED
        uint4 joints [[attribute(5)]];
        float4 weights [[attribute(6)]];
    #endif
    };

    struct VertexUniforms {
        float4x4 modelViewProjection;
        float4x4 model;
        float3x3 normalModel;
    };

    struct Fragment {
        float4 position [[position]];
        float3 world;
        float3 normal;
        float4 tangent;
        float2 uv;
        float4 color;
    };

    vertex Fragment surfaceVertex(VertexIn in [[stage_in]], constant VertexUniforms& u [[buffer(0)]]) {
        float4 position = float4(in.position, 1);
        float3 normal = in.normal;
        float3 tangent = in.tangent.xyz;
    #ifdef SKINNED
        constant float4x4* bones = (constant float4x4*)((constant char*)&u + 192);
        float4x4 skin = bones[in.joints.x] * in.weights.x + bones[in.joints.y] * in.weights.y
            + bones[in.joints.z] * in.weights.z + bones[in.joints.w] * in.weights.w;
        position = skin * position;
        float3x3 turn = float3x3(skin[0].xyz, skin[1].xyz, skin[2].xyz);
        normal = turn * normal;
        tangent = turn * tangent;
    #endif
        Fragment out;
        out.position = u.modelViewProjection * position;
        out.world = (u.model * position).xyz;
        out.normal = u.normalModel * normal;
        out.tangent = float4(u.normalModel * tangent, in.tangent.w);
        out.uv = in.uv;
        out.color = in.color;
        return out;
    }

    struct Light {
        float3 origin;
        float3 axis;
        float3 color;
        /// kind (0 directional, 1 point, 2 spot), cos of the cone's half angle, range, shadow slot.
        float4 params;
    };

    struct FragmentUniforms {
        float3 eye;
        float3 ground;
        float3 sky;
        packed_float3 layerColor;
        float layerAlpha;
        float4 baseColor;
        packed_float3 emissive;
        float alphaCutoff;
        /// metallic, roughness, normal scale, occlusion strength
        float4 pbr;
        Light lights[4];
        float4x4 shadows[4];
        /// x: the floor's shadow opacity
        float4 floor;
    };

    constant float PI = 3.14159265;

    static float3 toLinear(float3 c) {
        return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
    }

    static float3 toSRGB(float3 c) {
        c = max(c, 0.0);
        return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
    }

    // Khronos PBR Neutral: leaves colours below about 0.76 as they are.
    static float3 neutral(float3 color) {
        const float start = 0.8 - 0.04;
        const float desaturation = 0.15;
        float x = min(color.r, min(color.g, color.b));
        float offset = x < 0.08 ? x - 6.25 * x * x : 0.04;
        color -= offset;
        float peak = max(color.r, max(color.g, color.b));
        if (peak < start) return color;
        const float d = 1.0 - start;
        float newPeak = 1.0 - d * d / (peak + d - start);
        color *= newPeak / peak;
        float g = 1.0 - 1.0 / (desaturation * (peak - newPeak) + 1.0);
        return mix(color, float3(newPeak), g);
    }

    static float lookup(texture2d<float> map, sampler s, float2 uv) {
        return map.sample(s, uv).r;
    }

    /// 1 where the light reaches `world`, 0 in full shadow; 3×3 samples soften the edge.
    static float visibility(constant FragmentUniforms& u, constant Light& light, float3 world, float3 normal,
                            texture2d<float> s0, texture2d<float> s1, texture2d<float> s2, texture2d<float> s3, sampler point) {
        int slot = int(light.params.w);
        if (slot < 0) return 1.0;
        float4x4 m = u.shadows[slot];
        texture2d<float> map = slot == 0 ? s0 : slot == 1 ? s1 : slot == 2 ? s2 : s3;
        float size = float(map.get_width());
        bool directional = light.params.x < 0.5;
        // How much scene one shadow texel covers where `world` is.
        float texel;
        if (directional) {
            float radius = 1.0 / length(float3(m[0][0], m[1][0], m[2][0]));
            texel = 2.0 * radius / size;
        } else {
            texel = length(world - light.origin) * 2.0 / (size * max(m[1][1], 0.01));
        }
        float3 lift = world + normal * texel * 1.5;
        float4 clip = m * float4(lift, 1);
        if (clip.w <= 0) return 1.0;
        float2 ndc = clip.xy / clip.w;
        if (any(abs(ndc) > 1.0)) return 1.0;
        float2 uv = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
        float depth = directional ? dot(lift, light.axis) : length(lift - light.origin);
        float bias = texel * 1.5;
        float lit = 0;
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                lit += depth - bias <= lookup(map, point, uv + float2(x, y) / size) ? 1.0 : 0.0;
            }
        }
        return lit / 9.0;
    }

    /// The light's colour at `world` and the direction toward it.
    static float3 incoming(constant Light& light, float3 world, thread float3& toLight) {
        if (light.params.x < 0.5) {
            toLight = -light.axis;
            return light.color;
        }
        float3 offset = light.origin - world;
        float distance = max(length(offset), 0.001);
        toLight = offset / distance;
        float r = distance / max(light.params.z, 1.0);
        float strength = 1.0 / (1.0 + 3.0 * r * r);
        if (light.params.x > 1.5) {
            float c = dot(-toLight, light.axis);
            float edge = light.params.y;
            strength *= smoothstep(edge, mix(edge, 1.0, 0.25), c);
        }
        return light.color * strength;
    }

    static float3 hemisphere(constant FragmentUniforms& u, float3 direction) {
        return mix(u.ground, u.sky, saturate(direction.y * 0.5 + 0.5));
    }

    fragment float4 surfaceFragment(
        Fragment in [[stage_in]], bool front [[front_facing]], constant FragmentUniforms& u [[buffer(0)]],
        texture2d<float> baseColorMap [[texture(0)]], sampler baseColorSampler [[sampler(0)]],
        texture2d<float> metallicRoughnessMap [[texture(1)]], sampler metallicRoughnessSampler [[sampler(1)]],
        texture2d<float> normalMap [[texture(2)]], sampler normalSampler [[sampler(2)]],
        texture2d<float> occlusionMap [[texture(3)]], sampler occlusionSampler [[sampler(3)]],
        texture2d<float> emissiveMap [[texture(4)]], sampler emissiveSampler [[sampler(4)]],
        texture2d<float> shadow0 [[texture(8)]], texture2d<float> shadow1 [[texture(9)]],
        texture2d<float> shadow2 [[texture(10)]], texture2d<float> shadow3 [[texture(11)]],
        sampler shadowSampler [[sampler(8)]]
    ) {
        float4 base = u.baseColor * float4(in.color.rgb, in.color.a);
    #ifdef HAS_BASECOLOR
        float4 texel = baseColorMap.sample(baseColorSampler, in.uv);
        base *= float4(toLinear(texel.rgb), texel.a);
    #endif
    #ifdef ALPHA_MASK
        if (base.a < u.alphaCutoff) discard_fragment();
        base.a = 1.0;
    #elif !defined(ALPHA_BLEND)
        base.a = 1.0;
    #endif
        float3 color;
    #ifdef UNLIT
        color = base.rgb;
    #else
        float3 n = normalize(in.normal);
    #ifdef DOUBLE_SIDED
        if (!front) n = -n;
    #endif
    #ifdef HAS_NORMAL
        float3 t = in.tangent.xyz - n * dot(n, in.tangent.xyz);
        if (dot(t, t) > 1e-10) {
            t = normalize(t);
            float3 b = cross(n, t) * (in.tangent.w < 0 ? -1.0 : 1.0);
    #ifdef DOUBLE_SIDED
            if (!front) b = -b;
    #endif
            float3 m = normalMap.sample(normalSampler, in.uv).xyz * 2.0 - 1.0;
            m.xy *= u.pbr.z;
            n = normalize(t * m.x + b * m.y + n * m.z);
        }
    #endif
        float metallic = u.pbr.x;
        float roughness = u.pbr.y;
    #ifdef HAS_METALLICROUGHNESS
        float4 mr = metallicRoughnessMap.sample(metallicRoughnessSampler, in.uv);
        metallic *= mr.b;
        roughness *= mr.g;
    #endif
        metallic = saturate(metallic);
        roughness = clamp(roughness, 0.03, 1.0);
        float alpha = roughness * roughness;
        float3 diffuseColor = base.rgb * (1.0 - metallic);
        float3 f0 = mix(float3(0.04), base.rgb, metallic);
        float3 v = normalize(u.eye - in.world);
        float nv = max(dot(n, v), 1e-4);

        color = float3(0);
        for (int i = 0; i < 4; i++) {
            constant Light& light = u.lights[i];
            if (all(light.color == 0)) continue;
            float3 l;
            float3 radiance = incoming(light, in.world, l);
            float nl = dot(n, l);
            if (nl <= 0) continue;
            radiance *= visibility(u, light, in.world, normalize(in.normal), shadow0, shadow1, shadow2, shadow3, shadowSampler);
            float3 h = normalize(l + v);
            float nh = saturate(dot(n, h));
            float vh = saturate(dot(v, h));
            float a2 = alpha * alpha;
            float denominator = nh * nh * (a2 - 1.0) + 1.0;
            float d = a2 / (PI * denominator * denominator);
            float gv = nl * sqrt(nv * nv * (1.0 - a2) + a2);
            float gl = nv * sqrt(nl * nl * (1.0 - a2) + a2);
            float visible = 0.5 / max(gv + gl, 1e-5);
            float3 f = f0 + (1.0 - f0) * pow(1.0 - vh, 5.0);
            // Scaled by π so that a white diffuse surface facing a light of intensity 1 shows 1.
            color += (diffuseColor * (1.0 - f) + PI * d * visible * f) * radiance * nl;
        }

        // Light from all round: diffuse from the hemisphere about the normal, specular from
        // the reflection (a fitted split-sum term, Karis 2014).
        float3 r = reflect(-v, n);
        r = normalize(mix(r, n, alpha));
        const float4 c0 = float4(-1, -0.0275, -0.572, 0.022);
        const float4 c1 = float4(1, 0.0425, 1.04, -0.04);
        float4 rr = roughness * c0 + c1;
        float a004 = min(rr.x * rr.x, exp2(-9.28 * nv)) * rr.x + rr.y;
        float2 ab = float2(-1.04, 1.04) * a004 + rr.zw;
        float3 ambient = diffuseColor * hemisphere(u, n) + hemisphere(u, r) * (f0 * ab.x + ab.y);
    #ifdef HAS_OCCLUSION
        ambient *= mix(1.0, occlusionMap.sample(occlusionSampler, in.uv).r, u.pbr.w);
    #endif
        color += ambient;
    #endif
        float3 emission = float3(u.emissive);
    #ifdef HAS_EMISSIVE
        emission *= toLinear(emissiveMap.sample(emissiveSampler, in.uv).rgb);
    #endif
        color += emission;
        color = toSRGB(neutral(color)) * float3(u.layerColor);
        float a = base.a * u.layerAlpha;
        return float4(color * a, a);
    }

    fragment float4 floorFragment(
        Fragment in [[stage_in]], constant FragmentUniforms& u [[buffer(0)]],
        texture2d<float> shadow0 [[texture(8)]], texture2d<float> shadow1 [[texture(9)]],
        texture2d<float> shadow2 [[texture(10)]], texture2d<float> shadow3 [[texture(11)]],
        sampler shadowSampler [[sampler(8)]]
    ) {
        float3 n = normalize(in.normal);
        float strongest = 0;
        for (int i = 0; i < 4; i++) {
            float3 c = u.lights[i].color;
            strongest = max(strongest, max(c.r, max(c.g, c.b)));
        }
        float shade = 0;
        for (int i = 0; i < 4; i++) {
            constant Light& light = u.lights[i];
            if (light.params.w < 0 || all(light.color == 0)) continue;
            float3 l;
            float3 radiance = incoming(light, in.world, l);
            if (dot(n, l) <= 0) continue;
            float share = max(radiance.r, max(radiance.g, radiance.b)) / max(strongest, 1e-5);
            float lit = visibility(u, light, in.world, n, shadow0, shadow1, shadow2, shadow3, shadowSampler);
            shade = max(shade, (1.0 - lit) * saturate(share));
        }
        float a = shade * u.floor.x;
        return float4(0, 0, 0, a);
    }
    """
}

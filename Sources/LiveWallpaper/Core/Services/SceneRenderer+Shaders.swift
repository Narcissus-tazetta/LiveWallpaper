import Foundation

extension SceneRenderer {
    /// Apple GPUs can read the pixel being drawn, so every layer is blended in one
    /// render pass without writing the canvas out between layers. Other GPUs cannot
    /// compile this.
    static let fetchShaderSource = shaderSource + """

    fragment float4 scene_composite_fetch(VertexOut in [[stage_in]],
                                          float4 below [[color(0)]],
                                          texture2d<float> layer [[texture(1)]],
                                          texture2d<float> depth [[texture(2)]],
                                          constant LayerUniforms &u [[buffer(0)]]) {
        return float4(compositeLayer(below.rgb, u.viewOrigin + in.uv * u.viewSize, layer, depth, u), 1.0);
    }
    """

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut scene_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VertexOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(p.x, 1.0 - p.y);
        return out;
    }

    fragment float4 scene_loop_fade(VertexOut in [[stage_in]], texture2d<float> later [[texture(0)]],
                                    texture2d<float> now [[texture(1)]], constant float &weight [[buffer(0)]]) {
        constexpr sampler s(filter::nearest);
        return mix(later.sample(s, in.uv), now.sample(s, in.uv), weight);
    }

    // MARK: composite

    struct LayerUniforms {
        float2 uvScale;
        float2 uvOffset;
        float2 cursor;
        float2 maskScale;
        float2 depthShift;
        float2 placementColumn0;
        float2 placementColumn1;
        float2 placementOffset;
        float2 viewOrigin;
        float2 viewSize;
        int hasDepth;
        int depthSteps;
        float opacity;
        float maskRadius;
        float maskSoftness;
        int blendMode;
        int maskMode;
        int hasCursor;
        int hasLayer;
        float brightness;
        float saturation;
        float warmth;
        int hasColor;
        float tintRed;
        float tintGreen;
        float tintBlue;
    };

    float3 rgbToHSL(float3 c) {
        float low = min(min(c.r, c.g), c.b), high = max(max(c.r, c.g), c.b), delta = high - low;
        float3 hsl = float3(0.0, 0.0, (high + low) / 2.0);
        if (delta == 0.0) { return hsl; }
        hsl.y = hsl.z < 0.5 ? delta / (high + low) : delta / (2.0 - high - low);
        float3 d = (((high - c) / 6.0) + (delta / 2.0)) / delta;
        if (c.r == high) { hsl.x = d.b - d.g; }
        else if (c.g == high) { hsl.x = (1.0 / 3.0) + d.r - d.b; }
        else { hsl.x = (2.0 / 3.0) + d.g - d.r; }
        hsl.x = hsl.x < 0.0 ? hsl.x + 1.0 : (hsl.x > 1.0 ? hsl.x - 1.0 : hsl.x);
        return hsl;
    }

    float hueToRGB(float f1, float f2, float hue) {
        hue = hue < 0.0 ? hue + 1.0 : (hue > 1.0 ? hue - 1.0 : hue);
        if (6.0 * hue < 1.0) { return f1 + (f2 - f1) * 6.0 * hue; }
        if (2.0 * hue < 1.0) { return f2; }
        if (3.0 * hue < 2.0) { return f1 + (f2 - f1) * ((2.0 / 3.0) - hue) * 6.0; }
        return f1;
    }

    float3 hslToRGB(float3 hsl) {
        if (hsl.y == 0.0) { return float3(hsl.z); }
        float f2 = hsl.z < 0.5 ? hsl.z * (1.0 + hsl.y) : (hsl.z + hsl.y) - (hsl.y * hsl.z);
        float f1 = 2.0 * hsl.z - f2;
        return float3(hueToRGB(f1, f2, hsl.x + 1.0 / 3.0), hueToRGB(f1, f2, hsl.x), hueToRGB(f1, f2, hsl.x - 1.0 / 3.0));
    }

    float3 overlayBlend(float3 b, float3 s) { return select(1.0 - 2.0 * (1.0 - b) * (1.0 - s), 2.0 * b * s, b < 0.5); }
    float colorDodgeF(float b, float s) { return s == 1.0 ? s : min(b / (1.0 - s), 1.0); }
    float colorBurnF(float b, float s) { return s == 0.0 ? s : max(1.0 - (1.0 - b) / s, 0.0); }
    float vividLightF(float b, float s) { return s < 0.5 ? colorBurnF(b, 2.0 * s) : colorDodgeF(b, 2.0 * (s - 0.5)); }
    float reflectF(float b, float s) { return s == 1.0 ? s : min(b * b / (1.0 - s), 1.0); }
    float3 perChannel(int mode, float3 b, float3 s) {
        float3 r;
        for (int i = 0; i < 3; i++) {
            float x = b[i], y = s[i];
            switch (mode) {
            case 6: r[i] = colorBurnF(x, y); break;
            case 10: r[i] = colorDodgeF(x, y); break;
            case 12: r[i] = y < 0.5 ? 2.0 * x * y + x * x * (1.0 - 2.0 * y) : sqrt(x) * (2.0 * y - 1.0) + 2.0 * x * (1.0 - y); break;
            case 14: r[i] = vividLightF(x, y); break;
            case 15: r[i] = y < 0.5 ? max(x + 2.0 * y - 1.0, 0.0) : x + 2.0 * (y - 0.5); break;
            case 16: r[i] = y < 0.5 ? min(2.0 * y, x) : max(2.0 * (y - 0.5), x); break;
            case 17: r[i] = vividLightF(x, y) < 0.5 ? 0.0 : 1.0; break;
            case 20: r[i] = reflectF(x, y); break;
            default: r[i] = reflectF(y, x); break;
            }
        }
        return r;
    }
    /// The blended colour that the layer's alpha then mixes in, by SceneBlendMode position.
    float3 blend(int mode, float3 b, float3 s) {
        switch (mode) {
        case 1: return b * s;
        case 2: return 1.0 - (1.0 - b) * (1.0 - s);
        case 3: return overlayBlend(b, s);
        case 4: return min(b + s, 1.0);
        case 5: return min(s, b);
        case 7: return max(b + s - 1.0, 0.0);
        case 8: return min(b, s);
        case 9: return max(s, b);
        case 11: return max(b, s);
        case 13: return overlayBlend(s, b);
        case 18: return abs(b - s);
        case 19: return b + s - 2.0 * b * s;
        case 22: return min(b, s) - max(b, s) + 1.0;
        case 23: return (b + s) / 2.0;
        case 24: return 1.0 - abs(1.0 - b - s);
        case 25: { float3 l = rgbToHSL(b); return hslToRGB(float3(rgbToHSL(s).x, l.y, l.z)); }
        case 26: { float3 l = rgbToHSL(b); return hslToRGB(float3(l.x, rgbToHSL(s).y, l.z)); }
        case 27: { float3 l = rgbToHSL(s); return hslToRGB(float3(l.x, l.y, rgbToHSL(b).z)); }
        case 28: { float3 l = rgbToHSL(b); return hslToRGB(float3(l.x, l.y, rgbToHSL(s).z)); }
        case 29: return max(b.x, max(b.y, b.z)) * s;
        case 30: return b + s;
        case 31: return b + b * s;
        case 6: case 10: case 12: case 14: case 15: case 16: case 17: case 20: case 21: return perChannel(mode, b, s);
        default: return s;
        }
    }

    float4 sampleInside(texture2d<float> t, sampler s, float2 uv) {
        float2 inside = step(0.0, uv) * step(uv, 1.0);
        return t.sample(s, uv) * inside.x * inside.y;
    }

    /// One layer over `below`: placement, depth, cursor mask and blend mode.
    float3 compositeLayer(float3 below, float2 uv, texture2d<float> layer, texture2d<float> depth,
                          constant LayerUniforms &u) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 relative = uv - 0.5 - u.placementOffset;
        float2 placed = u.placementColumn0 * relative.x + u.placementColumn1 * relative.y;
        float2 layerUV = placed * u.uvScale + 0.5 + u.uvOffset;
        if (u.hasDepth != 0) {
            // A source pixel at depth d shows up shifted by depthShift * (2d - 1).
            // March from the nearest possible depth to the farthest and take the
            // first surface that reaches this pixel, so near things cover far ones
            // (iterating a fixed point instead doubled edges where depth jumps).
            int steps = u.depthSteps;
            float previousT = 1.0;
            float previousF = depth.sample(s, layerUV - u.depthShift).r * 2.0 - 1.0 - 1.0;
            float hitT = -1.0;
            for (int i = 1; i <= steps; i++) {
                float t = 1.0 - 2.0 * float(i) / float(steps);
                float f = depth.sample(s, layerUV - u.depthShift * t).r * 2.0 - 1.0 - t;
                if (f >= 0.0) {
                    // Linear refinement between the last two steps.
                    hitT = mix(previousT, t, previousF / min(previousF - f, -1e-5));
                    break;
                }
                previousT = t;
                previousF = f;
            }
            layerUV = layerUV - u.depthShift * hitT;
        }
        float4 src = sampleInside(layer, s, layerUV);
        // minimum and maximum ignore alpha across the picture; elsewhere nothing changes.
        if (u.blendMode == 8 || u.blendMode == 11) {
            bool inside = all(layerUV >= 0.0) && all(layerUV <= 1.0);
            float3 straight = src.a > 0.0 ? src.rgb / src.a : float3(0.0);
            return inside ? blend(u.blendMode, below, straight) : below;
        }
        float alpha = src.a * u.opacity;
        float3 color = src.a > 0.0 ? src.rgb / src.a : float3(0.0);
        // Skipped when unchanged, so layers without links draw exactly as before.
        if (u.hasColor != 0) {
            color *= float3(u.tintRed, u.tintGreen, u.tintBlue);
            float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
            color = mix(float3(luma), color, u.saturation);
            color *= float3(1.0 + 0.2 * u.warmth, 1.0, 1.0 - 0.2 * u.warmth);
            color = clamp(color * (1.0 + u.brightness), 0.0, 1.0);
        }
        if (u.maskMode >= 0) {
            float near = 0.0;
            if (u.hasCursor != 0) {
                float dist = length((uv - u.cursor) * u.maskScale);
                float inner = u.maskRadius * (1.0 - u.maskSoftness);
                near = 1.0 - smoothstep(inner, u.maskRadius + 1e-4, dist);
            }
            alpha *= u.maskMode == 0 ? 1.0 - near : near;
        }
        float3 mixed = blend(u.blendMode, below, color);
        return mix(below, mixed, alpha);
    }

    fragment float4 scene_capture(VertexOut in [[stage_in]],
                                  texture2d<float> base [[texture(0)]],
                                  constant LayerUniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 placed = (in.uv - 0.5 - u.uvOffset) / u.uvScale;
        float det = u.placementColumn0.x * u.placementColumn1.y - u.placementColumn1.x * u.placementColumn0.y;
        if (abs(det) < 1e-8) { return float4(0.0); }
        float2 relative = float2(u.placementColumn1.y * placed.x - u.placementColumn1.x * placed.y,
                                 -u.placementColumn0.y * placed.x + u.placementColumn0.x * placed.y) / det;
        float2 canvasUV = relative + 0.5 + u.placementOffset;
        float2 targetUV = (canvasUV - u.viewOrigin) / u.viewSize;
        return float4(base.sample(s, targetUV).rgb, 1.0);
    }

    fragment float4 scene_composite(VertexOut in [[stage_in]],
                                    texture2d<float> base [[texture(0)]],
                                    texture2d<float> layer [[texture(1)]],
                                    texture2d<float> depth [[texture(2)]],
                                    constant LayerUniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 below = base.sample(s, in.uv);
        if (u.hasLayer == 0) {
            return float4(below.rgb, 1.0);
        }
        return float4(compositeLayer(below.rgb, u.viewOrigin + in.uv * u.viewSize, layer, depth, u), 1.0);
    }

    // MARK: effects

    struct EffectUniforms {
        float4 bounds;
        float2 center;
        float2 direction;
        float2 scrollStep;
        float phase;
        float strength;
        float scale;
        float aspect;
        int kind;
        int cycles;
        int reversed;
        int overlay;
        int hasMask;
        int fixedEdge;
        float time;
        int hasTimeOffset;
        int patternClamps;
    };

    constant float TAU = 6.28318530718;

    float2 rotate2(float2 v, float angle) {
        float c = cos(angle), s = sin(angle);
        return float2(v.x * c - v.y * s, v.x * s + v.y * c);
    }

    float4 samplePattern(texture2d<float> pattern, float2 uv, constant EffectUniforms &u) {
        constexpr sampler clamped(filter::linear, address::clamp_to_edge);
        constexpr sampler repeating(filter::linear, address::repeat);
        return u.patternClamps != 0 ? pattern.sample(clamped, uv) : pattern.sample(repeating, uv);
    }

    float layerAspect(float stored, constant EffectUniforms &u) { return stored > 0.0 ? stored : u.aspect; }

    // Flow map (values: cycles at this frame, strength, feather, phaseScale). Two pairs of copies a
    // quarter cycle apart, each pair crossfading as one copy resets.
    float4 flowMap(texture2d<float> src, texture2d<float> flow, texture2d<float> pattern, sampler s, float2 uv,
                   constant EffectUniforms &u, constant float *v) {
        float t = v[0];
        float4 cycles = fract(float4(t, t + 0.5, 0.25 + t, 0.75 + t));
        float2 edges = float2(0.5 - v[2], 0.5 + v[2]);
        float blend = smoothstep(edges.x, edges.y, 2.0 * abs(cycles.x - 0.5));
        float blend2 = smoothstep(edges.x, edges.y, 2.0 * abs(cycles.z - 0.5));
        cycles -= 0.5;
        float phase = samplePattern(pattern, uv * v[3], u).r;
        float2 flowVector = (flow.sample(s, uv).rg - float2(0.498)) * 2.0;
        float2 travel = flowVector * v[1] * 0.1;
        float4 a = mix(src.sample(s, uv + travel * cycles.x), src.sample(s, uv + travel * cycles.y), blend);
        float4 b = mix(src.sample(s, uv + travel * cycles.z), src.sample(s, uv + travel * cycles.w), blend2);
        float4 flowing = mix(a, b, smoothstep(0.2, 0.8, phase));
        return mix(src.sample(s, uv), flowing, length(flowVector));
    }

    // Normal ripples (values: animationSpeed, scale, scrollSpeed, scrollAngle, ratio,
    // strength, textureAspect, specular, power, strength, rgb, then the two copies'
    // shifts at this frame in pattern repeats).
    float4 normalRipples(texture2d<float> src, texture2d<float> mask, texture2d<float> pattern, sampler s, float2 uv,
                         constant EffectUniforms &u, constant float *v) {
        float m = u.hasMask != 0 ? mask.sample(s, uv).r : 1.0;
        float4 coords = float4(uv, uv * 1.333) * v[1];
        float aspect = layerAspect(v[6], u);
        coords.xz *= aspect;
        coords.yw *= v[4];
        coords += float4(v[13], v[14], v[15], v[16]);
        float3 n1 = samplePattern(pattern, coords.xy, u).xyz * 2.0 - 1.0;
        float3 n2 = samplePattern(pattern, coords.zw, u).xyz * 2.0 - 1.0;
        float3 normal = normalize(float3(n1.xy + n2.xy, n1.z));
        float4 result = src.sample(s, uv + normal.xy * v[5] * v[5] * m);
        if (v[7] != 0.0) {
            float2 toward = normalize(float2(0.5, 0.0) - uv);
            float light = max(0.0, dot(normal.xy, toward)) * max(0.0, dot(toward, float2(0.0, -1.0)));
            result.rgb += pow(light, v[8]) * v[9] * float3(v[10], v[11], v[12]) * result.a;
        }
        return result;
    }

    // Noise drift (values: shift at this frame, scale, scaleX, amount, angle, textureAspect).
    float4 noiseDrift(texture2d<float> src, texture2d<float> mask, texture2d<float> pattern, sampler s, float2 uv,
                      constant EffectUniforms &u, constant float *v) {
        float m = u.hasMask != 0 ? mask.sample(s, uv).r : 1.0;
        float2 noiseUV = uv;
        noiseUV.x *= layerAspect(v[5], u);
        noiseUV *= v[1];
        noiseUV.x *= v[2];
        noiseUV.x += v[0];
        float noise = samplePattern(pattern, noiseUV, u).x;
        float2 offset = rotate2(float2((noise * 2.0 - 1.0) * v[3] * m, 0.0), v[4] + 1.57079632679);
        float2 moved = uv + offset;
        if (u.hasMask != 0) {
            moved = mix(uv, moved, mask.sample(s, uv + offset).r);
        }
        return src.sample(s, moved);
    }

    // Noise sway (values: the eight sines' angles at this frame, strength, phase, power, noiseScale,
    // ratio, angle).
    float4 noiseSway(texture2d<float> src, texture2d<float> mask, texture2d<float> pattern, sampler s, float2 uv,
                     constant EffectUniforms &u, constant float *v) {
        float stretch = u.aspect * v[12];
        float2 axes = rotate2(float2(1.0 / stretch, stretch), v[13]);
        float2 turned = rotate2(uv, v[13]);
        float amplitude = v[8] * v[8] * 0.005 * (u.hasMask != 0 ? mask.sample(s, uv).r : 1.0);
        float3 noise = samplePattern(pattern, uv * v[11], u).rgb;
        float phase = (noise.g * 3.14159265359 * 2.0 + turned.x * 10.0 + turned.y * 5.0) * v[9];
        float4 sines = sin(phase + float4(v[0], v[1], v[2], v[3]));
        float4 cosines = sin(0.4 + phase + float4(v[4], v[5], v[6], v[7]));
        sines = pow(abs(sines), float4(v[10])) * sign(sines);
        cosines = pow(abs(cosines), float4(v[10])) * sign(cosines);
        float2 offset = float2(axes.x * dot(sines, float4(amplitude)), axes.y * dot(cosines, float4(amplitude)));
        return src.sample(s, uv + offset);
    }

    float overlayChannel(float a, float b) { return a < 0.5 ? 2.0 * a * b : 1.0 - 2.0 * (1.0 - a) * (1.0 - b); }
    float softLightChannel(float a, float b) {
        return b < 0.5 ? 2.0 * a * b + a * a * (1.0 - 2.0 * b) : sqrt(a) * (2.0 * b - 1.0) + 2.0 * a * (1.0 - b);
    }
    float dodgeChannel(float a, float b) { return b == 1.0 ? b : min(a / (1.0 - b), 1.0); }
    float burnChannel(float a, float b) { return b == 0.0 ? b : max(1.0 - (1.0 - a) / b, 0.0); }
    float vividChannel(float a, float b) { return b < 0.5 ? burnChannel(a, 2.0 * b) : dodgeChannel(a, 2.0 * (b - 0.5)); }
    float linearLightChannel(float a, float b) {
        return b < 0.5 ? max(a + 2.0 * b - 1.0, 0.0) : a + 2.0 * (b - 0.5);
    }
    float pinChannel(float a, float b) { return b < 0.5 ? min(a, 2.0 * b) : max(a, 2.0 * (b - 0.5)); }
    float reflectChannel(float a, float b) { return b == 1.0 ? b : min(a * a / (1.0 - b), 1.0); }

    // The usual image blend modes, numbered as the pulse effect stores them; each
    // mixes from A towards the blend by `amount`.
    float3 blendModes(int mode, float3 a, float3 b, float amount) {
        float3 blended;
        switch (mode) {
        case 1: blended = min(a, b); break;
        case 2: blended = a * b; break;
        case 3: blended = float3(burnChannel(a.r, b.r), burnChannel(a.g, b.g), burnChannel(a.b, b.b)); break;
        case 4: case 20: blended = max(a + b - 1.0, 0.0); break;
        case 5: return min(a, b);
        case 6: blended = max(a, b); break;
        case 7: blended = 1.0 - (1.0 - a) * (1.0 - b); break;
        case 8: blended = float3(dodgeChannel(a.r, b.r), dodgeChannel(a.g, b.g), dodgeChannel(a.b, b.b)); break;
        case 9: blended = min(a + b, 1.0); break;
        case 10: return max(a, b);
        case 11: blended = float3(overlayChannel(a.r, b.r), overlayChannel(a.g, b.g), overlayChannel(a.b, b.b)); break;
        case 12: blended = float3(softLightChannel(a.r, b.r), softLightChannel(a.g, b.g), softLightChannel(a.b, b.b)); break;
        case 13: blended = float3(overlayChannel(b.r, a.r), overlayChannel(b.g, a.g), overlayChannel(b.b, a.b)); break;
        case 14: blended = float3(vividChannel(a.r, b.r), vividChannel(a.g, b.g), vividChannel(a.b, b.b)); break;
        case 15: blended = float3(linearLightChannel(a.r, b.r), linearLightChannel(a.g, b.g), linearLightChannel(a.b, b.b)); break;
        case 16: blended = float3(pinChannel(a.r, b.r), pinChannel(a.g, b.g), pinChannel(a.b, b.b)); break;
        case 17: blended = float3(vividChannel(a.r, b.r) < 0.5 ? 0.0 : 1.0, vividChannel(a.g, b.g) < 0.5 ? 0.0 : 1.0,
                                  vividChannel(a.b, b.b) < 0.5 ? 0.0 : 1.0); break;
        case 18: blended = abs(a - b); break;
        case 19: blended = a + b - 2.0 * a * b; break;
        case 21: blended = float3(reflectChannel(a.r, b.r), reflectChannel(a.g, b.g), reflectChannel(a.b, b.b)); break;
        case 22: blended = float3(reflectChannel(b.r, a.r), reflectChannel(b.g, a.g), reflectChannel(b.b, a.b)); break;
        case 23: blended = min(a, b) - max(a, b) + 1.0; break;
        case 24: blended = (a + b) / 2.0; break;
        case 25: blended = 1.0 - abs(1.0 - a - b); break;
        case 26: { float3 h = rgbToHSL(a); blended = hslToRGB(float3(rgbToHSL(b).x, h.y, h.z)); break; }
        case 27: { float3 h = rgbToHSL(a); blended = hslToRGB(float3(h.x, rgbToHSL(b).y, h.z)); break; }
        case 28: { float3 h = rgbToHSL(b); blended = hslToRGB(float3(h.x, h.y, rgbToHSL(a).z)); break; }
        case 29: { float3 h = rgbToHSL(a); blended = hslToRGB(float3(h.x, h.y, rgbToHSL(b).z)); break; }
        case 30: blended = float3(max(a.x, max(a.y, a.z))) * b; break;
        case 31: return a + b * amount;
        case 32: blended = a + a * b; break;
        default: blended = b; break;
        }
        return mix(a, blended, amount);
    }

    // Pulse (values: angle at this frame, phase, amount, boundsMin, boundsMax, noiseSpeed,
    // noiseAmount, power, low rgb, high rgb, blendMode, pulsesColor, pulsesOpacity, noise shift).
    float4 pulseBlend(texture2d<float> src, texture2d<float> mask, texture2d<float> pattern, sampler s, float2 uv,
                      constant EffectUniforms &u, constant float *v) {
        float4 sampled = src.sample(s, uv);
        // Blends work on the colour itself, not on colour × opacity.
        float4 colour = sampled.a > 0.0 ? float4(sampled.rgb / sampled.a, sampled.a) : sampled;
        float pulse = smoothstep(v[3], v[4], sin(v[0] + (v[1] - 1.57079632679)) * 0.5 + 0.5) * v[2];
        pulse += samplePattern(pattern, float2(v[17], v[18]), u).r * v[6];
        pulse = pow(pulse, v[7]);
        float4 result = colour;
        if (v[15] != 0.0) {
            result.rgb = blendModes(int(v[14]), colour.rgb * float3(v[8], v[9], v[10]), colour.rgb * float3(v[11], v[12], v[13]), pulse);
        }
        if (v[16] != 0.0) {
            result.a *= pulse;
        }
        if (u.hasMask != 0) {
            result = mix(colour, result, mask.sample(s, uv).r);
        }
        return float4(max(result.rgb, 0.0) * result.a, result.a);
    }

    // UV scroll (values: shift x and y at this frame, repeatX, repeatY).
    float4 uvScroll(texture2d<float> src, sampler s, float2 uv, constant EffectUniforms &u, constant float *v) {
        return src.sample(s, fract((uv + float2(v[0], v[1])) * float2(v[2], v[3])));
    }

    // Axis swing (values: angle at this frame, phase, amount, x0, y0, x1, y1, size, center,
    // feather, doubleSided, noise, noiseSpeed, noiseAmount, textureAspect, noise shift).
    float4 axisSwing(texture2d<float> src, texture2d<float> mask, texture2d<float> pattern, sampler s, float2 uv,
                     constant EffectUniforms &u, constant float *v) {
        float aspect = layerAspect(v[14], u);
        float swing = sin(v[0] + v[1] * 6.28318530718) * v[2];
        float2 p0 = float2(v[3] * aspect, v[4]), p1 = float2(v[5] * aspect, v[6]);
        float2 q = float2(uv.x * aspect, uv.y);
        float2 axis = normalize(p1 - p0);
        float2 across = float2(-axis.y, axis.x);
        float2 delta = q - (p0 + (p1 - p0) * v[8]);
        float along = dot(axis, delta), side = dot(across, delta);
        if (v[11] != 0.0) {
            float noise = samplePattern(pattern, float2(v[15], v[16]), u).r * 3.141 * 2.0;
            swing = clamp(swing + sin(noise) * v[13], -1.0, 1.0);
        }
        q += axis * swing * side * along + across * swing * swing * side;
        float feather = max(v[9], 0.00001);
        float weight = smoothstep(feather, 0.0, dot(q - p1, axis)) * smoothstep(-feather, 0.0, dot(q - p0, axis));
        float size = v[7] * (1.0 - abs(swing) * v[2] * 0.5);
        weight *= smoothstep(size + feather, size - feather, side);
        weight *= v[10] != 0.0 ? smoothstep(size + feather, size - feather, -side) : step(0.0, side);
        if (u.hasMask != 0) {
            weight *= mask.sample(s, uv).r;
        }
        q.x /= aspect;
        return src.sample(s, mix(uv, q, weight));
    }

    // Travelling waves (values: angle at this frame, scale, amplitude, exponent, angle, dual,
    // second angle at this frame, scale2, offset2, exponent2, angle2, speed2). The direction turns (0, 1) by the
    // angle; the picture moves across it by sin(phase)^exponent × amplitude², scaled
    // by the mask where the pixel is.
    float4 travelingWaves(texture2d<float> src, texture2d<float> mask, texture2d<float> timeOffset, sampler s,
                          float2 uv, constant EffectUniforms &u, constant float *v) {
        float m = u.hasMask != 0 ? mask.sample(s, uv).r : 1.0;
        float delay = u.hasTimeOffset != 0 ? timeOffset.sample(s, uv).r * TAU : 0.0;
        float2 direction = float2(-sin(v[4]), cos(v[4]));
        float phase = v[0] + dot(uv, direction) * v[1] + delay;
        float wave = sin(phase);
        float shaped = pow(abs(wave), v[3]) * sign(wave);
        if (v[5] != 0.0) {
            float2 direction2 = float2(-sin(v[10]), cos(v[10]));
            float phase2 = v[6] + v[8] * v[11] + dot(uv, direction2) * v[7] + delay;
            float wave2 = sin(phase2);
            shaped *= pow(abs(wave2), v[9]) * sign(wave2);
        }
        float2 across = float2(direction.y, -direction.x);
        return src.sample(s, uv + shaped * across * v[2] * v[2] * m);
    }

    // Flow shake (values: the swing's angle at this frame, amplitude, frictionX, frictionY, boundsMin,
    // boundsMax, side, irregular, then the four angles of the irregular swing). The
    // flow map holds each pixel's vector around 0.498; the mask is read where the
    // moved pixel comes from.
    float4 flowShake(texture2d<float> src, texture2d<float> mask, texture2d<float> flow, texture2d<float> timeOffset,
                     sampler s, float2 uv, constant EffectUniforms &u, constant float *v) {
        float delay = u.hasTimeOffset != 0 ? timeOffset.sample(s, uv).r * TAU : 0.0;
        float2 flowVector = (flow.sample(s, uv).rg - float2(0.498)) * 2.0;
        float2 friction = float2(v[2], v[3]);
        float offset;
        if (v[7] != 0.0) {
            float4 angles = delay + float4(v[8], v[9], v[10], v[11]);
            float4 rising = step(0.0, cos(angles));
            float4 sines = sin(angles) * 0.498 + 0.5;
            sines = mix(1.0 - pow(1.0 - sines, float4(friction.x)), pow(sines, float4(friction.y)), rising);
            offset = dot(float4(0.5), sines);
        } else {
            float angle = v[0] + delay;
            offset = sin(fract(angle / TAU) * TAU) * 0.498 + 0.5;
            offset = mix(1.0 - pow(1.0 - offset, friction.x), pow(offset, friction.y), step(0.0, cos(angle)));
        }
        offset = saturate((offset - v[4]) / (v[5] - v[4]));
        if (v[6] == 0.0) {
            offset = offset * 2.0 - 1.0;
        } else if (v[6] == 2.0) {
            offset -= 1.0;
        }
        float2 moved = offset * v[1] * v[1] * flowVector;
        float4 result = src.sample(s, uv + moved);
        if (u.hasMask != 0) {
            result = mix(src.sample(s, uv), result, mask.sample(s, uv + moved).r);
        }
        return result;
    }

    float hash3(float3 p) {
        p = fract(p * 0.3183099 + 0.1);
        p *= 17.0;
        return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
    }

    float valueNoise(float3 x) {
        float3 i = floor(x);
        float3 f = fract(x);
        f = f * f * (3.0 - 2.0 * f);
        return mix(mix(mix(hash3(i + float3(0, 0, 0)), hash3(i + float3(1, 0, 0)), f.x),
                       mix(hash3(i + float3(0, 1, 0)), hash3(i + float3(1, 1, 0)), f.x), f.y),
                   mix(mix(hash3(i + float3(0, 0, 1)), hash3(i + float3(1, 0, 1)), f.x),
                       mix(hash3(i + float3(0, 1, 1)), hash3(i + float3(1, 1, 1)), f.x), f.y), f.z);
    }

    float fbm(float3 x) {
        return valueNoise(x) * 0.65 + valueNoise(x * 2.03 + 7.1) * 0.35;
    }

    // Distortions read past the layer's edge as the edge colour: a full-canvas layer
    // would otherwise open black gaps, and a cut-out's edge is transparent anyway.
    // They work in a space where the layer's height is 1, so circles stay round.
    float2 toSpace(float2 uv, float aspect) { return float2(uv.x * aspect, uv.y); }
    float2 toUV(float2 q, float aspect) { return float2(q.x / aspect, q.y); }

    // A moved pixel that would come from outside the painted area keeps its own
    // colour: otherwise the edge of the area smears what is around it inside.
    float4 sampleMoved(texture2d<float> src, texture2d<float> mask, sampler s, float2 suv, float4 original,
                       constant EffectUniforms &u) {
        float4 moved = src.sample(s, suv);
        return u.hasMask != 0 ? mix(original, moved, mask.sample(s, suv).r) : moved;
    }

    // 0 at the fixed side of the area, rising to 1 at the opposite side.
    float edgeWeight(float2 uv, constant EffectUniforms &u) {
        float4 b = u.bounds;
        float t;
        switch (u.fixedEdge) {
        case 1: t = (uv.y - b.y) / max(b.w - b.y, 1e-4); break;
        case 2: t = (b.w - uv.y) / max(b.w - b.y, 1e-4); break;
        case 3: t = (uv.x - b.x) / max(b.z - b.x, 1e-4); break;
        case 4: t = (b.z - uv.x) / max(b.z - b.x, 1e-4); break;
        default: return 1.0;
        }
        return smoothstep(0.0, 1.0, clamp(t, 0.0, 1.0));
    }

    float2 rotateAround(float2 q, float2 c, float angle) {
        float s = sin(angle);
        float co = cos(angle);
        float2 d = q - c;
        return c + float2(d.x * co - d.y * s, d.x * s + d.y * co);
    }

    fragment float4 scene_effect(VertexOut in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 texture2d<float> mask [[texture(1)]],
                                 texture2d<float> flow [[texture(2)]],
                                 texture2d<float> timeOffset [[texture(3)]],
                                 texture2d<float> pattern [[texture(4)]],
                                 constant EffectUniforms &u [[buffer(0)]],
                                 constant float4 *pins [[buffer(1)]],
                                 constant float *realTime [[buffer(2)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        constexpr sampler wrap(filter::linear, address::repeat);
        float2 uv = in.uv;
        float m = (u.hasMask != 0 ? mask.sample(s, uv).r : 1.0) * edgeWeight(uv, u);
        float w = TAU * float(u.cycles) * u.phase;
        float2 q = toSpace(uv, u.aspect);
        float2 c = toSpace(u.center, u.aspect);
        float2 dir = normalize(toSpace(u.direction, 1.0));
        float2 perp = float2(-dir.y, dir.x);
        float4 original = src.sample(s, uv);
        float4 result = original;

        switch (u.kind) {
        case 0: { // shake
            float2 d = dir * (u.strength * 0.03) * sin(w);
            result = sampleMoved(src, mask, s, toUV(q - d * m, u.aspect), original, u);
            break;
        }
        case 1: { // sway
            float k = mix(2.0, 24.0, u.scale);
            float2 d = dir * (u.strength * 0.02) * sin(w - k * dot(q, dir));
            result = sampleMoved(src, mask, s, toUV(q - d * m, u.aspect), original, u);
            break;
        }
        case 2: { // swing
            float angle = u.strength * 0.35 * sin(w) * m;
            result = sampleMoved(src, mask, s, toUV(rotateAround(q, c, -angle), u.aspect), original, u);
            break;
        }
        case 3: { // waves
            float k = mix(4.0, 60.0, u.scale);
            float2 d = perp * (u.strength * 0.01) * sin(k * dot(q, dir) - w);
            result = sampleMoved(src, mask, s, toUV(q - d * m, u.aspect), original, u);
            break;
        }
        case 4: { // ripple
            float2 v = q - c;
            float r = length(v);
            float k = mix(10.0, 120.0, u.scale);
            float2 d = r > 1e-4 ? (v / r) * (u.strength * 0.01) * sin(k * r - w) : float2(0.0);
            result = sampleMoved(src, mask, s, toUV(q - d * m, u.aspect), original, u);
            break;
        }
        case 5: { // water flow: two samples half a cycle apart hide each one's reset
            float2 f = (flow.sample(s, uv).rg * 2.0 - 1.0) * (u.strength * 0.08) * m;
            float p0 = fract(float(u.cycles) * u.phase);
            float p1 = fract(p0 + 0.5);
            float4 a = sampleMoved(src, mask, s, toUV(q - f * p0, u.aspect), original, u);
            float4 b = sampleMoved(src, mask, s, toUV(q - f * p1, u.aspect), original, u);
            result = mix(a, b, abs(1.0 - 2.0 * p0));
            break;
        }
        case 12: { // drift: the water flow's two offset copies, one direction everywhere
            float2 f = dir * (u.strength * 0.08) * m;
            float p0 = fract(float(u.cycles) * u.phase);
            float p1 = fract(p0 + 0.5);
            float4 a = sampleMoved(src, mask, s, toUV(q - f * p0, u.aspect), original, u);
            float4 b = sampleMoved(src, mask, s, toUV(q - f * p1, u.aspect), original, u);
            result = mix(a, b, abs(1.0 - 2.0 * p0));
            break;
        }
        case 6: { // scroll
            float2 shifted = uv - u.scrollStep * float(u.cycles) * u.phase;
            result = mix(original, src.sample(wrap, shifted), m);
            break;
        }
        case 7: { // cloud motion: noise drifting around a circle in time, so it loops
            float f = mix(1.5, 8.0, u.scale);
            float3 p = float3(q * f, 0.0) + float3(0.0, sin(w), cos(w)) * 0.8;
            float2 d = (float2(fbm(p), fbm(p + 19.3)) - 0.5) * (u.strength * 0.06);
            result = sampleMoved(src, mask, s, toUV(q - d * m, u.aspect), original, u);
            break;
        }
        case 8: { // spin: whole turns per loop
            float angle = (u.reversed != 0 ? -1.0 : 1.0) * w;
            result = mix(original, src.sample(s, toUV(rotateAround(q, c, -angle), u.aspect)), m);
            break;
        }
        case 9: { // twirl
            float radius = mix(0.05, 0.7, u.scale);
            float r = length(q - c);
            float falloff = r < radius ? pow(1.0 - r / radius, 2.0) : 0.0;
            float angle = (u.reversed != 0 ? -1.0 : 1.0) * u.strength * 3.14159 * falloff * sin(w) * m;
            result = sampleMoved(src, mask, s, toUV(rotateAround(q, c, -angle), u.aspect), original, u);
            break;
        }
        case 11: { // puppet: displacement blended from nearby pins, fading to none
            int count = int(pins[0].x);
            float radius = mix(0.05, 0.6, u.scale);
            float2 sum = float2(0.0);
            float weights = 0.05;
            for (int i = 1; i <= count; i++) {
                float distance = length(q - pins[i].xy) / radius;
                float w = 1.0 / (1.0 + distance * distance * distance * distance);
                sum += pins[i].zw * w;
                weights += w;
            }
            float2 d = sum / weights;
            result = sampleMoved(src, mask, s, toUV(q - d * m, u.aspect), original, u);
            break;
        }
        case 10: { // pulse
            float dim = u.strength * (0.5 - 0.5 * cos(w));
            result = float4(original.rgb * (1.0 - dim * m), original.a);
            break;
        }
        case 13: // travelling waves
            result = travelingWaves(src, mask, timeOffset, s, uv, u, realTime);
            break;
        case 14: // flow shake
            result = flowShake(src, mask, flow, timeOffset, s, uv, u, realTime);
            break;
        case 15: // flow map
            result = mix(original, flowMap(src, flow, pattern, s, uv, u, realTime), m);
            break;
        case 16: // normal ripples
            result = normalRipples(src, mask, pattern, s, uv, u, realTime);
            break;
        case 17: // noise drift
            result = noiseDrift(src, mask, pattern, s, uv, u, realTime);
            break;
        case 18: // noise sway
            result = noiseSway(src, mask, pattern, s, uv, u, realTime);
            break;
        case 19: // pulse blend
            result = pulseBlend(src, mask, pattern, s, uv, u, realTime);
            break;
        case 20: // uv scroll
            result = mix(original, uvScroll(src, s, uv, u, realTime), m);
            break;
        case 22:
            result = original * clamp(realTime[0], 0.0, 1.0) * mask.sample(s, uv).r;
            break;
        case 21: // axis swing
            result = axisSwing(src, mask, pattern, s, uv, u, realTime);
            break;
        default:
            break;
        }

        if (u.overlay == 1) {
            result = mix(result, float4(1.0, 0.25, 0.3, 1.0), m * 0.45);
        } else if (u.overlay == 2) {
            float strength = length(flow.sample(s, uv).rg * 2.0 - 1.0);
            result = mix(result, float4(0.2, 0.55, 1.0, 1.0), clamp(strength, 0.0, 1.0) * 0.5);
        } else if (u.overlay == 3) {
            result = mix(result, float4(0.75, 0.35, 1.0, 1.0), timeOffset.sample(s, uv).r * 0.5);
        }
        return result;
    }

    // MARK: particles

    struct ParticleUniforms {
        float2 direction;
        float2 cursor;
        float4 color;
        float phase;
        float aspect;
        float size;
        float sway;
        float opacity;
        float pixelHeight;
        int count;
        int cycles;
        int preset;
        int hasCursor;
        int cursorMode;
        int hasMask;
        int seed;
        int travels;
    };

    struct ParticleOut {
        float4 position [[position]];
        float2 local;
        float alpha;
        float tint;
    };

    float hash1(uint n) {
        n = (n << 13u) ^ n;
        n = n * (n * n * 15731u + 789221u) + 1376312589u;
        return float(n & 0x7fffffffu) / float(0x7fffffff);
    }

    // Everything below is a function of (particle index, phase); every term with
    // the phase repeats a whole number of times per loop.
    vertex ParticleOut particle_vertex(uint vid [[vertex_id]],
                                      uint iid [[instance_id]],
                                      constant ParticleUniforms &u [[buffer(0)]],
                                      texture2d<float> mask [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        uint base = iid * 9u + uint(u.seed) * 7919u;
        float h0 = hash1(base), h1 = hash1(base + 1u), h2 = hash1(base + 2u), h3 = hash1(base + 3u);
        float h4 = hash1(base + 4u), h5 = hash1(base + 5u), h6 = hash1(base + 6u);
        float margin = 0.08 + u.size * 0.06;
        float2 box = float2(u.aspect + 2.0 * margin, 1.0 + 2.0 * margin);
        float2 dir = u.direction;
        float2 perp = float2(-dir.y, dir.x);

        // Position in a space where the canvas is aspect × 1.
        float2 q = float2(h0 * u.aspect, h1);
        float life = 1.0;
        if (u.travels != 0) {
            // Depth-like variation: some particles a bit slower, a whole number of
            // crossings per loop either way.
            int crossings = max(1, u.cycles + int(h6 * 2.0) - (u.cycles > 1 ? 1 : 0));
            float t = fract(h2 + float(crossings) * u.phase);
            q += dir * (t * 1.25);
            life = smoothstep(0.0, 0.08, t) * (1.0 - smoothstep(0.92, 1.0, t));
        }
        float swayCycles = 1.0 + floor(h3 * 3.0);
        q += perp * (u.sway * 0.05) * sin(6.28318530718 * (swayCycles * u.phase + h4));
        // Wrap off-canvas, so a particle leaving one edge enters at the other.
        q = fmod(fmod(q + margin, box) + box, box) - margin;

        float2 uv = float2(q.x / u.aspect, q.y);
        if (u.hasCursor != 0) {
            float2 cq = float2(u.cursor.x * u.aspect, u.cursor.y);
            float2 d = q - cq;
            float dist = length(d);
            float push = 0.12 * pow(max(0.0, 1.0 - dist / 0.25), 2.0);
            float2 away = dist > 1e-4 ? d / dist : float2(0.0);
            q += (u.cursorMode == 1 ? -away : away) * push;
            uv = float2(q.x / u.aspect, q.y);
        }

        float sizeScale = 0.6 + h5 * 0.8;
        float radius = (0.004 + u.size * 0.03) * sizeScale;
        float2 corner = float2((vid & 1u) ? 1.0 : -1.0, (vid & 2u) ? 1.0 : -1.0);
        float2 offset;
        if (u.preset == 1) { // rain: a streak along the fall
            offset = dir * corner.y * radius * 4.0 + perp * corner.x * radius * 0.25;
        } else if (u.preset == 2) { // petals tumble
            float angle = 6.28318530718 * (h3 + swayCycles * u.phase);
            float c = cos(angle), sn = sin(angle);
            float2 r = corner * radius * float2(1.0, 0.6);
            offset = float2(r.x * c - r.y * sn, r.x * sn + r.y * c);
        } else {
            offset = corner * radius * (u.preset == 3 || u.preset == 5 ? 2.5 : 1.0);
        }
        // Keep at least a pixel wide so small particles do not shimmer away.
        float minRadius = 1.0 / max(u.pixelHeight, 1.0);
        offset = sign(offset) * max(abs(offset), float2(minRadius));
        float2 vertexQ = q + offset;
        float2 vertexUV = float2(vertexQ.x / u.aspect, vertexQ.y);

        float twinkle = 1.0;
        if (u.preset == 3 || u.preset == 5 || u.preset == 7) {
            float blinkCycles = 1.0 + floor(h6 * 4.0);
            twinkle = 0.35 + 0.65 * (0.5 + 0.5 * sin(6.28318530718 * (blinkCycles * u.phase + h0)));
        }
        float inside = u.hasMask != 0 ? mask.sample(s, uv, level(0)).r : 1.0;

        ParticleOut out;
        out.position = float4(vertexUV.x * 2.0 - 1.0, 1.0 - vertexUV.y * 2.0, 0.0, 1.0);
        out.local = corner;
        out.alpha = life * twinkle * inside * u.opacity * u.color.a * (0.6 + 0.4 * h4);
        out.tint = h1;
        return out;
    }

    fragment float4 particle_fragment(ParticleOut in [[stage_in]],
                                      constant ParticleUniforms &u [[buffer(0)]]) {
        float2 p = in.local;
        float r = length(p);
        float shape;
        switch (u.preset) {
        case 0: shape = 1.0 - smoothstep(0.55, 1.0, r); break;                       // snow
        case 1: shape = (1.0 - smoothstep(0.6, 1.0, abs(p.x))) * (1.0 - smoothstep(0.3, 1.0, abs(p.y))); break; // rain
        case 2: shape = 1.0 - smoothstep(0.8, 1.0, length(float2(p.x, p.y * 1.0 + 0.25 * p.x * p.x))); break;   // petal
        case 3: shape = exp(-r * r * 9.0) + 0.6 * (1.0 - smoothstep(0.08, 0.2, r)); break;  // firefly glow
        case 4: shape = exp(-r * r * 6.0); break;                                     // dust
        case 5: shape = exp(-r * r * 10.0) + 0.5 * (1.0 - smoothstep(0.1, 0.25, r)); break; // ember
        case 6: shape = smoothstep(0.65, 0.85, r) * (1.0 - smoothstep(0.85, 1.0, r)) + 0.15 * (1.0 - smoothstep(0.0, 0.9, r)); break; // bubble
        default: {                                                                    // star
            float cross = max(1.0 - smoothstep(0.0, 0.12, abs(p.x)) , 1.0 - smoothstep(0.0, 0.12, abs(p.y))) * (1.0 - r);
            shape = max(exp(-r * r * 16.0), cross);
        }
        }
        float3 color = u.color.rgb;
        if (u.preset == 5) { // embers vary from orange to yellow
            color = mix(color, float3(1.0, 0.85, 0.4), in.tint * 0.6);
        }
        float alpha = clamp(shape, 0.0, 1.0) * in.alpha;
        return float4(color * alpha, alpha);
    }

    // MARK: simulated particles

    struct ParticleSystemInstance {
        float2 center;
        float2 right;
        float2 up;
        float2 uvOrigin;
        float2 uvSize;
        float4 color;
        float depth;
    };

    struct ParticleSystemUniforms {
        float2 column0;
        float2 column1;
        float2 origin;
        float2 viewOrigin;
        float2 viewSize;
        float2 canvasSize;
        float brightness;
        float refractAmount;
        int blend;
        int refracts;
        int hasNormal;
        int cuts;
        float cutoutStart;
        float cutoutEnd;
        float cutoutOpacity;
        float padding;
    };

    struct ParticleSystemOut {
        float4 position [[position]];
        float2 uv;
        float4 color;
        float2 canvasUV;
        // The sprite's right and up on the canvas (x right, y up), normalized:
        // (right.x, up.x, right.y, up.y) times the refraction amount.
        float4 tangents;
    };

    vertex ParticleSystemOut particle_system_vertex(uint vid [[vertex_id]],
                                                    uint iid [[instance_id]],
                                                    const device ParticleSystemInstance *instances [[buffer(0)]],
                                                    constant ParticleSystemUniforms &u [[buffer(1)]]) {
        ParticleSystemInstance p = instances[iid];
        // The sprite's texture coordinates, v down from its top edge.
        float2 corner = float2((vid & 1u) ? 1.0 : 0.0, (vid & 2u) ? 1.0 : 0.0);
        float2 local = p.center + p.right * (corner.x - 0.5) - p.up * (corner.y - 0.5);
        float2 uv = u.origin + u.column0 * local.x + u.column1 * local.y;
        ParticleSystemOut out;
        out.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
        out.uv = p.uvOrigin + corner * p.uvSize;
        out.color = p.color;
        out.canvasUV = uv;
        float2 pixels = float2(u.canvasSize.x, -u.canvasSize.y);
        float2 right = (u.column0 * p.right.x + u.column1 * p.right.y) * pixels;
        float2 up = (u.column0 * p.up.x + u.column1 * p.up.y) * pixels;
        right = length(right) > 0.0 ? normalize(right) : float2(1.0, 0.0);
        up = length(up) > 0.0 ? normalize(up) : float2(0.0, 1.0);
        out.tangents = float4(right.x, up.x, right.y, up.y) * u.refractAmount;
        return out;
    }

    fragment float4 particle_system_fragment(ParticleSystemOut in [[stage_in]],
                                             constant ParticleSystemUniforms &u [[buffer(1)]],
                                             texture2d<float> sprite [[texture(0)]],
                                             texture2d<float> background [[texture(1)]],
                                             texture2d<float> normals [[texture(2)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float4 color = in.color * sprite.sample(s, in.uv);
        if (u.refracts != 0) {
            float2 offset = float2(0.0);
            if (u.hasNormal != 0) {
                float3 n = normals.sample(s, in.uv).rgb;
                float2 normal = n.xy * 2.0 - 1.0;
                offset = (in.tangents.xy * normal.x + in.tangents.zw * normal.y) * n.z * in.color.a;
            }
            // The offset has y up; canvas UV runs down.
            float2 canvasUV = in.canvasUV + float2(offset.x, -offset.y);
            color.rgb *= background.sample(s, (canvasUV - u.viewOrigin) / u.viewSize).rgb;
        }
        float3 rgb = color.rgb * u.brightness;
        if (u.cuts != 0) {
            color.a = smoothstep(u.cutoutStart, u.cutoutEnd, color.a) * u.cutoutOpacity;
        }
        // Opaque particles cover what is below whatever their alpha.
        if (u.blend == 0) { return float4(rgb, 1.0); }
        float alpha = saturate(color.a);
        return float4(rgb * alpha, alpha);
    }
    """
}

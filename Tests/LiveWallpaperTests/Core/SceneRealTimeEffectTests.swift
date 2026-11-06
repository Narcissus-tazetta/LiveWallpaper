import AppKit
@testable import LiveWallpaper
import Metal
import XCTest

/// The real-time effects against their formulas, computed here on the CPU.
@MainActor
final class SceneRealTimeEffectTests: XCTestCase {
    private var directory: URL!
    private var video: URL!
    private let size = 64

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneRealTimeEffectTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        video = directory.appendingPathComponent("scene.mp4")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func writeImage(
        prefix: String,
        _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)
    ) throws -> String {
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0 ..< size {
            for x in 0 ..< size {
                let (r, g, b) = pixel(x, y)
                pixels[(y * size + x) * 4] = r
                pixels[(y * size + x) * 4 + 1] = g
                pixels[(y * size + x) * 4 + 2] = b
            }
        }
        let image = CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )!
        return try SceneStore.writeImage(image, prefix: prefix, videoPath: video.path)
    }

    /// Red rises with x and green with y, 4 per pixel, so a moved pixel shows where
    /// it was read from.
    private func writeGradient() throws -> String {
        try writeImage(prefix: "layer") { x, y in (UInt8(x * 4), UInt8(y * 4), 0) }
    }

    /// BGRA.
    private func frame(
        _ effect: SceneEffect?, file: String, time: Double, realTime: Bool,
        shake: SceneCameraShake? = nil
    ) throws -> [UInt8] {
        var layer = SceneLayer(name: "picture", imageFile: file)
        layer.effects = effect.map { [$0] } ?? []
        var scene = SceneDocument(canvasWidth: size, canvasHeight: size, layers: [layer])
        scene.loopSeconds = 60
        scene.cameraShake = shake
        let renderer = try SceneRenderer(document: scene, videoPath: video.path)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let command = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
        var input = SceneFrameInput(time: time)
        input.isRealTime = realTime
        try renderer.encode(into: texture, commandBuffer: command, input: input)
        command.commit()
        command.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        texture.getBytes(
            &pixels,
            bytesPerRow: size * 4,
            from: MTLRegionMake2D(0, 0, size, size),
            mipmapLevel: 0
        )
        return pixels
    }

    /// The gradient read at `uv` with linear filtering and clamped edges.
    private func gradient(at uv: SIMD2<Double>) -> (red: Double, green: Double) {
        func channel(_ value: Double) -> Double {
            min(max(value * Double(size) - 0.5, 0), Double(size - 1)) * 4
        }
        return (channel(uv.x), channel(uv.y))
    }

    /// Largest difference from the expected red/green over the inner pixels (the
    /// outer ring also depends on how far the clamp reaches).
    private func worstError(
        _ pixels: [UInt8],
        expected: (SIMD2<Double>) -> SIMD2<Double>
    ) -> Double {
        var worst = 0.0
        for y in 2 ..< size - 2 {
            for x in 2 ..< size - 2 {
                let uv = SIMD2((Double(x) + 0.5) / Double(size), (Double(y) + 0.5) / Double(size))
                let colour = gradient(at: expected(uv))
                let index = (y * size + x) * 4
                worst = max(
                    worst,
                    abs(Double(pixels[index + 2]) - colour.red),
                    abs(Double(pixels[index + 1]) - colour.green)
                )
            }
        }
        return worst
    }

    func testOpacityMaskMultipliesPremultipliedColorAndDefaultsToWhite() throws {
        let file = try writeImage(prefix: "layer") { _, _ in (200, 100, 50) }
        var effect = SceneEffect(kind: .opacityMask)
        effect.values = ["alpha": 0.5]
        let unmasked = try frame(effect, file: file, time: 0, realTime: true)
        effect.maskFile = try writeImage(prefix: "mask") { x, _ in (x < 32 ? 0 : 128, 255, 255) }
        let masked = try frame(effect, file: file, time: 0, realTime: true)
        for (x, expected) in [(16, [0, 0, 0]), (48, [13, 25, 50])] {
            let offset = (32 * size + x) * 4
            for channel in 0 ..< 3 {
                XCTAssertEqual(
                    Double(masked[offset + channel]),
                    Double(expected[channel]),
                    accuracy: 1
                )
            }
        }
        let offset = (32 * size + 48) * 4
        XCTAssertEqual(Double(unmasked[offset + 2]), 100, accuracy: 1)
        XCTAssertFalse(effect.kind.usesCycles)
        XCTAssertFalse(effect.kind.canMoveOnItsOwnLayer)
    }

    func testEditorEffectsSelectRealTimePlaybackWithoutAnImportedFlag() throws {
        for kind in SceneEffectKind.allCases.filter(\.runsOnRealTime) {
            var layer = SceneLayer(name: "picture", imageFile: "layer.png")
            layer.effects = [SceneEffect(kind: kind)]
            let scene = SceneDocument(canvasWidth: size, canvasHeight: size, layers: [layer])
            XCTAssertTrue(
                scene.requiresRealTimePlayback,
                "\(kind) must retain its speed after baking"
            )
            let restored = try JSONDecoder().decode(
                SceneDocument.self,
                from: JSONEncoder().encode(scene)
            )
            XCTAssertTrue(restored.requiresRealTimePlayback)
        }
    }

    func testRealTimePlaybackFollowsEnabledVisibleEffectsAndExplicitRequest() {
        var layer = SceneLayer(name: "picture", imageFile: "layer.png")
        layer.effects = [SceneEffect(kind: .travelingWaves)]
        var scene = SceneDocument(canvasWidth: size, canvasHeight: size, layers: [layer])
        XCTAssertTrue(scene.requiresRealTimePlayback)
        scene.layers[0].effects[0].isEnabled = false
        XCTAssertFalse(scene.requiresRealTimePlayback)
        scene.layers[0].effects[0].isEnabled = true
        scene.layers[0].isVisible = false
        XCTAssertFalse(scene.requiresRealTimePlayback)
        scene.layers = []
        XCTAssertFalse(scene.requiresRealTimePlayback)
        scene.runsInRealTime = true
        XCTAssertTrue(scene.requiresRealTimePlayback)
    }

    func testFlowAndScrollRespectThePaintedArea() throws {
        let file = try writeGradient()
        let mask = try writeImage(prefix: "mask") { x, _ in
            let value: UInt8 = x < self.size / 2 ? 0 : 255
            return (value, value, value)
        }
        var still = SceneEffect(kind: .uvScroll)
        still.values = ["speedX": 0, "speedY": 0]
        let original = try frame(still, file: file, time: 1.3, realTime: true)
        for kind in [SceneEffectKind.flowMap, .uvScroll] {
            var effect = SceneEffect(kind: kind)
            effect.flowFile = try solid("flow", 255, 128, 0)
            effect.patternFile = try solid("pattern", 0, 0, 0)
            let unmasked = try frame(effect, file: file, time: 1.3, realTime: true)
            XCTAssertNotEqual(unmasked, original)
            effect.maskFile = mask
            let masked = try frame(effect, file: file, time: 1.3, realTime: true)
            var mismatchedPixels = 0
            for y in 2 ..< size - 2 {
                for x in 2 ..< size - 2 where abs(x - size / 2) > 1 {
                    let offset = (y * size + x) * 4
                    let expected = x < size / 2 ? original : unmasked
                    if masked[offset ..< offset + 4] != expected[offset ..< offset + 4] {
                        mismatchedPixels += 1
                    }
                }
            }
            XCTAssertEqual(mismatchedPixels, 0, "\(kind) must preserve unpainted pixels")
        }
    }

    func testTravelingWavesMoveEachPixelAsTheFormulaSays() throws {
        let file = try writeGradient()
        var effect = SceneEffect(kind: .travelingWaves)
        typealias Key = SceneEffect.WaveKey
        effect.values = [
            Key.speed: 2,
            Key.scale: 8,
            Key.amplitude: 0.3,
            Key.exponent: 1,
            Key.angle: 1.1
        ]
        let time = 0.7
        let pixels = try frame(effect, file: file, time: time, realTime: true)

        let error = worstError(pixels) { uv in
            let direction = SIMD2(-sin(1.1), cos(1.1))
            let wave = sin(time * 2 + (uv * direction).sum() * 8)
            return uv + wave * SIMD2(direction.y, -direction.x) * 0.3 * 0.3
        }
        XCTAssertLessThan(error, 6)
    }

    func testFlowShakeMovesAlongTheFlowAsTheFormulaSays() throws {
        let file = try writeGradient()
        // Every pixel flows right: red 191 is (191/255 − 0.498) × 2 ≈ 0.502.
        let flow = try writeImage(prefix: "flow") { _, _ in (191, 128, 0) }
        var effect = SceneEffect(kind: .flowShake)
        typealias Key = SceneEffect.FlowShakeKey
        effect.values = [Key.speed: 2, Key.amplitude: 0.4]
        effect.flowFile = flow
        let time = 0.5
        let pixels = try frame(effect, file: file, time: time, realTime: true)

        let error = worstError(pixels) { uv in
            let angle = 2 * time
            var offset = sin(angle) * 0.498 + 0.5
            offset = offset * 2 - 1
            let vector = SIMD2((191.0 / 255 - 0.498) * 2, (128.0 / 255 - 0.498) * 2)
            return uv + offset * 0.4 * 0.4 * vector
        }
        XCTAssertLessThan(error, 6)
    }

    /// Largest colour difference from `expected` (0...255 red, green, blue) over the
    /// inner pixels; nil from `expected` skips a pixel.
    private func worstColourError(
        _ pixels: [UInt8],
        expected: (Int, Int) -> SIMD3<Double>?
    ) -> Double {
        var worst = 0.0
        for y in 2 ..< size - 2 {
            for x in 2 ..< size - 2 {
                guard let colour = expected(x, y) else { continue }
                let index = (y * size + x) * 4
                worst = max(
                    worst,
                    abs(Double(pixels[index + 2]) - colour.x),
                    abs(Double(pixels[index + 1]) - colour.y),
                    abs(Double(pixels[index]) - colour.z)
                )
            }
        }
        return worst
    }

    private func solid(_ prefix: String, _ r: UInt8, _ g: UInt8, _ b: UInt8) throws -> String {
        try writeImage(prefix: prefix) { _, _ in (r, g, b) }
    }

    private func uv(_ x: Int, _ y: Int) -> SIMD2<Double> {
        SIMD2((Double(x) + 0.5) / Double(size), (Double(y) + 0.5) / Double(size))
    }

    func testFlowMapStreamsAlongTheFlowAsTheFormulaSays() throws {
        let file = try writeGradient()
        var effect = SceneEffect(kind: .flowMap)
        typealias Key = SceneEffect.FlowMapKey
        effect.values = [Key.speed: 0.3, Key.strength: 1, Key.feather: 0.4, Key.phaseScale: 2]
        effect.flowFile = try solid("flow", 191, 128, 0)
        effect.patternFile = try solid("pattern", 0, 0, 0)
        let time = 1.3
        let pixels = try frame(effect, file: file, time: time, realTime: true)

        let vector = SIMD2((191.0 / 255 - 0.498) * 2, (128.0 / 255 - 0.498) * 2)
        let travel = vector * 0.1
        let t = time * 0.3
        let cx = (t - floor(t)) - 0.5, cy = ((t + 0.5) - floor(t + 0.5)) - 0.5
        func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
            let k = min(max((x - e0) / (e1 - e0), 0), 1)
            return k * k * (3 - 2 * k)
        }
        let blend = smooth(0.1, 0.9, 2 * abs(cx))
        let amount = (vector * vector).sum().squareRoot()
        // With the phase image black only the first pair shows; on a linear gradient
        // every mix is a mix of positions.
        let error = worstError(pixels) { uv in
            let pair = (uv + travel * cx) * (1 - blend) + (uv + travel * cy) * blend
            return uv * (1 - amount) + pair * amount
        }
        XCTAssertLessThan(error, 6)
    }

    func testNormalRipplesBendByTheNormalAsTheFormulaSays() throws {
        let file = try writeGradient()
        var effect = SceneEffect(kind: .normalRipples)
        typealias Key = SceneEffect.RipplesKey
        effect.values = [Key.strength: 0.25, Key.animationSpeed: 0.3, Key.scale: 1]
        effect.patternFile = try solid("normal", 220, 90, 255)
        let pixels = try frame(effect, file: file, time: 2, realTime: true)

        let n = SIMD3(220.0 / 255, 90.0 / 255, 1) * 2 - 1
        let raw = SIMD3(n.x * 2, n.y * 2, n.z)
        let normal = raw / (raw * raw).sum().squareRoot()
        let error = worstError(pixels) { uv in uv + SIMD2(normal.x, normal.y) * 0.25 * 0.25 }
        XCTAssertLessThan(error, 6)
    }

    func testNoiseDriftPushesAcrossTheAngleAsTheFormulaSays() throws {
        let file = try writeGradient()
        var effect = SceneEffect(kind: .noiseDrift)
        typealias Key = SceneEffect.NoiseDriftKey
        effect.values = [Key.amount: 0.08, Key.angle: 0.7, Key.speed: 0.02]
        effect.patternFile = try solid("noise", 204, 0, 0)
        let pixels = try frame(effect, file: file, time: 3, realTime: true)

        let push = (204.0 / 255 * 2 - 1) * 0.08
        let angle = 0.7 + Double.pi / 2
        let offset = SIMD2(push * cos(angle), push * sin(angle))
        let error = worstError(pixels) { uv in uv + offset }
        XCTAssertLessThan(error, 6)
    }

    func testNoiseSwayMovesEachPixelAsTheFormulaSays() throws {
        let file = try writeGradient()
        var effect = SceneEffect(kind: .noiseSway)
        typealias Key = SceneEffect.NoiseSwayKey
        effect.values = [
            Key.speed: 2,
            Key.strength: 1.5,
            Key.phase: 0.5,
            Key.power: 1,
            Key.ratio: 0.3,
            Key.angle: 0.4
        ]
        effect.patternFile = try solid("noise", 0, 153, 0)
        let time = 0.9
        let pixels = try frame(effect, file: file, time: time, realTime: true)

        func rotate(_ v: SIMD2<Double>, _ a: Double) -> SIMD2<Double> {
            SIMD2(v.x * cos(a) - v.y * sin(a), v.x * sin(a) + v.y * cos(a))
        }
        let stretch = 1.0 * 0.3
        let axes = rotate(SIMD2(1 / stretch, stretch), 0.4)
        let amplitude = 1.5 * 1.5 * 0.005
        let sineSpeeds = [1, -0.16161616, 0.0083333, -0.00019841].map { $0 * 2 }
        let cosineSpeeds = [-0.5, 0.041666666, -0.0013888889, 0.000024801587].map { $0 * 2 }
        let error = worstError(pixels) { uv in
            let turned = rotate(uv, 0.4)
            let phase = (153.0 / 255 * Double.pi * 2 + turned.x * 10 + turned.y * 5) * 0.5
            let x = sineSpeeds.map { sin(phase + time * $0) }.reduce(0, +) * amplitude
            let y = cosineSpeeds.map { sin(0.4 + phase + time * $0) }.reduce(0, +) * amplitude
            return uv + SIMD2(axes.x * x, axes.y * y)
        }
        XCTAssertLessThan(error, 6)
    }

    /// Every effect whose motion a bake bends onto the loop, each at a rate that is not a
    /// whole number of repeats a minute (and, for the sways, slower than half a turn).
    private func loopingEffects() throws -> [SceneEffect] {
        var waves = SceneEffect(kind: .travelingWaves)
        waves.values = [
            SceneEffect.WaveKey.speed: 2.07, SceneEffect.WaveKey.scale: 8,
            SceneEffect.WaveKey.amplitude: 0.3,
            SceneEffect.WaveKey.angle: 0.4, SceneEffect.WaveKey.dual: 1,
            SceneEffect.WaveKey.speed2: 0.03,
            SceneEffect.WaveKey.scale2: 5, SceneEffect.WaveKey.offset2: 3
        ]
        var sway = SceneEffect(kind: .noiseSway)
        sway.values = [
            SceneEffect.NoiseSwayKey.speed: 0.85, SceneEffect.NoiseSwayKey.strength: 3,
            SceneEffect.NoiseSwayKey.phase: 0.5,
            SceneEffect.NoiseSwayKey.power: 1, SceneEffect.NoiseSwayKey.ratio: 1
        ]
        sway.patternFile = try solid("noise", 0, 153, 0)
        var shake = SceneEffect(kind: .flowShake)
        // The irregular swing sums four sines in 0...2; the default bounds clip most of it.
        shake.values = [
            SceneEffect.FlowShakeKey.speed: 0.85, SceneEffect.FlowShakeKey.amplitude: 0.5,
            SceneEffect.FlowShakeKey.irregular: 1,
            SceneEffect.FlowShakeKey.boundsMax: 2
        ]
        shake.flowFile = try solid("flow", 191, 128, 0)
        var steadyShake = shake
        steadyShake.values[SceneEffect.FlowShakeKey.irregular] = 0
        var flow = SceneEffect(kind: .flowMap)
        flow.values = [
            SceneEffect.FlowMapKey.speed: 0.007,
            SceneEffect.FlowMapKey.strength: 4,
            SceneEffect.FlowMapKey.feather: 0.4
        ]
        flow.flowFile = try solid("flow", 191, 128, 0)
        flow.patternFile = try writeImage(prefix: "phase") { x, _ in (UInt8(x * 4), 0, 0) }
        var drift = SceneEffect(kind: .noiseDrift)
        drift.values = [
            SceneEffect.NoiseDriftKey.amount: 0.08,
            SceneEffect.NoiseDriftKey.angle: 0.7,
            SceneEffect.NoiseDriftKey.speed: 0.013
        ]
        drift.patternFile = try writeImage(prefix: "drift") { x, y in (
            UInt8((x * 7 + y * 3) % 64 * 4),
            0,
            0
        ) }
        var pulse = SceneEffect(kind: .pulseBlend)
        pulse.values = [
            SceneEffect.PulseKey.speed: 0.05, SceneEffect.PulseKey.amount: 0.8,
            SceneEffect.PulseKey.blendMode: 9,
            SceneEffect.PulseKey.highRed: 0.5, SceneEffect.PulseKey.highGreen: 0.2,
            SceneEffect.PulseKey.highBlue: 1
        ]
        var scroll = SceneEffect(kind: .uvScroll)
        scroll.values = [SceneEffect.ScrollKey.speedX: -0.11, SceneEffect.ScrollKey.speedY: 0.07]
        var swing = SceneEffect(kind: .axisSwing)
        swing.values = [
            SceneEffect.AxisSwingKey.speed: 0.07, SceneEffect.AxisSwingKey.amount: 0.6,
            SceneEffect.AxisSwingKey.x0: 0.2,
            SceneEffect.AxisSwingKey.y0: 0.3, SceneEffect.AxisSwingKey.x1: 0.8,
            SceneEffect.AxisSwingKey.y1: 0.4,
            SceneEffect.AxisSwingKey.size: 0.5, SceneEffect.AxisSwingKey.feather: 0.05
        ]
        let bumps = try writeImage(prefix: "bumps") { x, y in (
            UInt8(128 + (x * 5 + y * 2) % 60),
            UInt8(128 + (x * 3 + y * 7) % 60),
            255
        ) }
        var ripples = SceneEffect(kind: .normalRipples)
        ripples.values = [
            SceneEffect.RipplesKey.strength: 0.5, SceneEffect.RipplesKey.animationSpeed: 0.17,
            SceneEffect.RipplesKey.scale: 1.3,
            SceneEffect.RipplesKey.scrollSpeed: 0.13, SceneEffect.RipplesKey.scrollAngle: 0.6
        ]
        ripples.patternFile = bumps
        var noisyPulse = pulse
        noisyPulse.values[SceneEffect.PulseKey.speed] = 0
        noisyPulse.values[SceneEffect.PulseKey.noiseSpeed] = 0.37
        noisyPulse.values[SceneEffect.PulseKey.noiseAmount] = 1
        noisyPulse.patternFile = bumps
        var noisySwing = swing
        noisySwing.values[SceneEffect.AxisSwingKey.noise] = 1
        noisySwing.values[SceneEffect.AxisSwingKey.noiseSpeed] = 0.37
        noisySwing.values[SceneEffect.AxisSwingKey.noiseAmount] = 1
        noisySwing.patternFile = bumps
        return [
            waves,
            sway,
            shake,
            steadyShake,
            flow,
            drift,
            pulse,
            scroll,
            swing,
            ripples,
            noisyPulse,
            noisySwing
        ]
    }

    func testBakedLoopKeepsTheRealRatesThroughItsFirstHalfAndCloses() throws {
        let file = try writeGradient()
        for effect in try loopingEffects() {
            let live = try frame(effect, file: file, time: 25, realTime: true)
            let baked = try frame(effect, file: file, time: 25, realTime: false)
            XCTAssertEqual(
                baked,
                live,
                "\(effect.kind): the first half of a baked loop moves as on real time"
            )
            XCTAssertNotEqual(
                baked,
                try frame(effect, file: file, time: 0, realTime: false),
                "\(effect.kind) moves"
            )

            let start = try frame(effect, file: file, time: 0, realTime: false)
            let end = try frame(effect, file: file, time: 59.98, realTime: false)
            let jump = zip(start, end).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(jump, 3, "\(effect.kind): the baked loop closes")
            let realEnd = try frame(effect, file: file, time: 59.98, realTime: true)
            XCTAssertNotEqual(end, realEnd, "\(effect.kind): on real time the motion is not bent")
        }
    }

    /// A converted shader whose red is the fraction of 0.37 × time: a sawtooth no bend of
    /// the time can close.
    private func sawtoothShader() -> SceneEffect {
        let draw = SceneRenderGraph.Draw(
            vertex: .init(source: """
            #include <metal_stdlib>
            using namespace metal;
            struct V { float4 position [[position]]; };
            vertex V vertexMain(uint id [[vertex_id]]) {
                float2 p[] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
                return {float4(p[id],0,1)};
            }
            """, entryPoint: "vertexMain"),
            fragment: .init(source: """
            #include <metal_stdlib>
            using namespace metal;
            fragment float4 fragmentMain(constant float& time [[buffer(0)]]) { return float4(fract(time * 0.37), 0, 0, 1); }
            """, entryPoint: "fragmentMain", uniforms: Data(repeating: 0, count: 16), updates: [
                .init(
                    offset: 0,
                    value: .time
                )
            ]),
            vertices: Data(repeating: 0, count: 12), vertexStride: 4, vertexCount: 3,
            attributes: [], textures: [.init(index: 0, source: "input")]
        )
        var effect = SceneEffect(kind: .shader)
        effect.renderGraph = SceneRenderGraph(
            targets: [.init(name: "work")], passes: [.init(
                operation: .draw,
                target: "work",
                draw: draw
            )], output: "work"
        )
        return effect
    }

    func testABakedLoopFadesAConvertedShaderIntoItsStart() throws {
        let file = try writeGradient()
        let shader = sawtoothShader()
        func red(_ time: Double, live: Bool) throws -> Int {
            try Int(frame(
                shader,
                file: file,
                time: time,
                realTime: live
            )[2])
        }
        XCTAssertEqual(
            try red(25, live: false),
            try red(25, live: true),
            "past the fade the shader runs on its own time"
        )
        // fract(0.37 × 60) = 0.2 is where the loop's end left it; drawn as it is, the start is 0.
        XCTAssertEqual(try red(0, live: false), try red(60, live: true))
        XCTAssertLessThanOrEqual(
            try abs(red(0, live: false) - red(59.98, live: false)),
            2,
            "the baked loop closes"
        )
        XCTAssertEqual(try red(0, live: true), 0)
    }

    func testABakedLoopKeepsTheCameraShakeAndCloses() throws {
        let file = try writeGradient()
        let shake = SceneCameraShake(speed: 0.3, amplitude: 4, roughness: 1)
        let live = try frame(nil, file: file, time: 25, realTime: true, shake: shake)
        XCTAssertEqual(try frame(nil, file: file, time: 25, realTime: false, shake: shake), live)
        let start = try frame(nil, file: file, time: 0, realTime: false, shake: shake)
        let end = try frame(nil, file: file, time: 59.98, realTime: false, shake: shake)
        XCTAssertLessThanOrEqual(
            zip(start, end).map { abs(Int($0) - Int($1)) }.max() ?? 0,
            3,
            "the baked loop closes"
        )
        XCTAssertNotEqual(
            end,
            try frame(nil, file: file, time: 59.98, realTime: true, shake: shake)
        )
    }

    func testAClampedPatternDriftsOffWithoutWrappingRound() throws {
        let file = try writeGradient()
        var drift = SceneEffect(kind: .noiseDrift)
        drift.values = [
            SceneEffect.NoiseDriftKey.amount: 0.08,
            SceneEffect.NoiseDriftKey.speed: 0.05
        ]
        drift.patternFile = try writeImage(prefix: "drift") { x, _ in (UInt8(x * 4), 0, 0) }
        // 5 s and 25 s are a whole repeat apart: the same on a repeating pattern, past
        // the edge on a clamped one.
        XCTAssertEqual(
            try frame(drift, file: file, time: 5, realTime: true),
            try frame(drift, file: file, time: 25, realTime: true)
        )
        drift.values[SceneEffect.patternClampsKey] = 1
        XCTAssertNotEqual(
            try frame(drift, file: file, time: 5, realTime: true),
            try frame(drift, file: file, time: 25, realTime: true)
        )
    }

    func testPulseBlendTintsAsTheFormulaSays() throws {
        let file = try writeGradient()
        var effect = SceneEffect(kind: .pulseBlend)
        typealias Key = SceneEffect.PulseKey
        effect.values = [
            Key.speed: 3, Key.phase: 0.5, Key.amount: 0.8, Key.blendMode: 9,
            Key.highRed: 0.5, Key.highGreen: 0.2, Key.highBlue: 1
        ]
        let time = 0.4
        let pixels = try frame(effect, file: file, time: time, realTime: true)

        let wave = sin(time * 3 + (0.5 - Double.pi / 2)) * 0.5 + 0.5
        let pulse = wave * wave * (3 - 2 * wave) * 0.8
        let error = worstColourError(pixels) { x, y in
            let colour = SIMD3(Double(x * 4), Double(y * 4), 0) / 255
            let added = SIMD3(min(colour.x * 1.5, 1), min(colour.y * 1.2, 1), min(colour.z * 2, 1))
            return (colour + (added - colour) * pulse) * 255
        }
        XCTAssertLessThan(error, 4)
    }

    func testUVScrollWrapsAtTheSpeedSquared() throws {
        let file = try writeGradient()
        var effect = SceneEffect(kind: .uvScroll)
        typealias Key = SceneEffect.ScrollKey
        effect.values = [Key.speedX: -0.3, Key.speedY: 0.2]
        let time = 1.7
        let pixels = try frame(effect, file: file, time: time, realTime: true)

        let shift = SIMD2(-0.09 * time, 0.04 * time)
        var skipped = 0
        let error = worstColourError(pixels) { x, y in
            var moved = self.uv(x, y) + shift
            moved -= SIMD2(floor(moved.x), floor(moved.y))
            // Next to the wrap the filter mixes both ends.
            let edge = 1.5 / Double(self.size)
            guard moved.x > edge, moved.x < 1 - edge, moved.y > edge, moved.y < 1 - edge else {
                skipped += 1
                return nil
            }
            let colour = self.gradient(at: moved)
            return SIMD3(colour.red, colour.green, 0)
        }
        XCTAssertLessThan(skipped, size * 8)
        XCTAssertLessThan(error, 6)
    }

    func testAxisSwingBendsBesideTheAxisAsTheFormulaSays() throws {
        let file = try writeGradient()
        var effect = SceneEffect(kind: .axisSwing)
        typealias Key = SceneEffect.AxisSwingKey
        effect.values = [
            Key.speed: 2, Key.amount: 0.6, Key.x0: 0.2, Key.y0: 0.3, Key.x1: 0.8, Key.y1: 0.4,
            Key.size: 0.5,
            Key.feather: 0.05
        ]
        let time = 0.6
        let pixels = try frame(effect, file: file, time: time, realTime: true)

        func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
            let k = min(max((x - e0) / (e1 - e0), 0), 1)
            return k * k * (3 - 2 * k)
        }
        let swing = sin(time * 2) * 0.6
        let p0 = SIMD2(0.2, 0.3), p1 = SIMD2(0.8, 0.4)
        let axisLength = ((p1 - p0) * (p1 - p0)).sum().squareRoot()
        let axis = (p1 - p0) / axisLength
        let across = SIMD2(-axis.y, axis.x)
        let centre = p0 + (p1 - p0) * 0.5
        let error = worstError(pixels) { uv in
            let delta = uv - centre
            let along = (axis * delta).sum(), side = (across * delta).sum()
            let bent = uv + axis * swing * side * along + across * swing * swing * side
            var weight = smooth(0.05, 0, ((bent - p1) * axis).sum()) * smooth(
                -0.05,
                0,
                ((bent - p0) * axis).sum()
            )
            let reach = 0.5 * (1 - abs(swing) * 0.6 * 0.5)
            weight *= smooth(reach + 0.05, reach - 0.05, side) * (side >= 0 ? 1 : 0)
            return uv + (bent - uv) * weight
        }
        XCTAssertLessThan(error, 6)
    }
}

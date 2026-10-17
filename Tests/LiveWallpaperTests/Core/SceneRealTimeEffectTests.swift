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

    private func writeImage(prefix: String, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> String {
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
    private func frame(_ effect: SceneEffect, file: String, time: Double, realTime: Bool) throws -> [UInt8] {
        var layer = SceneLayer(name: "picture", imageFile: file)
        layer.effects = [effect]
        var scene = SceneDocument(canvasWidth: size, canvasHeight: size, layers: [layer])
        scene.loopSeconds = 60
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
        texture.getBytes(&pixels, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
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
    private func worstError(_ pixels: [UInt8], expected: (SIMD2<Double>) -> SIMD2<Double>) -> Double {
        var worst = 0.0
        for y in 2 ..< size - 2 {
            for x in 2 ..< size - 2 {
                let uv = SIMD2((Double(x) + 0.5) / Double(size), (Double(y) + 0.5) / Double(size))
                let colour = gradient(at: expected(uv))
                let index = (y * size + x) * 4
                worst = max(worst, abs(Double(pixels[index + 2]) - colour.red), abs(Double(pixels[index + 1]) - colour.green))
            }
        }
        return worst
    }

    func testTravelingWavesMoveEachPixelAsTheFormulaSays() throws {
        let file = try writeGradient()
        var effect = SceneEffect(kind: .travelingWaves)
        typealias Key = SceneEffect.WaveKey
        effect.values = [Key.speed: 2, Key.scale: 8, Key.amplitude: 0.3, Key.exponent: 1, Key.angle: 1.1]
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

    func testBakedLoopRoundsTheSpeedSoTheLoopCloses() throws {
        let file = try writeGradient()
        var effect = SceneEffect(kind: .travelingWaves)
        typealias Key = SceneEffect.WaveKey
        // 2.07 rad/s is 19.77 turns a minute: not a whole number on real time.
        effect.values = [Key.speed: 2.07, Key.scale: 8, Key.amplitude: 0.3, Key.angle: 0.4]

        let start = try frame(effect, file: file, time: 0, realTime: false)
        let end = try frame(effect, file: file, time: 60, realTime: false)
        let realEnd = try frame(effect, file: file, time: 60, realTime: true)
        XCTAssertEqual(start, end, "the baked loop must close")
        XCTAssertNotEqual(start, realEnd, "on real time the speed is not rounded")
    }

    /// Largest colour difference from `expected` (0...255 red, green, blue) over the
    /// inner pixels; nil from `expected` skips a pixel.
    private func worstColourError(_ pixels: [UInt8], expected: (Int, Int) -> SIMD3<Double>?) -> Double {
        var worst = 0.0
        for y in 2 ..< size - 2 {
            for x in 2 ..< size - 2 {
                guard let colour = expected(x, y) else { continue }
                let index = (y * size + x) * 4
                worst = max(worst, abs(Double(pixels[index + 2]) - colour.x), abs(Double(pixels[index + 1]) - colour.y),
                            abs(Double(pixels[index]) - colour.z))
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
        effect.values = [Key.speed: 2, Key.strength: 1.5, Key.phase: 0.5, Key.power: 1, Key.ratio: 0.3, Key.angle: 0.4]
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
            Key.speed: 2, Key.amount: 0.6, Key.x0: 0.2, Key.y0: 0.3, Key.x1: 0.8, Key.y1: 0.4, Key.size: 0.5,
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
            var weight = smooth(0.05, 0, ((bent - p1) * axis).sum()) * smooth(-0.05, 0, ((bent - p0) * axis).sum())
            let reach = 0.5 * (1 - abs(swing) * 0.6 * 0.5)
            weight *= smooth(reach + 0.05, reach - 0.05, side) * (side >= 0 ? 1 : 0)
            return uv + (bent - uv) * weight
        }
        XCTAssertLessThan(error, 6)
    }
}

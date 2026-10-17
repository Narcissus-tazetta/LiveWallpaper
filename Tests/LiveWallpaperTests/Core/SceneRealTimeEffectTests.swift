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
}

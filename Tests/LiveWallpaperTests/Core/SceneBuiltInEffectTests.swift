@testable import LiveWallpaper
import Metal
import XCTest

final class SceneBuiltInEffectTests: XCTestCase {
    private let size = 32

    /// A grey (0.25) canvas with a white 4-wide bar; the pixel (x, 16) of the result in 0...255.
    private func render(_ builtIn: SceneBuiltInEffect, _ changes: [String: Double] = [:], time: Double = 0) throws -> [[Int]] {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let input = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0 ..< size {
            for x in 0 ..< size {
                let value: UInt8 = (14 ..< 18).contains(x) ? 255 : 64
                for c in 0 ..< 3 { pixels[(y * size + x) * 4 + c] = value }
                pixels[(y * size + x) * 4 + 3] = 255
            }
        }
        input.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: pixels, bytesPerRow: size * 4)
        let effect = builtIn.makeEffect()
        let renderer = try SceneRenderGraphRenderer(graph: try XCTUnwrap(effect.renderGraph), device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let values = effect.values.merging(changes) { _, new in new }
        let result = try renderer.encode(input: input, images: [:], time: time, cursor: nil, values: values, audio: nil, commandBuffer: command)
        XCTAssertEqual(result.pixelFormat, .rgba16Float)
        let buffer = try XCTUnwrap(device.makeBuffer(length: size * size * 8, options: .storageModeShared))
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: result, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: size, height: size, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: size * 8, destinationBytesPerImage: size * size * 8)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        let halves = buffer.contents().bindMemory(to: Float16.self, capacity: size * size * 4)
        return (0 ..< size).map { x in (0 ..< 4).map { Int((Float(halves[(16 * size + x) * 4 + $0]) * 255).rounded()) } }
    }

    func testEveryEffectKeepsAPictureAtItsDefaultsExceptWhereItShouldChangeIt() throws {
        for effect in SceneBuiltInEffect.allCases {
            let row = try render(effect)
            XCTAssertEqual(row.count, size, "\(effect)")
            XCTAssertTrue(row.allSatisfy { $0[3] == 255 }, "\(effect) keeps the picture opaque")
        }
    }

    func testColorAdjustBrightensDesaturatesAndKeepsNeutralSettingsAsTheyWere() throws {
        let neutral = try render(.colorAdjust, ["brightness": 0, "contrast": 1, "saturation": 1, "hue": 0])
        XCTAssertEqual(neutral[0][0], 64, accuracy: 1)
        XCTAssertEqual(neutral[15][0], 255, accuracy: 1)
        XCTAssertEqual(try render(.colorAdjust, ["brightness": 0.25])[0][0], 128, accuracy: 2)
    }

    func testBlurSpreadsTheBarAndZeroRadiusLeavesItSharp() throws {
        XCTAssertEqual(try render(.blur, ["radius": 0])[11][0], 64, accuracy: 1)
        XCTAssertGreaterThan(try render(.blur, ["radius": 8])[11][0], 80)
    }

    func testGlowAddsLightBesideTheBar() throws {
        XCTAssertEqual(try render(.glow, ["strength": 0])[20][0], 64, accuracy: 1)
        XCTAssertGreaterThan(try render(.glow, ["strength": 1, "threshold": 0.5])[20][0], 70)
    }

    func testChromaticAberrationSplitsTheBarsEdges() throws {
        let row = try render(.chromaticAberration, ["amount": 0.05, "angle": 0])
        XCTAssertNotEqual(row[13][0], row[13][2], "red and blue sit apart at the bar's edge")
    }

    func testPixelateMakesBlocksOfOneColor() throws {
        let row = try render(.pixelate, ["size": 8])
        XCTAssertEqual(row[16][0], row[17][0])
    }

    func testGlitchMovesSomethingOnceItRuns() throws {
        let plain = try render(.glitch, ["amount": 0])
        let moved = try (0 ..< 20).contains { step in
            try render(.glitch, ["amount": 1, "speed": 8], time: Double(step) * 0.2) != plain
        }
        XCTAssertTrue(moved)
    }
}

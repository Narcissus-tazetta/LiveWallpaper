@testable import LiveWallpaper
import Metal
import XCTest

final class SceneBloomTests: XCTestCase {
    private let size = 64

    /// A black canvas with a white 4 × 4 square in the middle, through the bloom's graph.
    private func render(_ bloom: SceneBloom) throws -> [UInt8] {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let input = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 30 ..< 34 { for x in 30 ..< 34 { for c in 0 ..< 4 { pixels[(y * size + x) * 4 + c] = 255 } } }
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        input.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: pixels, bytesPerRow: size * 4)
        let renderer = try SceneRenderGraphRenderer(graph: bloom.graph, device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let result = try renderer.encode(
            input: input, images: [:], time: 0, cursor: nil, values: [:], audio: nil, commandBuffer: command
        )
        let bytesPerPixel = result.pixelFormat == .rgba16Float ? 8 : 4
        let buffer = try XCTUnwrap(device.makeBuffer(length: size * size * bytesPerPixel, options: .storageModeShared))
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: result, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: size, height: size, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: size * bytesPerPixel, destinationBytesPerImage: size * size * bytesPerPixel)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(result.pixelFormat, .rgba16Float)
        let halves = buffer.contents().bindMemory(to: Float16.self, capacity: size * size * 4)
        return (0 ..< size * size * 4).map { UInt8(max(0, min(255, (Float(halves[$0]) * 255).rounded()))) }
    }

    private func red(_ pixels: [UInt8], x: Int, y: Int) -> Int { Int(pixels[(y * size + x) * 4]) }

    func testBloomSpreadsLightBesideBrightPartsAndLeavesDarkAreasAlone() throws {
        var bloom = SceneBloom()
        bloom.strength = 0
        let plain = try render(bloom)
        XCTAssertEqual(red(plain, x: 36, y: 31), 0)
        XCTAssertEqual(red(plain, x: 31, y: 31), 255)

        bloom.strength = 1
        let glowing = try render(bloom)
        XCTAssertGreaterThan(red(glowing, x: 36, y: 31), 10, "light spreads beside the square")
        XCTAssertEqual(red(glowing, x: 4, y: 4), 0, "far corners stay dark")
    }
}

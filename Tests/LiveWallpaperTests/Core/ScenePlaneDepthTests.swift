@testable import LiveWallpaper
import Metal
import simd
import XCTest

final class ScenePlaneDepthTests: XCTestCase {
    func testTransparentPixelsDoNotOccludeLaterPlanes() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try SceneModelRenderer(materials: [], device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        func texture(
            _ format: MTLPixelFormat,
            width: Int,
            usage: MTLTextureUsage
        ) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format,
                width: width,
                height: 1,
                mipmapped: false
            )
            descriptor.usage = usage
            descriptor.storageMode = format == .depth32Float ? .private : .shared
            return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        }
        let front = try texture(.rgba8Unorm, width: 3, usage: .shaderRead)
        let frontBytes: [UInt8] = [0, 0, 0, 0, 0, 255, 0, 255, 0, 0, 255, 0]
        frontBytes.withUnsafeBytes { front.replace(
            region: MTLRegionMake2D(0, 0, 3, 1),
            mipmapLevel: 0,
            withBytes: $0.baseAddress!,
            bytesPerRow: 12
        ) }
        let back = try texture(.rgba8Unorm, width: 1, usage: .shaderRead)
        let backBytes: [UInt8] = [255, 0, 0, 255]
        backBytes.withUnsafeBytes { back.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: $0.baseAddress!,
            bytesPerRow: 4
        ) }
        let target = try texture(.rgba8Unorm, width: 3, usage: .renderTarget)
        let depth = try texture(.depth32Float, width: 3, usage: .renderTarget)
        for blend in [SceneSpace.Blending.translucent, .additive, .normal] {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 1
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            let space = SceneSpace(
                world: [],
                width: 2,
                height: 2,
                offsetX: 0,
                offsetY: 0,
                depthTest: true,
                depthWrite: true,
                blending: blend
            )
            var matrix = matrix_identity_float4x4
            matrix.columns.0.x = 2; matrix.columns.1.y = 2; matrix.columns.3.z = 0.25
            try renderer.drawPlane(
                front,
                transform: matrix,
                color: .one,
                space: space,
                format: .rgba8Unorm,
                encoder: encoder
            )
            matrix.columns.3.z = 0.75
            var backSpace = space
            backSpace.blending = .normal
            try renderer.drawPlane(
                back,
                transform: matrix,
                color: .one,
                space: backSpace,
                format: .rgba8Unorm,
                encoder: encoder
            )
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            if let error = command.error { throw error }
            var bytes = [UInt8](repeating: 0, count: 12)
            target.getBytes(
                &bytes,
                bytesPerRow: 12,
                from: MTLRegionMake2D(0, 0, 3, 1),
                mipmapLevel: 0
            )
            XCTAssertEqual(
                Array(bytes[0 ..< 3]),
                blend == .normal ? [0, 0, 0] : [255, 0, 0],
                "\(blend): transparent margin"
            )
            XCTAssertEqual(
                Array(bytes[8 ..< 11]),
                [0, 0, 255],
                "\(blend): zero-alpha emission is visible"
            )
            XCTAssertEqual(
                Array(bytes[4 ..< 7]),
                [0, 255, 0],
                "\(blend): opaque part still occludes"
            )
        }
    }
}

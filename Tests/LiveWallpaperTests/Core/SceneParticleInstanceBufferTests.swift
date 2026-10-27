@testable import LiveWallpaper
import Metal
import XCTest

final class SceneParticleInstanceBufferTests: XCTestCase {
    private func instances(_ count: Int, value: Float) -> [SceneParticleSimulator.Instance] {
        Array(
            repeating: .init(
                center: SIMD2(value, -value),
                right: SIMD2(1, 0),
                up: SIMD2(0, 1),
                uvOrigin: .zero,
                uvSize: .one,
                color: SIMD4(value, 0, 0, 1),
                depth: value
            ),
            count: count
        )
    }

    func testSeparateDrawsKeepTheirDataUntilTheGPUReadsIt() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var cache = SceneParticleInstanceBuffers()
        cache.beginFrame()
        let parent = try cache.upload(instances(8, value: 2), device: device)
        let child = try cache.upload(instances(3, value: 7), device: device)
        XCTAssertFalse(parent === child)
        let result = try XCTUnwrap(device.makeBuffer(
            length: parent.length + child.length,
            options: .storageModeShared
        ))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(
            from: parent,
            sourceOffset: 0,
            to: result,
            destinationOffset: 0,
            size: parent.length
        )
        blit.copy(
            from: child,
            sourceOffset: 0,
            to: result,
            destinationOffset: parent.length,
            size: child.length
        )
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertNil(command.error)
        let values = result.contents().assumingMemoryBound(to: SceneParticleSimulator.Instance.self)
        for index in 0 ..< 8 {
            XCTAssertEqual(values[index].center.x, 2)
        }
        for index in 8 ..< 11 {
            XCTAssertEqual(values[index].center.x, 7)
        }
    }

    func testStableAndShrinkingDrawsReuseStorageAndUpdateContents() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var cache = SceneParticleInstanceBuffers()
        cache.beginFrame()
        let first = try cache.upload(instances(32, value: 1), device: device)
        let second = try cache.upload(instances(16, value: 2), device: device)
        for frame in 1 ... 120 {
            cache.beginFrame()
            let a = try cache.upload(
                instances(frame.isMultiple(of: 2) ? 4 : 32, value: Float(frame)),
                device: device
            )
            let b = try cache.upload(instances(16, value: 3), device: device)
            XCTAssertTrue(a === first)
            XCTAssertTrue(b === second)
            XCTAssertEqual(
                a.contents().assumingMemoryBound(to: SceneParticleSimulator.Instance.self).pointee
                    .center.x,
                Float(frame)
            )
        }
    }

    func testGrowthPreservesOtherDrawsAndReservesRoomForMoreParticles() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var cache = SceneParticleInstanceBuffers()
        cache.beginFrame()
        let first = try cache.upload(instances(8, value: 1), device: device)
        let child = try cache.upload(instances(2, value: 9), device: device)
        cache.beginFrame()
        let grown = try cache.upload(instances(9, value: 2), device: device)
        XCTAssertFalse(grown === first)
        XCTAssertGreaterThanOrEqual(
            grown.length,
            9 * MemoryLayout<SceneParticleSimulator.Instance>.stride
        )
        XCTAssertTrue(try cache.upload(instances(2, value: 3), device: device) === child)
        cache.beginFrame()
        XCTAssertTrue(try cache.upload(instances(10, value: 4), device: device) === grown)
        XCTAssertEqual(
            grown.contents().assumingMemoryBound(to: SceneParticleSimulator.Instance.self)[9].depth,
            4
        )
    }

    func testResetDiscardsStorageAndRestartsTheDrawOrder() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var cache = SceneParticleInstanceBuffers()
        let old = try cache.upload(instances(100, value: 1), device: device)
        cache.removeAll()
        cache.beginFrame()
        let fresh = try cache.upload(instances(1, value: 2), device: device)
        XCTAssertFalse(old === fresh)
        XCTAssertLessThan(fresh.length, old.length)
    }
}

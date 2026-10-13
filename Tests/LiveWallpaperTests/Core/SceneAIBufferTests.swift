import CoreVideo
import XCTest
@testable import LiveWallpaper

final class SceneAIBufferTests: XCTestCase {
    func testFloat16AndFloat32PlanesResampleToTheSameDepthValues() throws {
        let bits: [UInt16] = [0x0000, 0x8000, 0x3C00, 0xBC00, 0x3800, 0x0400, 0x0001, 0x7BFF]
        let values: [Float] = [0, -0.0, 1, -1, 0.5, 1 / 16384, 1 / 16777216, 65504]
        var results: [[Float]] = []
        for format in [kCVPixelFormatType_OneComponent16Half, kCVPixelFormatType_OneComponent32Float] {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 4, 2, format, nil, &buffer), kCVReturnSuccess)
            let plane = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(plane, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(plane))
            let stride = CVPixelBufferGetBytesPerRow(plane)
            for y in 0..<2 {
                let row = base.advanced(by: y * stride)
                for x in 0..<4 {
                    if format == kCVPixelFormatType_OneComponent16Half {
                        row.assumingMemoryBound(to: UInt16.self)[x] = bits[y * 4 + x]
                    } else {
                        row.assumingMemoryBound(to: Float.self)[x] = values[y * 4 + x]
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(plane, [])
            XCTAssertEqual(SceneAI.readFloatPlane(plane, width: 4, height: 2), values)
            results.append(SceneAI.readFloatPlane(plane, width: 8, height: 4))
        }
        XCTAssertEqual(results[0], results[1])
    }
}

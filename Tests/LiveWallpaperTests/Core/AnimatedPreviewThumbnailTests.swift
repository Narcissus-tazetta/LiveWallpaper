import AppKit
import ImageIO
@testable import LiveWallpaper
import UniformTypeIdentifiers
import XCTest

final class AnimatedPreviewThumbnailTests: XCTestCase {
    func testAnimatedPreviewRemainsVisibleWhenItsMiddleFrameIsBlack() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).gif")
        defer { try! FileManager.default.removeItem(at: url) }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 3, nil))
        for color in [NSColor.red, .black, .black] {
            let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                                                bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let image = try XCTUnwrap(VideoThumbnailGenerator.previewImage(from: url))
        let bitmap = NSBitmapImageRep(cgImage: image)
        let color = try XCTUnwrap(bitmap.colorAt(x: 8, y: 8)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.redComponent, 0.9)
        XCTAssertGreaterThan(color.redComponent, color.greenComponent * 2)
    }
}

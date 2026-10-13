import CoreGraphics
import Foundation
import ImageIO

/// Tells whether a point of a layer image is see-through, so a click on the preview
/// picks the layer that is actually visible there. Works on a small copy of the
/// alpha channel per file.
@MainActor
final class SceneHitTester {
    private struct AlphaMap {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    private static let maxEdge = 256
    /// nil value: the image has no alpha and is opaque everywhere.
    private var maps: [String: AlphaMap?] = [:]

    /// `uv` in the layer's UV (origin top-left).
    func isOpaque(fileURL: URL, at uv: SIMD2<Float>) -> Bool {
        guard uv.x >= 0, uv.x <= 1, uv.y >= 0, uv.y <= 1 else {
            return false
        }
        let key = fileURL.path
        if maps[key] == nil {
            maps[key] = Self.alphaMap(fileURL)
        }
        guard let map = maps[key] ?? nil else {
            return true
        }
        let x = min(Int(uv.x * Float(map.width)), map.width - 1)
        let y = min(Int(uv.y * Float(map.height)), map.height - 1)
        return map.bytes[y * map.width + x] > 25
    }

    private static func alphaMap(_ url: URL) -> AlphaMap? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            AppLog.windowRefresh.error("hit test image unreadable: \(url.lastPathComponent, privacy: .public)")
            return nil
        }
        guard ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) else {
            return nil
        }
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drew: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drew ? AlphaMap(width: width, height: height, bytes: bytes) : nil
    }
}

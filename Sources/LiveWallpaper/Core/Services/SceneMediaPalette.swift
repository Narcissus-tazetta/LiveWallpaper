import CoreGraphics
import Foundation
import ImageIO
import simd

/// The main colours of a track's artwork, 0...1 RGB, for scene scripts.
struct SceneMediaPalette: Equatable {
    var primary: SIMD3<Double>
    var secondary: SIMD3<Double>
    var tertiary: SIMD3<Double>
    /// Readable on `primary`: the secondary or tertiary colour when either has enough
    /// contrast, otherwise black or white.
    var text: SIMD3<Double>
    /// Black or white, whichever contrasts more with `primary`.
    var highContrast: SIMD3<Double>

    enum PaletteError: Error {
        case undecodableImage
    }

    init(imageData: Data) throws {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 64
              ] as CFDictionary)
        else { throw PaletteError.undecodableImage }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                    bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        // 4 bits per channel; the colour of a bucket is the mean of its pixels.
        var sums: [Int: (color: SIMD3<Double>, count: Int)] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] >= 128 {
            let alpha = Double(pixels[index + 3]) / 255
            let color = SIMD3(Double(pixels[index]), Double(pixels[index + 1]), Double(pixels[index + 2])) / 255 / alpha
            let key = Int(pixels[index] >> 4) << 8 | Int(pixels[index + 1] >> 4) << 4 | Int(pixels[index + 2] >> 4)
            let old = sums[key] ?? (.zero, 0)
            sums[key] = (old.color + color, old.count + 1)
        }
        let ranked = sums.values.sorted { $0.count > $1.count }.map { simd_clamp($0.color / Double($0.count), .zero, .one) }
        guard let primary = ranked.first else { throw PaletteError.undecodableImage }
        func distinct(from chosen: [SIMD3<Double>]) -> SIMD3<Double> {
            ranked.first { color in chosen.allSatisfy { simd_distance($0, color) > 0.15 } } ?? chosen.last!
        }
        let secondary = distinct(from: [primary])
        let tertiary = distinct(from: [primary, secondary])
        let black = SIMD3<Double>.zero, white = SIMD3<Double>.one
        let highContrast = Self.contrast(primary, black) >= Self.contrast(primary, white) ? black : white
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.highContrast = highContrast
        text = [secondary, tertiary].first { Self.contrast(primary, $0) >= 4.5 } ?? highContrast
    }

    /// WCAG contrast ratio.
    static func contrast(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        func luminance(_ color: SIMD3<Double>) -> Double {
            let linear = color.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear.x + 0.7152 * linear.y + 0.0722 * linear.z
        }
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }
}

private extension SIMD3 where Scalar == Double {
    func map(_ transform: (Double) -> Double) -> SIMD3<Double> { SIMD3(transform(x), transform(y), transform(z)) }
}

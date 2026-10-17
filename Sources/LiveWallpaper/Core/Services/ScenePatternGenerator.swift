import CoreGraphics
import Foundation

/// The tiling images real-time effects read when the editor adds them: smooth noise,
/// a normal map made from it, and a flow phase. Every lattice repeats a whole number
/// of times across the image, so the image tiles without a seam.
enum ScenePatternGenerator {
    enum Pattern {
        /// 256², each of red, green and blue an independent noise.
        case noise
        /// 256², a water-like surface's normals (0.5 = flat, blue up).
        case normals
        /// 32², grey noise.
        case phase
    }

    /// The pattern a newly added effect of `kind` reads; nil when it needs none.
    static func pattern(for kind: SceneEffectKind) -> Pattern? {
        switch kind {
        case .flowMap: .phase
        case .normalRipples: .normals
        case .noiseDrift, .noiseSway, .pulseBlend, .axisSwing: .noise
        default: nil
        }
    }

    static func image(_ pattern: Pattern, seed: UInt32 = 1) -> CGImage {
        switch pattern {
        case .noise:
            return makeImage(size: 256) { x, y in
                (0 ..< 3).map { channel in fbm(x, y, size: 256, seed: seed &+ UInt32(channel) &* 101) }
            }
        case .normals:
            let size = 256
            let heights = (0 ..< size * size).map { fbm($0 % size, $0 / size, size: size, seed: seed) }
            // Steepness of the surface: enough to bend the picture visibly, not so
            // much that the normals lie flat.
            let slope = 6.0
            return makeImage(size: size) { x, y in
                func h(_ x: Int, _ y: Int) -> Double { heights[((y + size) % size) * size + (x + size) % size] }
                let dx = (h(x + 1, y) - h(x - 1, y)) / 2 * slope * Double(size) / 64
                let dy = (h(x, y + 1) - h(x, y - 1)) / 2 * slope * Double(size) / 64
                let length = (dx * dx + dy * dy + 1).squareRoot()
                return [-dx / length * 0.5 + 0.5, -dy / length * 0.5 + 0.5, 1 / length * 0.5 + 0.5]
            }
        case .phase:
            return makeImage(size: 32) { x, y in
                let value = fbm(x, y, size: 32, seed: seed)
                return [value, value, value]
            }
        }
    }

    /// Smooth noise in 0...1, the sum of octaves whose lattices divide `size`.
    private static func fbm(_ x: Int, _ y: Int, size: Int, seed: UInt32) -> Double {
        var sum = 0.0, weight = 1.0, total = 0.0
        var cells = 4
        while cells <= size / 4 {
            sum += latticeNoise(Double(x) / Double(size) * Double(cells), Double(y) / Double(size) * Double(cells),
                                period: cells, seed: seed &+ UInt32(cells)) * weight
            total += weight
            weight *= 0.5
            cells *= 2
        }
        return sum / total
    }

    private static func latticeNoise(_ x: Double, _ y: Double, period: Int, seed: UInt32) -> Double {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - Double(x0), fy = y - Double(y0)
        func corner(_ cx: Int, _ cy: Int) -> Double {
            hash(UInt32((cx % period + period) % period), UInt32((cy % period + period) % period), seed)
        }
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let top = corner(x0, y0) + (corner(x0 + 1, y0) - corner(x0, y0)) * sx
        let bottom = corner(x0, y0 + 1) + (corner(x0 + 1, y0 + 1) - corner(x0, y0 + 1)) * sx
        return top + (bottom - top) * sy
    }

    private static func hash(_ x: UInt32, _ y: UInt32, _ seed: UInt32) -> Double {
        var h = x &* 0x8DA6_B343 ^ y &* 0xD816_3841 ^ seed &* 0xCB1A_B31F
        h ^= h >> 13
        h = h &* 0x5BD1_E995
        h ^= h >> 15
        return Double(h) / Double(UInt32.max)
    }

    private static func makeImage(size: Int, _ pixel: (Int, Int) -> [Double]) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0 ..< size {
            for x in 0 ..< size {
                let value = pixel(x, y)
                for channel in 0 ..< 3 {
                    bytes[(y * size + x) * 4 + channel] = UInt8((min(max(value[channel], 0), 1) * 255).rounded())
                }
            }
        }
        // Built from bytes it fully controls, so the image cannot fail to exist.
        return CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}

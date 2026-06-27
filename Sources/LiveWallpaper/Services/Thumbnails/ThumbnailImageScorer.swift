import AppKit
import CoreGraphics

enum ThumbnailImageScorer {
    static func score(_ image: CGImage) -> Double {
        let width = 128
        let height = 72
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = bytesPerRow * height
        var raw = [UInt8](repeating: 0, count: totalBytes)

        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: &raw,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return 0
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var luma = [Double](repeating: 0, count: width * height)
        var sum: Double = 0

        for y in 0 ..< height {
            for x in 0 ..< width {
                let i = y * bytesPerRow + x * bytesPerPixel
                let r = Double(raw[i])
                let g = Double(raw[i + 1])
                let b = Double(raw[i + 2])
                let value = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let p = y * width + x
                luma[p] = value
                sum += value
            }
        }

        let count = Double(width * height)
        let mean = sum / count
        var variance: Double = 0
        for value in luma {
            let delta = value - mean
            variance += delta * delta
        }
        variance /= count

        var edgeSum: Double = 0
        var edgeCount: Double = 0
        for y in 0 ..< (height - 1) {
            for x in 0 ..< (width - 1) {
                let p = y * width + x
                edgeSum += abs(luma[p] - luma[p + 1])
                edgeSum += abs(luma[p] - luma[p + width])
                edgeCount += 2
            }
        }

        let edge = edgeCount > 0 ? (edgeSum / edgeCount) : 0
        let brightnessPenalty = brightnessPenalty(forMeanLuma: mean)
        return max((variance + edge * 8) * brightnessPenalty, 0)
    }

    static func isLowInformation(_ image: CGImage) -> Bool {
        score(image) < 80
    }

    private static func brightnessPenalty(forMeanLuma mean: Double) -> Double {
        if mean < 8 || mean > 247 {
            return 0.05
        }
        if mean < 22 {
            return mean / 22
        }
        if mean > 232 {
            return (255 - mean) / 23
        }
        return 1
    }
}

import AppKit
import AVFoundation

enum FitPreviewService {
    static func generateStillImage(path: String) async -> NSImage? {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)

        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            duration = CMTime(seconds: 8.0, preferredTimescale: 600)
        }
        let durationSeconds = CMTimeGetSeconds(duration)
        let usableDuration: Double =
            (durationSeconds.isFinite && durationSeconds > 0.3) ? durationSeconds : 8.0
        let rawCandidates: [Double] = [0.18, 0.32, 0.46, 0.60, 0.74]
        let candidateTimes: [CMTime] = rawCandidates.map { ratio in
            let t = min(max(usableDuration * ratio, 0.12), max(usableDuration - 0.12, 0.12))
            return CMTime(seconds: t, preferredTimescale: 600)
        }

        var bestImage: CGImage?
        var bestScore: Double = -1

        for time in candidateTimes {
            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
                continue
            }
            let score = fitPreviewImageScore(cgImage)
            if score > bestScore {
                bestScore = score
                bestImage = cgImage
            }
        }

        if let bestImage {
            return NSImage(
                cgImage: bestImage, size: NSSize(width: bestImage.width, height: bestImage.height)
            )
        }

        let fallbackTimes: [CMTime] = [
            CMTime(seconds: 0.2, preferredTimescale: 600),
            CMTime(seconds: 1.0, preferredTimescale: 600)
        ]
        for time in fallbackTimes {
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                return NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: cgImage.width, height: cgImage.height)
                )
            }
        }

        return nil
    }

    private static func fitPreviewImageScore(_ image: CGImage) -> Double {
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
        for v in luma {
            let d = v - mean
            variance += d * d
        }
        variance /= count

        var edgeSum: Double = 0
        var edgeCount: Double = 0
        for y in 0 ..< (height - 1) {
            for x in 0 ..< (width - 1) {
                let p = y * width + x
                let dx = abs(luma[p] - luma[p + 1])
                let dy = abs(luma[p] - luma[p + width])
                edgeSum += dx + dy
                edgeCount += 2
            }
        }
        let edge = edgeCount > 0 ? (edgeSum / edgeCount) : 0

        return variance + edge * 8
    }
}

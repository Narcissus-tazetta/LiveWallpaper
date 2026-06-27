import AppKit
import AVFoundation

final class ThumbnailGenerator {
    func generateThumbnail(for path: String, maxSize: CGSize) async -> NSImage? {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize

        do {
            let duration = try await asset.load(.duration)
            let durationSeconds = CMTimeGetSeconds(duration)
            let usableDuration = (durationSeconds.isFinite && durationSeconds > 0.3)
                ? durationSeconds
                : 8.0
            let candidateRatios: [Double] = [0.12, 0.22, 0.34, 0.46, 0.58, 0.70, 0.82]
            var bestImage: CGImage?
            var bestScore: Double = -1

            for ratio in candidateRatios {
                let seconds = min(max(usableDuration * ratio, 0.15), max(usableDuration - 0.15, 0.15))
                let targetTime = CMTime(seconds: seconds, preferredTimescale: 600)
                guard let cgImage = try? generator.copyCGImage(at: targetTime, actualTime: nil) else {
                    continue
                }
                let score = ThumbnailImageScorer.score(cgImage)
                if score > bestScore {
                    bestScore = score
                    bestImage = cgImage
                }
                if score >= 1200 {
                    break
                }
            }

            guard let bestImage else {
                return nil
            }
            return NSImage(
                cgImage: bestImage,
                size: NSSize(width: bestImage.width, height: bestImage.height)
            )
        } catch {
            return nil
        }
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}

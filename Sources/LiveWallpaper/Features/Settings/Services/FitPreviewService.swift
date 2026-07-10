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
            if Task.isCancelled {
                return nil
            }
            guard let cgImage = try? await generator.image(at: time).image else {
                continue
            }
            let score = ThumbnailImageScorer.score(cgImage)
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
            if Task.isCancelled {
                return nil
            }
            if let cgImage = try? await generator.image(at: time).image {
                return NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: cgImage.width, height: cgImage.height)
                )
            }
        }

        return nil
    }
}

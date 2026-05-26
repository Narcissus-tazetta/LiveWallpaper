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
            let targetTime = CMTime(
                seconds: min(max(durationSeconds * 0.3, 0.1), durationSeconds - 0.1),
                preferredTimescale: 600
            )

            let cgImage = try generator.copyCGImage(at: targetTime, actualTime: nil)
            return NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
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

import CoreGraphics
import Foundation
import ImageIO
import os
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {
    enum ThumbnailError: Error {
        case noThumbnail
        case undecodableImage
    }

    private static let logger = Logger(
        subsystem: "com.sakana.livewallpaper.QuickLookThumbnail",
        category: "thumbnail"
    )

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let image: CGImage
        do {
            guard let data = try PackageThumbnailLocator.thumbnailData(in: request.fileURL) else {
                throw ThumbnailError.noThumbnail
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw ThumbnailError.undecodableImage
            }
            image = decoded
        } catch {
            // Replying with an error makes Finder fall back to the generic document icon.
            Self.logger.error(
                "no thumbnail for \(request.fileURL.lastPathComponent, privacy: .private): \(String(describing: error), privacy: .public)"
            )
            handler(nil, error)
            return
        }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(request.maximumSize.width / width, request.maximumSize.height / height)
        let size = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())

        let reply = QLThumbnailReply(contextSize: size) { context in
            context.interpolationQuality = .high
            // The context is contextSize × request.scale in pixels with an unscaled CTM, so
            // drawing at `size` filled only the bottom-left quarter on Retina displays.
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: context.width, height: context.height)
            )
            return true
        }
        handler(reply, nil)
    }
}

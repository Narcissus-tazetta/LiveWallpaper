import AVFoundation
import AppKit
import QuickLookThumbnailing

/// QLThumbnailGenerator → AVAssetImageGenerator フォールバックの共通ロジック。
/// `DiskThumbnailCache`(ローカル動画一覧のプレビュー用キャッシュ)と
/// `StoreClient`(Store投稿時のサムネイル生成)の両方から利用される。
enum VideoThumbnailGenerator {
  static func generateBestThumbnail(
    path: String,
    size: CGSize = CGSize(width: 480, height: 270)
  ) async -> NSImage? {
    let url = URL(fileURLWithPath: path)
    let request = QLThumbnailGenerator.Request(
      fileAt: url,
      size: size,
      scale: NSScreen.main?.backingScaleFactor ?? 2,
      representationTypes: .all
    )

    let representation = await withCheckedContinuation {
      (continuation: CheckedContinuation<QLThumbnailRepresentation?, Never>) in
      QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
        continuation.resume(returning: representation)
      }
    }

    if let cgImage = representation?.cgImage, !ThumbnailImageScorer.isLowInformation(cgImage) {
      return NSImage(
        cgImage: cgImage,
        size: NSSize(width: cgImage.width, height: cgImage.height)
      )
    }

    // AVAssetImageGenerator のフレーム抽出は同期・重量処理なので、呼び出し元が
    // MainActorであってもブロックしないようバックグラウンドキューへ逃がす。
    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: generateFallbackThumbnail(path: path))
      }
    }
  }

  nonisolated static func generateFallbackThumbnail(path: String) -> NSImage? {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 420, height: 236)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .positiveInfinity

    let candidateSeconds: [Double] = [0.2, 0.8, 1.5, 3.0, 6.0, 10.0, 15.0, 30.0]
    var bestImage: CGImage?
    var bestScore: Double = -1

    for seconds in candidateSeconds {
      let time = CMTime(seconds: seconds, preferredTimescale: 600)
      guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
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

    if let bestImage {
      return NSImage(
        cgImage: bestImage,
        size: NSSize(width: bestImage.width, height: bestImage.height)
      )
    }

    return nil
  }

  /// Store配布用のJPEGエンコード。ローカルキャッシュ用(480x270, quality 0.82)より
  /// 一段小さい320x180 + quality 0.7 にリサイズし、配布ファイルサイズを抑える
  /// (想定15〜40KB程度)。
  nonisolated static func jpegData(
    _ image: NSImage,
    maxSize: NSSize = NSSize(width: 320, height: 180),
    quality: CGFloat = 0.7
  ) -> Data? {
    let resized = resized(image, toFit: maxSize)
    guard let tiff = resized.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff)
    else {
      return nil
    }
    return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
  }

  private nonisolated static func resized(_ image: NSImage, toFit maxSize: NSSize) -> NSImage {
    let sourceSize = image.size
    guard sourceSize.width > 0, sourceSize.height > 0 else {
      return image
    }
    let scale = min(maxSize.width / sourceSize.width, maxSize.height / sourceSize.height, 1)
    guard scale < 1 else {
      return image
    }
    let newSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    let newImage = NSImage(size: newSize)
    newImage.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(
      in: NSRect(origin: .zero, size: newSize),
      from: NSRect(origin: .zero, size: sourceSize),
      operation: .copy,
      fraction: 1.0
    )
    newImage.unlockFocus()
    return newImage
  }
}

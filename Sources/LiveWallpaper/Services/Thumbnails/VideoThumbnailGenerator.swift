import AVFoundation
import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// QLThumbnailGenerator → AVAssetImageGenerator フォールバックの共通ロジック。
/// `DiskThumbnailCache`(ローカル動画一覧のプレビュー用キャッシュ)と
/// `StoreClient`(Store投稿時のサムネイル生成)の両方から利用される。
enum VideoThumbnailGenerator {
  nonisolated static func expectedSidecarURL(for videoPath: String) -> URL {
    URL(fileURLWithPath: videoPath).deletingPathExtension().appendingPathExtension("preview.jpg")
  }

  nonisolated static func sidecarURL(for videoPath: String) -> URL? {
    let candidate = expectedSidecarURL(for: videoPath)
    return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
  }

  @discardableResult
  nonisolated static func saveNormalizedPreview(from sourceURL: URL, to destinationURL: URL) -> Bool {
    guard let cgImage = previewImage(from: sourceURL) else { return false }
    let mutableData = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(mutableData as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
      return false
    }
    let destinationOptions: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: 0.82
    ]
    CGImageDestinationAddImage(destination, cgImage, destinationOptions as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      return false
    }
    do {
      try (mutableData as Data).write(to: destinationURL, options: .atomic)
      return true
    } catch {
      return false
    }
  }

  nonisolated static func previewImage(from url: URL, maxPixelSize: Int = 480) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let count = CGImageSourceGetCount(source)
    guard count > 0 else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ]
    var selected = 0
    if count > 1 {
      // Animated previews can fade to black in the middle as well as at the start.
      var brightest = -1.0
      var sampleOptions = options
      sampleOptions[kCGImageSourceThumbnailMaxPixelSize] = 32
      for index in Set((0..<min(count, 9)).map { $0 * (count - 1) / (min(count, 9) - 1) }).sorted() {
        guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, sampleOptions as CFDictionary) else { continue }
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let brightness = pixels.withUnsafeMutableBytes { buffer -> Double in
          let context = CGContext(data: buffer.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
                                  bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
          context.draw(frame, in: CGRect(x: 0, y: 0, width: 32, height: 32))
          let bytes = buffer.bindMemory(to: UInt8.self)
          return stride(from: 0, to: bytes.count, by: 4).reduce(0.0) {
            $0 + 0.2126 * Double(bytes[$1]) + 0.7152 * Double(bytes[$1 + 1]) + 0.0722 * Double(bytes[$1 + 2])
          }
        }
        if brightness > brightest { brightest = brightness; selected = index }
      }
    }
    return CGImageSourceCreateThumbnailAtIndex(source, selected, options as CFDictionary)
  }

  static func generateBestThumbnail(
    path: String,
    size: CGSize = CGSize(width: 480, height: 270)
  ) async -> NSImage? {
    if let sidecar = sidecarURL(for: path),
       let image = NSImage(contentsOf: sidecar) {
      return image
    }

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
    if let sidecar = sidecarURL(for: path),
       let image = NSImage(contentsOf: sidecar) {
      return image
    }

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

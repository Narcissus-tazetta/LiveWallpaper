import AVFoundation
import AppKit
import QuickLookThumbnailing

extension DiskThumbnailCache {
  func generate(path: String) {
    let url = URL(fileURLWithPath: path)
    let request = QLThumbnailGenerator.Request(
      fileAt: url,
      size: CGSize(width: 480, height: 270),
      scale: NSScreen.main?.backingScaleFactor ?? 2,
      representationTypes: .all
    )

    QLThumbnailGenerator.shared
      .generateBestRepresentation(for: request) { [weak self] representation, _ in
        guard let self else {
          return
        }

        if let cgImage = representation?.cgImage {
          let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
          )
          DispatchQueue.main.async {
            self.finishGeneration(path: path, image: image)
          }
          return
        }

        DispatchQueue.global(qos: .userInitiated).async {
          let fallback = Self.generateFallbackThumbnail(path: path)
          DispatchQueue.main.async {
            self.finishGeneration(path: path, image: fallback)
          }
        }
      }
  }

  func finishGeneration(path: String, image: NSImage?) {
    if let image, visiblePaths.contains(path) {
      inMemoryImages[path] = image
      touch(path)
      trimInMemoryIfNeeded()
      writeToDisk(path: path, image: image)
    }

    inFlight.remove(path)
    processQueue()
    bumpRevision()
  }

  nonisolated static func generateFallbackThumbnail(path: String) -> NSImage? {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 420, height: 236)
    let candidates = [0.2, 1.0]

    for seconds in candidates {
      let time = CMTime(seconds: seconds, preferredTimescale: 600)
      if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
        return NSImage(
          cgImage: cgImage,
          size: NSSize(width: cgImage.width, height: cgImage.height)
        )
      }
    }

    return nil
  }

  func writeToDisk(path: String, image: NSImage) {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let fileSize = attributes[.size] as? NSNumber,
      let modifiedDate = attributes[.modificationDate] as? Date,
      let data = imageData(image)
    else {
      return
    }

    let fileName = "\(hashed(path)).jpg"
    let fileURL = dataDirectoryURL().appendingPathComponent(fileName)

    do {
      try data.write(to: fileURL, options: .atomic)
    } catch {
      return
    }

    metadata.entries[path] = Entry(
      fileName: fileName,
      sourcePath: path,
      sourceSize: fileSize.uint64Value,
      sourceModifiedAt: modifiedDate.timeIntervalSince1970,
      lastAccessAt: Date().timeIntervalSince1970
    )
    persistMetadata()
    trimDiskIfNeeded()
  }

  func imageData(_ image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff)
    else {
      return nil
    }
    return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
  }
}

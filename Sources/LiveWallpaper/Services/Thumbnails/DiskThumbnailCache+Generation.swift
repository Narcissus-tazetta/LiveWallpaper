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

        if let cgImage = representation?.cgImage,
          !ThumbnailImageScorer.isLowInformation(cgImage)
        {
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

  func writeToDisk(path: String, image: NSImage) {
    guard let dataDirectoryURL = Self.dataDirectoryURL() else {
      return
    }
    let fileName = "\(Self.hashed(path)).jpg"
    let fileURL = dataDirectoryURL.appendingPathComponent(fileName)
    ioQueue.async { [weak self] in
      guard let entry = DiskThumbnailCache.buildEntryForWrite(
        sourcePath: path,
        fileName: fileName,
        fileURL: fileURL,
        image: image
      ) else {
        return
      }
      Task { @MainActor in
        guard let self else {
          return
        }
        self.metadata.entries[path] = entry
        self.persistMetadata()
        self.trimDiskIfNeeded()
      }
    }
  }

  nonisolated static func buildEntryForWrite(
    sourcePath: String,
    fileName: String,
    fileURL: URL,
    image: NSImage
  ) -> Entry? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: sourcePath),
      let fileSize = attributes[.size] as? NSNumber,
      let modifiedDate = attributes[.modificationDate] as? Date,
      let data = imageData(image)
    else {
      return nil
    }

    do {
      try data.write(to: fileURL, options: .atomic)
    } catch {
      return nil
    }

    return Entry(
      fileName: fileName,
      sourcePath: sourcePath,
      sourceSize: fileSize.uint64Value,
      sourceModifiedAt: modifiedDate.timeIntervalSince1970,
      lastAccessAt: Date().timeIntervalSince1970
    )
  }
}

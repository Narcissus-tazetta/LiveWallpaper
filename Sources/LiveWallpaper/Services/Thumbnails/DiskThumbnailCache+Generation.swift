import AppKit

extension DiskThumbnailCache {
  func generate(path: String) {
    Task {
      let image = await VideoThumbnailGenerator.generateBestThumbnail(path: path)
      finishGeneration(path: path, image: image)
    }
  }

  func finishGeneration(path: String, image: NSImage?) {
    if let image, isPathVisible(path) {
      inMemoryImages[path] = image
      touch(path)
      trimInMemoryIfNeeded()
      writeToDisk(path: path, image: image)
    }

    inFlight.remove(path)
    processQueue()
    bumpRevision()
  }

  func writeToDisk(path: String, image: NSImage) {
    guard let dataDirectoryURL = Self.dataDirectoryURL() else {
      return
    }
    let fileName = "\(CacheKeyHashing.hashed(path)).jpg"
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

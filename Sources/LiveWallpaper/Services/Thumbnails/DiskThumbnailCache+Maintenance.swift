import AppKit
import CryptoKit

extension DiskThumbnailCache {
  nonisolated enum DiskReadResult {
    case data(Data)
    case invalidSource
    case missingData
  }

  nonisolated static func loadThumbnailData(
    sourcePath: String,
    entry: Entry,
    fileURL: URL
  ) -> DiskReadResult {
    guard isSourceValid(path: sourcePath, entry: entry) else {
      return .invalidSource
    }
    guard let data = try? Data(contentsOf: fileURL) else {
      return .missingData
    }
    return .data(data)
  }

  nonisolated static func isSourceValid(path: String, entry: Entry) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let fileSize = attributes[.size] as? NSNumber,
      let modifiedDate = attributes[.modificationDate] as? Date
    else {
      return false
    }

    let sizeMatches = fileSize.uint64Value == entry.sourceSize
    let mtimeMatches = abs(modifiedDate.timeIntervalSince1970 - entry.sourceModifiedAt) < 0.001
    return sizeMatches && mtimeMatches
  }

  func touch(_ path: String) {
    let now = Date().timeIntervalSince1970
    inMemoryLastAccess[path] = now
    if var entry = metadata.entries[path] {
      entry.lastAccessAt = now
      metadata.entries[path] = entry
      persistMetadata()
    }
  }

  func removeEntry(_ path: String) {
    guard let entry = metadata.entries.removeValue(forKey: path) else {
      return
    }

    guard let dataDirectoryURL = Self.dataDirectoryURL() else {
      return
    }

    let fileURL = dataDirectoryURL.appendingPathComponent(entry.fileName)
    ioQueue.async {
      try? FileManager.default.removeItem(at: fileURL)
    }

    inMemoryImages.removeValue(forKey: path)
    inMemoryLastAccess.removeValue(forKey: path)
    if let index = pendingQueue.firstIndex(of: path) {
      pendingQueue.remove(at: index)
    }
    inFlight.remove(path)
    visiblePaths.remove(path)
    persistMetadata()
  }

  func trimInMemoryIfNeeded() {
    if inMemoryImages.count <= maxInMemoryCount {
      return
    }

    let removeCount = inMemoryImages.count - maxInMemoryCount
    let removable = inMemoryLastAccess.keys
      .filter { !visiblePaths.contains($0) }
      .sorted {
        (inMemoryLastAccess[$0] ?? .leastNormalMagnitude)
          < (inMemoryLastAccess[$1] ?? .leastNormalMagnitude)
      }

    for key in removable.prefix(removeCount) {
      inMemoryImages.removeValue(forKey: key)
      inMemoryLastAccess.removeValue(forKey: key)
    }
  }

  func trimDiskIfNeeded() {
    let entries = metadata.entries
    let maxBytes = maxDiskBytes
    guard let dataURL = Self.dataDirectoryURL() else {
      return
    }
    ioQueue.async { [weak self] in
      let fileManager = FileManager.default
      var sizedEntries: [SizedEntry] = []
      var totalSize: UInt64 = 0

      for (path, entry) in entries {
        let fileURL = dataURL.appendingPathComponent(entry.fileName)
        guard let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
          let size = attrs[.size] as? NSNumber
        else {
          continue
        }
        let bytes = size.uint64Value
        totalSize += bytes
        sizedEntries.append(SizedEntry(path: path, entry: entry, bytes: bytes))
      }

      if totalSize <= maxBytes {
        return
      }

      let sorted = sizedEntries.sorted { $0.entry.lastAccessAt < $1.entry.lastAccessAt }
      var overflow = totalSize - maxBytes
      var removed: [(String, String)] = []

      for item in sorted {
        if overflow == 0 {
          break
        }
        let fileURL = dataURL.appendingPathComponent(item.entry.fileName)
        try? fileManager.removeItem(at: fileURL)
        removed.append((item.path, item.entry.fileName))
        if overflow > item.bytes {
          overflow -= item.bytes
        } else {
          overflow = 0
        }
      }

      guard !removed.isEmpty else {
        return
      }

      Task { @MainActor in
        guard let self else {
          return
        }
        var removedAny = false
        for (path, fileName) in removed {
          guard let entry = self.metadata.entries[path],
            entry.fileName == fileName
          else {
            continue
          }
          self.metadata.entries.removeValue(forKey: path)
          self.inMemoryImages.removeValue(forKey: path)
          self.inMemoryLastAccess.removeValue(forKey: path)
          if let index = self.pendingQueue.firstIndex(of: path) {
            self.pendingQueue.remove(at: index)
          }
          self.inFlight.remove(path)
          self.visiblePaths.remove(path)
          removedAny = true
        }
        guard removedAny else {
          return
        }
        self.persistMetadata()
        self.bumpRevision()
      }
    }
  }

  func persistMetadata() {
    metadataDirty = true
    scheduleMetadataFlush()
  }

  func scheduleMetadataFlush() {
    metadataFlushWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      Task { @MainActor in
        self?.flushMetadataIfNeeded()
      }
    }
    metadataFlushWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + metadataFlushDelay,
      execute: workItem
    )
  }

  func flushMetadataIfNeeded() {
    guard metadataDirty else {
      return
    }
    metadataDirty = false
    metadataFlushWorkItem?.cancel()
    metadataFlushWorkItem = nil

    let snapshot = metadata
    guard let metadataURL = Self.metadataFileURL() else {
      NSLog("[ThumbnailCache] metadata path unavailable")
      return
    }
    ioQueue.async {
      do {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: metadataURL, options: .atomic)
      } catch {
        NSLog("[ThumbnailCache] metadata flush failed error=\(error.localizedDescription)")
      }
    }
  }

  func flushMetadataImmediately() {
    guard metadataDirty else {
      return
    }
    metadataDirty = false
    metadataFlushWorkItem?.cancel()
    metadataFlushWorkItem = nil

    let snapshot = metadata
    guard let metadataURL = Self.metadataFileURL() else {
      NSLog("[ThumbnailCache] metadata path unavailable")
      return
    }
    ioQueue.sync {
      do {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: metadataURL, options: .atomic)
      } catch {
        NSLog("[ThumbnailCache] metadata flush failed error=\(error.localizedDescription)")
      }
    }
  }

  nonisolated static func rootDirectoryURL() -> URL? {
    guard
      let support = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      return nil
    }
    return
      support
      .appendingPathComponent("LiveWallpaper", isDirectory: true)
      .appendingPathComponent("ThumbnailCache", isDirectory: true)
  }

  nonisolated static func dataDirectoryURL() -> URL? {
    guard let rootDirectoryURL = rootDirectoryURL() else {
      return nil
    }
    return rootDirectoryURL.appendingPathComponent("data", isDirectory: true)
  }

  nonisolated static func metadataFileURL() -> URL? {
    guard let rootDirectoryURL = rootDirectoryURL() else {
      return nil
    }
    return rootDirectoryURL.appendingPathComponent(Self.metadataFileName)
  }

  nonisolated static func hashed(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  nonisolated static func imageData(_ image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff)
    else {
      return nil
    }
    return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
  }

  func bumpRevision() {
    revision += 1
  }
}

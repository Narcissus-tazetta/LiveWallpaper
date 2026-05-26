import AppKit
import CryptoKit

extension DiskThumbnailCache {
  func isSourceValid(path: String, entry: Entry) -> Bool {
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

    let fileURL = dataDirectoryURL().appendingPathComponent(entry.fileName)
    try? FileManager.default.removeItem(at: fileURL)

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
    let fileManager = FileManager.default
    var sizedEntries: [SizedEntry] = []
    var totalSize: UInt64 = 0

    for (path, entry) in metadata.entries {
      let fileURL = dataDirectoryURL().appendingPathComponent(entry.fileName)
      guard let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
        let size = attrs[.size] as? NSNumber
      else {
        continue
      }
      let bytes = size.uint64Value
      totalSize += bytes
      sizedEntries.append(SizedEntry(path: path, entry: entry, bytes: bytes))
    }

    if totalSize <= maxDiskBytes {
      return
    }

    let sorted = sizedEntries.sorted { $0.entry.lastAccessAt < $1.entry.lastAccessAt }
    var overflow = totalSize - maxDiskBytes

    for item in sorted {
      if overflow == 0 {
        break
      }
      let fileURL = dataDirectoryURL().appendingPathComponent(item.entry.fileName)
      try? fileManager.removeItem(at: fileURL)
      metadata.entries.removeValue(forKey: item.path)
      inMemoryImages.removeValue(forKey: item.path)
      inMemoryLastAccess.removeValue(forKey: item.path)
      if overflow > item.bytes {
        overflow -= item.bytes
      } else {
        overflow = 0
      }
    }

    persistMetadata()
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

    guard let data = try? JSONEncoder().encode(metadata) else {
      return
    }
    try? data.write(to: metadataFileURL(), options: .atomic)
  }

  func rootDirectoryURL() -> URL {
    let support = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    return
      support
      .appendingPathComponent("LiveWallpaper", isDirectory: true)
      .appendingPathComponent("ThumbnailCache", isDirectory: true)
  }

  func dataDirectoryURL() -> URL {
    rootDirectoryURL().appendingPathComponent("data", isDirectory: true)
  }

  func metadataFileURL() -> URL {
    rootDirectoryURL().appendingPathComponent(metadataFileName)
  }

  func hashed(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  func bumpRevision() {
    revision += 1
  }
}

import AVFoundation
import AppKit
import CryptoKit
import QuickLookThumbnailing

@MainActor
final class DiskThumbnailCache: ObservableObject {
  struct Entry: Codable {
    var fileName: String
    var sourcePath: String
    var sourceSize: UInt64
    var sourceModifiedAt: TimeInterval
    var lastAccessAt: TimeInterval
  }

  struct Metadata: Codable {
    var version: Int
    var entries: [String: Entry]
  }

  struct SizedEntry {
    var path: String
    var entry: Entry
    var bytes: UInt64
  }

  @Published var revision: Int = 0

  let maxInMemoryCount: Int = 90
  let maxDiskBytes: UInt64 = 500 * 1024 * 1024
  let maxConcurrentGenerations: Int = 2
  let metadataFileName = "metadata.json"

  var inMemoryImages: [String: NSImage] = [:]
  var inMemoryLastAccess: [String: TimeInterval] = [:]
  var visiblePaths: Set<String> = []
  var pendingQueue: [String] = []
  var inFlight: Set<String> = []
  var metadata: Metadata = .init(version: 1, entries: [:])
  var initialized: Bool = false
  var metadataDirty: Bool = false
  var metadataFlushWorkItem: DispatchWorkItem?
  let metadataFlushDelay: TimeInterval = 2.0
  var willTerminateObserver: NSObjectProtocol?

  func image(for path: String) -> NSImage? {
    ensureInitialized()

    if let cached = inMemoryImages[path] {
      touch(path)
      return cached
    }

    guard let entry = metadata.entries[path] else {
      return nil
    }

    guard isSourceValid(path: path, entry: entry) else {
      removeEntry(path)
      return nil
    }

    let fileURL = dataDirectoryURL().appendingPathComponent(entry.fileName)
    guard let image = NSImage(contentsOf: fileURL) else {
      removeEntry(path)
      return nil
    }

    inMemoryImages[path] = image
    touch(path)
    trimInMemoryIfNeeded()
    bumpRevision()
    return image
  }

  func setVisible(path: String, isVisible: Bool) {
    ensureInitialized()

    if isVisible {
      visiblePaths.insert(path)
      request(path: path)
      return
    }

    visiblePaths.remove(path)
    if let index = pendingQueue.firstIndex(of: path) {
      pendingQueue.remove(at: index)
    }
  }

  func request(path: String) {
    ensureInitialized()

    guard inMemoryImages[path] == nil else {
      touch(path)
      return
    }

    if image(for: path) != nil {
      return
    }

    guard FileManager.default.fileExists(atPath: path) else {
      return
    }
    guard !inFlight.contains(path) else {
      return
    }
    guard !pendingQueue.contains(path) else {
      return
    }

    pendingQueue.append(path)
    processQueue()
  }

  func processQueue() {
    ensureInitialized()

    while inFlight.count < maxConcurrentGenerations, !pendingQueue.isEmpty {
      let path = pendingQueue.removeFirst()
      guard visiblePaths.contains(path) else {
        continue
      }
      guard inMemoryImages[path] == nil else {
        touch(path)
        continue
      }
      guard FileManager.default.fileExists(atPath: path) else {
        continue
      }

      inFlight.insert(path)
      generate(path: path)
    }
  }

  func prewarm(paths: [String]) {
    ensureInitialized()
    for path in paths {
      guard inMemoryImages[path] == nil else {
        continue
      }
      _ = image(for: path)
    }
  }

  func prune(validPaths: Set<String>) {
    ensureInitialized()

    let stale = Set(metadata.entries.keys).subtracting(validPaths)
    for path in stale {
      removeEntry(path)
    }

    inMemoryImages = inMemoryImages.filter { validPaths.contains($0.key) }
    inMemoryLastAccess = inMemoryLastAccess.filter { validPaths.contains($0.key) }
    visiblePaths = visiblePaths.filter { validPaths.contains($0) }
    pendingQueue = pendingQueue.filter { validPaths.contains($0) }
    inFlight = inFlight.filter { validPaths.contains($0) }

    persistMetadata()
    trimDiskIfNeeded()
    flushMetadataIfNeeded()
    bumpRevision()
  }

  func clear() {
    ensureInitialized()

    let fileManager = FileManager.default
    let base = rootDirectoryURL()

    do {
      if fileManager.fileExists(atPath: base.path) {
        try fileManager.removeItem(at: base)
      }
      try fileManager.createDirectory(
        at: dataDirectoryURL(),
        withIntermediateDirectories: true
      )
    } catch {
      return
    }

    metadata = .init(version: 1, entries: [:])
    inMemoryImages.removeAll()
    inMemoryLastAccess.removeAll()
    visiblePaths.removeAll()
    pendingQueue.removeAll()
    inFlight.removeAll()
    persistMetadata()
    flushMetadataIfNeeded()
    bumpRevision()
  }

  deinit {
    if let observer = willTerminateObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }
}

import AVFoundation
import AppKit
import CryptoKit
import QuickLookThumbnailing

@MainActor
final class DiskThumbnailCache: ObservableObject {
  enum InitializationState {
    case idle
    case loading
    case ready
  }

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
  nonisolated static let metadataFileName = "metadata.json"
  let ioQueue = DispatchQueue(label: "LiveWallpaper.thumbnailCache.io", qos: .utility)

  var inMemoryImages: [String: NSImage] = [:]
  var inMemoryLastAccess: [String: TimeInterval] = [:]
  var visiblePaths: Set<String> = []
  var pendingQueue: [String] = []
  var inFlight: Set<String> = []
  var inFlightReads: Set<String> = []
  var deferredRequests: Set<String> = []
  var metadata: Metadata = .init(version: 1, entries: [:])
  var initializationState: InitializationState = .idle
  var metadataDirty: Bool = false
  var metadataFlushWorkItem: DispatchWorkItem?
  let metadataFlushDelay: TimeInterval = 2.0
  var willTerminateObserver: NSObjectProtocol?

  func image(for path: String) -> NSImage? {
    ensureInitialized()

    guard initializationState == .ready else {
      return nil
    }

    if let cached = inMemoryImages[path] {
      touch(path)
      return cached
    }

    guard let entry = metadata.entries[path] else {
      return nil
    }

    scheduleDiskRead(path: path, entry: entry)
    return nil
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

    guard initializationState == .ready else {
      deferredRequests.insert(path)
      return
    }

    guard inMemoryImages[path] == nil else {
      touch(path)
      return
    }

    if let entry = metadata.entries[path] {
      scheduleDiskRead(path: path, entry: entry)
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

    guard initializationState == .ready else {
      return
    }

    while inFlight.count < maxConcurrentGenerations, !pendingQueue.isEmpty {
      let path = pendingQueue.removeFirst()
      guard visiblePaths.contains(path) else {
        continue
      }
      guard inMemoryImages[path] == nil else {
        touch(path)
        continue
      }

      inFlight.insert(path)
      verifySourceExistsAndGenerate(path: path)
    }
  }

  func prewarm(paths: [String]) {
    ensureInitialized()
    guard initializationState == .ready else {
      deferredRequests.formUnion(paths)
      return
    }
    for path in paths {
      guard inMemoryImages[path] == nil else {
        continue
      }
      if let entry = metadata.entries[path] {
        scheduleDiskRead(path: path, entry: entry)
      }
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

    guard let base = Self.rootDirectoryURL(),
          let dataURL = Self.dataDirectoryURL()
    else {
      return
    }
    ioQueue.async {
      let fileManager = FileManager.default
      do {
        if fileManager.fileExists(atPath: base.path) {
          try fileManager.removeItem(at: base)
        }
        try fileManager.createDirectory(
          at: dataURL,
          withIntermediateDirectories: true
        )
      } catch {
        return
      }
    }

    metadata = .init(version: 1, entries: [:])
    inMemoryImages.removeAll()
    inMemoryLastAccess.removeAll()
    visiblePaths.removeAll()
    pendingQueue.removeAll()
    inFlight.removeAll()
    inFlightReads.removeAll()
    deferredRequests.removeAll()
    persistMetadata()
    flushMetadataIfNeeded()
    bumpRevision()
  }

  deinit {
    if let observer = willTerminateObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  private func scheduleDiskRead(path: String, entry: Entry) {
    guard !inFlightReads.contains(path) else {
      return
    }
    inFlightReads.insert(path)
    guard let fileURL = Self.dataDirectoryURL()?.appendingPathComponent(entry.fileName) else {
      inFlightReads.remove(path)
      return
    }
    ioQueue.async { [weak self] in
      let result = DiskThumbnailCache.loadThumbnailData(
        sourcePath: path,
        entry: entry,
        fileURL: fileURL
      )
      Task { @MainActor in
        guard let self else {
          return
        }
        self.inFlightReads.remove(path)
        guard let current = self.metadata.entries[path],
          current.fileName == entry.fileName
        else {
          return
        }
        switch result {
        case .data(let data):
          guard let image = NSImage(data: data) else {
            self.removeEntry(path)
            return
          }
          self.inMemoryImages[path] = image
          self.touch(path)
          self.trimInMemoryIfNeeded()
          self.bumpRevision()
        case .invalidSource, .missingData:
          self.removeEntry(path)
        }
      }
    }
  }

  private func verifySourceExistsAndGenerate(path: String) {
    ioQueue.async { [weak self] in
      let exists = FileManager.default.fileExists(atPath: path)
      Task { @MainActor in
        guard let self else {
          return
        }
        guard exists else {
          self.inFlight.remove(path)
          self.processQueue()
          return
        }
        self.generate(path: path)
      }
    }
  }
}

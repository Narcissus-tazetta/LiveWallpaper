import AppKit

extension DiskThumbnailCache {
  func ensureInitialized() {
    guard !initialized else {
      return
    }
    initialized = true

    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(
        at: dataDirectoryURL(),
        withIntermediateDirectories: true
      )
    } catch {
      metadata = .init(version: 1, entries: [:])
      return
    }

    let metadataURL = metadataFileURL()
    if let data = try? Data(contentsOf: metadataURL),
      let decoded = try? JSONDecoder().decode(Metadata.self, from: data),
      decoded.version == 1
    {
      metadata = decoded
    } else {
      metadata = .init(version: 1, entries: [:])
      persistMetadata()
      flushMetadataIfNeeded()
    }

    let observer = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.flushMetadataIfNeeded()
      }
    }
    willTerminateObserver = observer
  }
}

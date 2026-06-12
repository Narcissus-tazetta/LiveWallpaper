import AppKit

extension DiskThumbnailCache {
  func ensureInitialized() {
    guard initializationState == .idle else {
      return
    }
    initializationState = .loading

    guard let dataURL = Self.dataDirectoryURL(),
          let metadataURL = Self.metadataFileURL()
    else {
      initializationState = .ready
      bumpRevision()
      return
    }
    ioQueue.async { [weak self] in
      let fileManager = FileManager.default
      var loadedMetadata = Metadata(version: 1, entries: [:])
      var shouldPersist = false

      do {
        try fileManager.createDirectory(
          at: dataURL,
          withIntermediateDirectories: true
        )
      } catch {}

      if let data = try? Data(contentsOf: metadataURL),
        let decoded = try? JSONDecoder().decode(Metadata.self, from: data),
        decoded.version == 1
      {
        loadedMetadata = decoded
      } else {
        shouldPersist = true
      }

      Task { @MainActor in
        guard let self else {
          return
        }
        self.metadata = loadedMetadata
        self.initializationState = .ready
        if self.willTerminateObserver == nil {
          let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
          ) { [weak self] _ in
            MainActor.assumeIsolated {
              self?.flushMetadataImmediately()
            }
          }
          self.willTerminateObserver = observer
        }
        if shouldPersist {
          self.persistMetadata()
          self.flushMetadataIfNeeded()
        }
        let pending = self.deferredRequests
        self.deferredRequests.removeAll()
        for path in pending {
          self.request(path: path)
        }
        self.bumpRevision()
      }
    }
  }
}

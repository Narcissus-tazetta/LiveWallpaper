import AppKit

extension LightweightProxyCache {
    func ensureInitialized() {
        guard initializationState == .idle else {
            return
        }
        initializationState = .loading

        guard let dataURL = Self.dataDirectoryURL(),
              let metadataURL = Self.metadataFileURL()
        else {
            initializationState = .ready
            return
        }

        ioQueue.async { [weak self] in
            let fileManager = FileManager.default
            var loadedMetadata = Metadata(version: Self.metadataVersion, entries: [:])
            var shouldPersist = false

            do {
                try fileManager.createDirectory(at: dataURL, withIntermediateDirectories: true)
            } catch {}

            var shouldWipeDataDirectory = false
            if let data = try? Data(contentsOf: metadataURL),
               let decoded = try? JSONDecoder().decode(Metadata.self, from: data),
               decoded.version == Self.metadataVersion
            {
                loadedMetadata = decoded
            } else {
                shouldPersist = true
                // A version bump means any existing proxy files on disk were
                // produced under a since-changed encoding scheme (e.g. the
                // mis-scaled transform fixed in metadataVersion 2) — they're
                // no longer referenced by the (now-empty) metadata, so remove
                // them outright rather than leaving them as orphaned disk usage.
                shouldWipeDataDirectory = true
            }

            if shouldWipeDataDirectory, let contents = try? fileManager.contentsOfDirectory(atPath: dataURL.path) {
                for item in contents {
                    try? fileManager.removeItem(at: dataURL.appendingPathComponent(item))
                }
            } else if let contents = try? fileManager.contentsOfDirectory(atPath: dataURL.path) {
                // Sweep any staged-but-never-finalized proxy files left behind by a
                // crash or force-quit during a previous export.
                for item in contents where item.hasSuffix(".tmp") {
                    try? fileManager.removeItem(at: dataURL.appendingPathComponent(item))
                }
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
                            self?.cancelActiveGeneration()
                            self?.flushMetadataImmediately()
                        }
                    }
                    self.willTerminateObserver = observer
                }

                if shouldPersist {
                    self.persistMetadata()
                    self.flushMetadataIfNeeded()
                }

                if let pending = self.pendingGenerationRequest {
                    self.pendingGenerationRequest = nil
                    self.generateProxyIfNeeded(for: pending.path, completion: pending.completion)
                }
            }
        }
    }
}

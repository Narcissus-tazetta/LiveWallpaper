import AppKit

extension LightweightProxyCache {
    func touch(_ path: String) {
        guard var entry = metadata.entries[path] else {
            return
        }
        entry.lastAccessAt = Date().timeIntervalSince1970
        metadata.entries[path] = entry
        persistMetadata()
    }

    func recordEntry(
        path: String,
        fileName: String?,
        isPassthrough: Bool,
        fileSize: UInt64,
        modifiedDate: Date
    ) {
        if let previous = metadata.entries[path],
           let previousFileName = previous.fileName,
           previousFileName != fileName,
           let dataURL = dataDirectory
        {
            let staleURL = dataURL.appendingPathComponent(previousFileName)
            ioQueue.async {
                try? FileManager.default.removeItem(at: staleURL)
            }
        }
        metadata.entries[path] = Entry(
            fileName: fileName,
            isPassthrough: isPassthrough,
            sourceSize: fileSize,
            sourceModifiedAt: modifiedDate.timeIntervalSince1970,
            lastAccessAt: Date().timeIntervalSince1970
        )
        persistMetadata()
    }

    func trimDiskIfNeeded() {
        let entries = metadata.entries
        let maxBytes = maxDiskBytes
        guard let dataURL = dataDirectory else {
            return
        }
        ioQueue.async { [weak self] in
            let fileManager = FileManager.default
            var sizedEntries: [SizedEntry] = []
            var totalSize: UInt64 = 0

            for (path, entry) in entries {
                guard let fileName = entry.fileName else {
                    continue
                }
                let fileURL = dataURL.appendingPathComponent(fileName)
                guard let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
                      let size = attrs[.size] as? NSNumber
                else {
                    continue
                }
                let bytes = size.uint64Value
                totalSize += bytes
                sizedEntries.append(SizedEntry(path: path, entry: entry, bytes: bytes))
            }

            guard totalSize > maxBytes else {
                return
            }

            let sorted = sizedEntries.sorted { $0.entry.lastAccessAt < $1.entry.lastAccessAt }
            var overflow = totalSize - maxBytes
            var removed: [(path: String, fileName: String)] = []

            for item in sorted {
                if overflow == 0 {
                    break
                }
                guard let fileName = item.entry.fileName else {
                    continue
                }
                let fileURL = dataURL.appendingPathComponent(fileName)
                try? fileManager.removeItem(at: fileURL)
                removed.append((item.path, fileName))
                overflow = overflow > item.bytes ? overflow - item.bytes : 0
            }

            guard !removed.isEmpty else {
                return
            }

            Task { @MainActor in
                guard let self else {
                    return
                }
                var removedAny = false
                for item in removed {
                    guard let entry = self.metadata.entries[item.path],
                          entry.fileName == item.fileName
                    else {
                        continue
                    }
                    self.metadata.entries.removeValue(forKey: item.path)
                    removedAny = true
                }
                guard removedAny else {
                    return
                }
                self.persistMetadata()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + metadataFlushDelay, execute: workItem)
    }

    func flushMetadataIfNeeded() {
        guard metadataDirty else {
            return
        }
        metadataDirty = false
        metadataFlushWorkItem?.cancel()
        metadataFlushWorkItem = nil

        let snapshot = metadata
        guard let metadataURL = self.metadataURL else {
            return
        }
        ioQueue.async {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: metadataURL, options: .atomic)
            } catch {
                AppLog.proxyCache.error("metadata flush failed error=\(error.localizedDescription, privacy: .public)")
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
        guard let metadataURL = self.metadataURL else {
            return
        }
        ioQueue.sync {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: metadataURL, options: .atomic)
            } catch {
                AppLog.proxyCache.error("metadata flush failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated static func rootDirectoryURL() -> URL? {
        DiskCacheLayout.rootDirectoryURL(subfolder: "LightweightProxyCache")
    }

    nonisolated static func dataDirectoryURL() -> URL? {
        DiskCacheLayout.dataDirectoryURL(subfolder: "LightweightProxyCache")
    }

    nonisolated static func metadataFileURL() -> URL? {
        DiskCacheLayout.metadataFileURL(subfolder: "LightweightProxyCache", metadataFileName: metadataFileName)
    }
}

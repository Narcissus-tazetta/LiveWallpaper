import Foundation

enum StorageUsage {
    /// 2 GiB headroom required in addition to estimated export size.
    static let bakeHeadroomBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// Estimates the bytes needed to encode an HEVC video of the given dimensions and duration.
    static func estimatedBakeBytes(
        width: Int,
        height: Int,
        loopSeconds: Int,
        quality: BakeQuality
    ) -> Int64 {
        let pixels = Double(max(width, 0) * max(height, 0))
        let seconds = Double(max(loopSeconds, 1))
        let factor = max(quality.bytesPerPixelSecond, 0)
        let raw = pixels * seconds * factor
        guard raw.isFinite, raw < Double(Int64.max - bakeHeadroomBytes) else {
            return Int64.max - bakeHeadroomBytes
        }
        return Int64(raw)
    }

    /// Estimates the bytes needed to encode the scene document.
    static func estimatedBakeBytes(
        document: SceneDocument,
        quality: BakeQuality,
        maxEdge: Int = SceneVideoBaker.maxEdge
    ) -> Int64 {
        let (w, h) = SceneRenderer.outputSize(for: document, maxEdge: maxEdge)
        return estimatedBakeBytes(
            width: w,
            height: h,
            loopSeconds: document.loopSeconds,
            quality: quality
        )
    }

    /// Available space on the volume hosting the destination URL.
    static func availableDiskSpace(for destinationURL: URL) -> Int64 {
        let directoryURL = destinationURL.hasDirectoryPath ? destinationURL : destinationURL
            .deletingLastPathComponent()
        if let values = try? directoryURL
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let available = values.volumeAvailableCapacityForImportantUsage
        {
            return available
        }
        if let values = try? directoryURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let available = values.volumeAvailableCapacity
        {
            return Int64(available)
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: directoryURL.path),
           let freeSize = attrs[.systemFreeSize] as? Int64
        {
            return freeSize
        }
        return Int64.max
    }

    /// Checks if there is enough capacity for a planned video bake.
    static func checkBakeCapacity(
        outputURL: URL,
        document: SceneDocument,
        quality: BakeQuality,
        availableDiskSpace: Int64? = nil
    ) -> (isSufficient: Bool, requiredBytes: Int64, availableBytes: Int64) {
        let estimated = estimatedBakeBytes(document: document, quality: quality)
        let required = estimated + bakeHeadroomBytes
        let available = availableDiskSpace ?? self.availableDiskSpace(for: outputURL)
        return (available >= required, required, available)
    }

    // MARK: - Directory Size Breakdown

    struct StorageBreakdown: Equatable {
        var videosBytes: Int64 = 0
        var authorSettingsBackupsBytes: Int64 = 0
        var aerialBackupsBytes: Int64 = 0
        var externalScenesBytes: Int64 = 0
        var thumbnailCacheBytes: Int64 = 0

        var totalBytes: Int64 {
            videosBytes + authorSettingsBackupsBytes + aerialBackupsBytes + externalScenesBytes +
                thumbnailCacheBytes
        }
    }

    static func directoryAllocatedSize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .fileSizeKey,
                .isRegularFileKey
            ],
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .fileSizeKey,
                .isRegularFileKey
            ]),
                values.isRegularFile == true else { continue }
            total +=
                Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values
                    .fileSize ?? 0)
        }
        return total
    }

    static func currentBreakdown() -> StorageBreakdown {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return StorageBreakdown()
        }
        let base = appSupport.appendingPathComponent("LiveWallpaper", isDirectory: true)
        return StorageBreakdown(
            videosBytes: directoryAllocatedSize(at: base.appendingPathComponent(
                "Videos",
                isDirectory: true
            )),
            authorSettingsBackupsBytes: directoryAllocatedSize(at: base.appendingPathComponent(
                "AuthorSettingsBackups",
                isDirectory: true
            )),
            aerialBackupsBytes: directoryAllocatedSize(at: base.appendingPathComponent(
                "AerialBackups",
                isDirectory: true
            )),
            externalScenesBytes: directoryAllocatedSize(at: base.appendingPathComponent(
                "ExternalScenes",
                isDirectory: true
            )),
            thumbnailCacheBytes: directoryAllocatedSize(at: base.appendingPathComponent(
                "ThumbnailCache",
                isDirectory: true
            ))
        )
    }

    // MARK: - Orphan Videos

    struct OrphanVideoItem: Equatable, Identifiable {
        var id: String {
            stem
        }

        let stem: String
        let files: [URL]
        let totalAllocatedBytes: Int64
        let modificationDate: Date
    }

    static func extractVideoStem(from fileName: String) -> String {
        var name = fileName
        if name.hasSuffix(".preview.jpg") {
            name = String(name.dropLast(".preview.jpg".count))
        } else if name.hasSuffix(".preview.png") {
            name = String(name.dropLast(".preview.png".count))
        } else if name.hasSuffix(".preview.jpeg") {
            name = String(name.dropLast(".preview.jpeg".count))
        } else {
            name = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        }
        return name
    }

    /// Finds files in `videosDirectory` that do not correspond to any path in
    /// `referencedVideoPaths`.
    static func findOrphanVideos(
        in videosDirectory: URL,
        referencedVideoPaths: Set<String>,
        protectedText: String = "",
        now: Date = Date(),
        olderThanDays: Int? = nil
    ) -> [OrphanVideoItem] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: videosDirectory.path),
              let contents = try? fm.contentsOfDirectory(
                  at: videosDirectory,
                  includingPropertiesForKeys: [
                      .contentModificationDateKey,
                      .isRegularFileKey,
                      .isDirectoryKey,
                      .totalFileAllocatedSizeKey,
                      .fileAllocatedSizeKey,
                      .fileSizeKey
                  ],
                  options: [.skipsSubdirectoryDescendants]
              )
        else {
            return []
        }

        // Build a normalized set of stems from referencedVideoPaths
        var referencedStems = Set<String>()
        var referencedStandardizedPaths = Set<String>()
        for path in referencedVideoPaths {
            let u = URL(fileURLWithPath: path).standardizedFileURL
            referencedStandardizedPaths.insert(u.path)
            referencedStems.insert(extractVideoStem(from: u.lastPathComponent))
        }

        // Group top-level files/directories by their stem
        var itemsByStem: [String: [URL]] = [:]
        for fileURL in contents {
            let name = fileURL.lastPathComponent
            // Ignore temporary bake/conversion files
            if name.hasPrefix(".") || name.hasPrefix("..") {
                continue
            }
            let stem = extractVideoStem(from: name)
            itemsByStem[stem, default: []].append(fileURL)
        }

        var orphans: [OrphanVideoItem] = []
        for (stem, fileURLs) in itemsByStem {
            // If the stem or any corresponding video file is referenced, it's not an orphan
            if referencedStems.contains(stem) {
                continue
            }
            // A reference kept somewhere the model's own path set does not list (a newer
            // feature's preference key, say) must never cost the user a wallpaper.
            if !protectedText.isEmpty, protectedText.contains(stem) {
                continue
            }
            let matchesReferenced = fileURLs
                .contains { referencedStandardizedPaths.contains($0.standardizedFileURL.path) }
            if matchesReferenced {
                continue
            }

            var totalBytes: Int64 = 0
            var latestDate: Date = .distantPast

            for url in fileURLs {
                let isDirectory = (
                    try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory
                ) ??
                    false
                if isDirectory {
                    totalBytes += directoryAllocatedSize(at: url)
                } else {
                    let values = try? url.resourceValues(forKeys: [
                        .totalFileAllocatedSizeKey,
                        .fileAllocatedSizeKey,
                        .fileSizeKey
                    ])
                    totalBytes +=
                        Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? values?
                            .fileSize ?? 0)
                }
                if let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                {
                    if modDate > latestDate {
                        latestDate = modDate
                    }
                }
            }

            if let olderThanDays {
                let age = now.timeIntervalSince(latestDate)
                guard age >= Double(olderThanDays) * 86400 else {
                    continue
                }
            }

            orphans.append(OrphanVideoItem(
                stem: stem,
                files: fileURLs,
                totalAllocatedBytes: totalBytes,
                modificationDate: latestDate
            ))
        }

        return orphans.sorted { $0.stem < $1.stem }
    }

    /// Deletes the given orphan video items from disk.
    @discardableResult
    static func deleteOrphans(_ orphans: [OrphanVideoItem]) throws -> Int64 {
        let fm = FileManager.default
        var freedBytes: Int64 = 0
        var firstError: Error?
        for orphan in orphans {
            for file in orphan.files where fm.fileExists(atPath: file.path) {
                do {
                    try fm.removeItem(at: file)
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            freedBytes += orphan.totalAllocatedBytes
        }
        if let firstError { throw firstError }
        return freedBytes
    }

    // MARK: - Backups

    struct BackupItem: Equatable, Identifiable {
        var id: String {
            url.lastPathComponent
        }

        let url: URL
        let modificationDate: Date
        let totalAllocatedBytes: Int64
    }

    /// Finds author settings backups not among the newest `keepLatestCount` or within `maxAgeDays`.
    static func findExpiredAuthorSettingsBackups(
        in backupsDirectory: URL,
        keepLatestCount: Int = 3,
        maxAgeDays: Int = 30,
        now: Date = Date()
    ) -> [BackupItem] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupsDirectory.path),
              let subdirs = try? fm.contentsOfDirectory(
                  at: backupsDirectory,
                  includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                  options: [.skipsSubdirectoryDescendants]
              )
        else {
            return []
        }

        var allItems: [BackupItem] = []
        for dir in subdirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let modDate = (try? dir.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let size = directoryAllocatedSize(at: dir)
            allItems.append(BackupItem(
                url: dir,
                modificationDate: modDate,
                totalAllocatedBytes: size
            ))
        }

        // Sort newest first
        allItems.sort { $0.modificationDate > $1.modificationDate }

        // Keep the newest `keepLatestCount`
        let candidates = allItems.dropFirst(keepLatestCount)

        // Expire only those older than maxAgeDays
        let maxAgeSeconds = Double(maxAgeDays) * 86400
        return candidates.filter { now.timeIntervalSince($0.modificationDate) > maxAgeSeconds }
    }

    /// Finds all backups in a given directory (e.g. AerialBackups).
    static func findBackups(in directory: URL) -> [BackupItem] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path),
              let files = try? fm.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [
                      .contentModificationDateKey,
                      .isRegularFileKey,
                      .totalFileAllocatedSizeKey,
                      .fileAllocatedSizeKey,
                      .fileSizeKey
                  ],
                  options: [.skipsSubdirectoryDescendants]
              )
        else {
            return []
        }

        var items: [BackupItem] = []
        for file in files {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else {
                continue
            }
            let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let values = try? file.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .fileSizeKey
            ])
            let size = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? values?
                .fileSize ?? 0)
            items.append(BackupItem(
                url: file,
                modificationDate: modDate,
                totalAllocatedBytes: size
            ))
        }
        return items.sorted { $0.modificationDate > $1.modificationDate }
    }

    /// Deletes the given backup items from disk.
    @discardableResult
    static func deleteBackups(_ backups: [BackupItem]) throws -> Int64 {
        let fm = FileManager.default
        var freedBytes: Int64 = 0
        var firstError: Error?
        for backup in backups where fm.fileExists(atPath: backup.url.path) {
            do {
                try fm.removeItem(at: backup.url)
                freedBytes += backup.totalAllocatedBytes
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        return freedBytes
    }
}

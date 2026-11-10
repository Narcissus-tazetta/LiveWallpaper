import AppKit
import AVFoundation
import CryptoKit
import Foundation

/// Only `importPackage` touches the model and is main-actor bound; everything else is file
/// work that runs on a background queue. Unchecked because FileManager is not marked
/// Sendable, though Apple documents it as safe to call from any thread; all stored
/// properties are immutable.
final class PackageImporter: @unchecked Sendable {
    enum DuplicateResolution {
        case abort
        case replace
    }

    enum ImportError: LocalizedError {
        case invalidPackageFormat
        case missingMetadata
        case invalidMetadataJSON(String)
        case unsupportedPackageVersion
        case duplicateVideo(String)
        case videoNotFound(String)
        case corruptedVideoFile(String)
        case invalidChecksum(String)
        case extractionFailed
        case unsafeFileReference(String)
        case packageTooLarge(Int64, max: Int64)
        case extractedSizeTooLarge(Int64, max: Int64)
        case metadataTooLarge(Int64, max: Int64)
        case excessiveEntryCount(Int, max: Int)
        case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)

        var errorDescription: String? {
            switch self {
            case .invalidPackageFormat:
                return NSLocalizedString("不正なパッケージ形式です", comment: "")
            case .missingMetadata:
                return NSLocalizedString("metadata.jsonが見つかりません", comment: "")
            case let .invalidMetadataJSON(details):
                return String(
                    format: NSLocalizedString("metadata.jsonが破損しています: %@", comment: ""),
                    details
                )
            case .unsupportedPackageVersion:
                return NSLocalizedString("サポートされていないパッケージバージョンです", comment: "")
            case let .duplicateVideo(name):
                return String(format: NSLocalizedString("重複するビデオが既に存在します: %@", comment: ""), name)
            case let .videoNotFound(name):
                return String(format: NSLocalizedString("ビデオファイルが見つかりません: %@", comment: ""), name)
            case let .corruptedVideoFile(name):
                return String(format: NSLocalizedString("ビデオファイルが破損しています: %@", comment: ""), name)
            case let .invalidChecksum(name):
                return String(
                    format: NSLocalizedString("ビデオファイルのチェックサムが一致しません: %@", comment: ""),
                    name
                )
            case .extractionFailed:
                return NSLocalizedString("パッケージの展開に失敗しました", comment: "")
            case let .unsafeFileReference(name):
                return String(format: NSLocalizedString("不正なファイル参照が含まれています: %@", comment: ""), name)
            case let .packageTooLarge(size, max):
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                let sizeText = formatter.string(fromByteCount: size)
                let maxText = formatter.string(fromByteCount: max)
                let template = NSLocalizedString("パッケージのサイズが大きすぎます(%@ / 上限%@)", comment: "")
                return String(format: template, sizeText, maxText)
            case let .extractedSizeTooLarge(size, max):
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                let sizeText = formatter.string(fromByteCount: size)
                let maxText = formatter.string(fromByteCount: max)
                let template = NSLocalizedString("展開後のサイズが大きすぎます(%@ / 上限%@)", comment: "")
                return String(format: template, sizeText, maxText)
            case let .metadataTooLarge(size, max):
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                let sizeText = formatter.string(fromByteCount: size)
                let maxText = formatter.string(fromByteCount: max)
                let template = NSLocalizedString("マニフェストのサイズが大きすぎます(%@ / 上限%@)", comment: "")
                return String(format: template, sizeText, maxText)
            case let .insufficientDiskSpace(required, available):
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                let template = NSLocalizedString(
                    "空き容量が不足しているため、パッケージを展開できません(必要: %@、空き: %@)",
                    comment: ""
                )
                return String(
                    format: template,
                    formatter.string(fromByteCount: required),
                    formatter.string(fromByteCount: available)
                )
            case let .excessiveEntryCount(count, max):
                let template = NSLocalizedString("パッケージ内のファイル数が多すぎます(%d / 上限%d)", comment: "")
                return String(format: template, count, max)
            }
        }
    }

    struct Limits: Equatable {
        var maximumPackageFileBytes: Int64
        var maximumExtractedBytes: Int64
        var maximumEntryCount: Int
        var maximumMetadataBytes: Int64

        /// Packages the user exports themselves are not size-capped by the exporter
        /// (a maximum-quality 4K scene video alone is several GB), so the cap only has
        /// to stop archives that could never fit on disk.
        static let local = Limits(
            maximumPackageFileBytes: 16 * 1024 * 1024 * 1024,
            maximumExtractedBytes: 32 * 1024 * 1024 * 1024,
            maximumEntryCount: 20000,
            maximumMetadataBytes: 10 * 1024 * 1024
        )

        /// Store packages are capped at upload time, so anything bigger is not from the Store.
        static let store = Limits(
            maximumPackageFileBytes: 500 * 1024 * 1024,
            maximumExtractedBytes: 2 * 1024 * 1024 * 1024,
            maximumEntryCount: 1000,
            maximumMetadataBytes: 10 * 1024 * 1024
        )
    }

    /// Free space that must remain after extraction, so a large import cannot fill the disk.
    static let extractionHeadroomBytes: Int64 = 2 * 1024 * 1024 * 1024

    private let fileManager: FileManager
    private let videosDirectory: URL?
    private let webWallpapersDirectory: URL
    private let scenePresetStore: ScenePresetStore?
    private let limits: Limits

    init(
        fileManager: FileManager = .default,
        videosDirectory: URL? = nil,
        webWallpapersDirectory: URL = LocalWebWallpaperPackage.libraryDirectory,
        scenePresetStore: ScenePresetStore? = .standard,
        limits: Limits = .local
    ) {
        self.fileManager = fileManager
        self.videosDirectory = videosDirectory
        self.webWallpapersDirectory = webWallpapersDirectory
        self.scenePresetStore = scenePresetStore
        self.limits = limits
    }

    @MainActor
    func importPackage(
        from packageURL: URL,
        into model: WallpaperModel,
        duplicateResolution: DuplicateResolution = .abort
    ) async throws {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { BlockingWork.removeInBackground(tempDir) }

        // One import at a time: the duplicate checks and destination names assume nothing
        // else is writing into the library folder meanwhile.
        let staged = try await BlockingWork.run(on: Self.stagingQueue) { [self] in
            try stageFiles(from: packageURL, in: tempDir, duplicateResolution: duplicateResolution)
        }
        let manifest = staged.manifest
        let importedVideoPaths = staged.importedVideoPaths

        // 全ファイルが正常に配置できた後にだけモデルを更新する。
        // 後半のビデオで失敗した際に、ライブラリが半分だけ増えない。
        for video in manifest.videos {
            if let videoPath = importedVideoPaths[video.id] {
                model.addVideoPathToLibrary(videoPath)

                for (screenId, pres) in video.presentations {
                    let fitMode = VideoFitMode(rawValue: pres.fitMode) ?? .fill
                    model.setWallpaperPresentation(
                        fitMode: fitMode,
                        zoom: pres.zoom,
                        offsetX: pres.offsetX,
                        offsetY: pres.offsetY,
                        path: videoPath,
                        screenID: screenId
                    )
                }

                if let edit = video.edit {
                    // パッケージは他人の環境で作られたものであり得るため、取り込んだ
                    // ファイルの実尺で検証・クランプする。trimEnd が実尺をはみ出した
                    // まま保存されると AVPlayerLooper が .failed になり、その壁紙が
                    // 一切再生されなくなる(WallpaperLoopBuilder.makeLooper 参照)。
                    let assetDuration = await Self.assetDurationSeconds(path: videoPath)
                    let trimEnd = Self.loopSafeTrimEnd(
                        edit.trimEnd,
                        assetDuration: assetDuration
                    )
                    let loopStart = Self.loopSafeLoopStart(
                        edit.loopStart,
                        trimStart: edit.trimStart,
                        trimEnd: trimEnd
                    )
                    let metadata = WallpaperEditMetadata(
                        trimStart: edit.trimStart,
                        trimEnd: trimEnd,
                        loopStart: loopStart
                    )
                    if metadata.isValid(assetDuration: assetDuration) {
                        model.setWallpaperEdit(
                            trimStart: edit.trimStart,
                            trimEnd: trimEnd,
                            loopStart: loopStart,
                            path: videoPath
                        )
                    } else {
                        AppLog.persistence.error(
                            "skipped invalid edit metadata for imported video id=\(video.id, privacy: .public)"
                        )
                    }
                }
            }
        }

        for video in manifest.videos {
            if let videoPath = importedVideoPaths[video.id], let effects = video.cursorEffects {
                model.setCursorEffectsOverride(effects, path: videoPath)
            }
        }

        // Stays on the main actor: a replaced video's scene folder is also written by the
        // model's debounced scene saves, which run here too.
        for scene in Self.importSceneFiles(
            of: manifest,
            importedVideoPaths: importedVideoPaths,
            packageRoot: staged.packageRoot
        ) {
            model.registerImportedScene(scene.document, path: scene.videoPath, asksAgain: true)
        }

        let webIDs = addWebWallpapers(of: manifest, staged: staged, to: model)
        model.addImportedScenePresets(staged.scenePresets)
        let importedPlaylistIDs = addPlaylists(
            of: manifest,
            importedVideoPaths: importedVideoPaths,
            webIDs: webIDs,
            to: model
        )

        if let firstPlaylistID = importedPlaylistIDs.first {
            model.selectPlaylist(firstPlaylistID)
        }

        for video in manifest.videos {
            if let importedPath = importedVideoPaths[video.id] {
                model.setRegisteredVideoDisplayName(video.displayName, for: importedPath)
            }
        }

        if let firstVideoId = manifest.videos.first?.id,
           let videoPath = importedVideoPaths[firstVideoId]
        {
            model.selectRegisteredVideo(path: videoPath)
        } else if let firstWeb = manifest.webWallpapers?.first, let id = webIDs[firstWeb.id] {
            model.selectWebWallpaper(id: id)
        }
    }

    /// - Returns: package web wallpaper id → id in the receiver's library.
    @MainActor
    private func addWebWallpapers(
        of manifest: PackageManifest,
        staged: StagedImport,
        to model: WallpaperModel
    ) -> [String: UUID] {
        var webIDs: [String: UUID] = [:]
        for web in manifest.webWallpapers ?? [] {
            guard let item = staged.webSources[web.id] else { continue }
            let id = model.addImportedWebWallpaper(item.source)
            webIDs[web.id] = id
            // A page already in the library keeps the receiver's own settings.
            guard let settings = item.settings, id == item.source.id else { continue }
            do {
                try settings.save(id: id)
            } catch {
                AppLog.persistence.error(
                    "imported web settings not saved: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return webIDs
    }

    @MainActor
    private func addPlaylists(
        of manifest: PackageManifest,
        importedVideoPaths: [String: String],
        webIDs: [String: UUID],
        to model: WallpaperModel
    ) -> [UUID] {
        var importedPlaylistIDs: [UUID] = []
        for playlist in manifest.playlists {
            let videoPaths = playlist.videoIds.compactMap { importedVideoPaths[$0] }
            let webWallpaperIDs = (playlist.webWallpaperIds ?? []).compactMap { webIDs[$0] }
            guard !videoPaths.isEmpty || !webWallpaperIDs.isEmpty,
                  let playlistID = model.createPlaylist(named: playlist.name)
            else { continue }
            for videoPath in videoPaths {
                model.addRegisteredVideo(path: videoPath, to: playlistID)
            }
            for webID in webWallpaperIDs {
                _ = model.addWebWallpaper(sourceID: webID, to: playlistID)
            }
            importedPlaylistIDs.append(playlistID)
        }
        return importedPlaylistIDs
    }

    private static let stagingQueue = DispatchQueue(
        label: "LiveWallpaper.packageImport",
        qos: .userInitiated
    )

    private struct StagedImport {
        let manifest: PackageManifest
        let packageRoot: URL
        /// Package video id → library path the video now lives at.
        let importedVideoPaths: [String: String]
        /// Package web wallpaper id → the source to add, already copied into the library.
        let webSources: [String: StagedWebWallpaper]
        let scenePresets: [ScenePreset]
    }

    struct StagedWebWallpaper {
        let source: WebWallpaperSource
        let settings: LocalWebSettings?
    }

    /// Unpacks, validates and copies the videos into the library. Only touches files, so it
    /// runs off the main actor; the model is updated afterwards from the result.
    private func stageFiles(
        from packageURL: URL,
        in tempDir: URL,
        duplicateResolution: DuplicateResolution
    ) throws -> StagedImport {
        let inspection = try Self.inspectZipArchive(at: packageURL, limits: limits)
        let availableBytes = StorageUsage.availableDiskSpace(for: tempDir)
        guard inspection.totalUncompressedBytes + Self.extractionHeadroomBytes <= availableBytes
        else {
            throw ImportError.insufficientDiskSpace(
                requiredBytes: inspection.totalUncompressedBytes + Self.extractionHeadroomBytes,
                availableBytes: availableBytes
            )
        }
        try Self.extractPackage(from: packageURL, to: tempDir)
        if let enumerator = fileManager.enumerator(
            at: tempDir,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) {
            while let fileURL = enumerator.nextObject() as? URL {
                let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    throw ImportError.unsafeFileReference(fileURL.lastPathComponent)
                }
            }
        }
        let extractedSize = StorageUsage.directoryAllocatedSize(at: tempDir)
        guard extractedSize <= limits.maximumExtractedBytes else {
            throw ImportError.extractedSizeTooLarge(
                extractedSize,
                max: limits.maximumExtractedBytes
            )
        }
        let (manifest, packageRootDir) = try loadManifest(from: tempDir)
        try validateManifest(manifest)
        // Hashing every library video is the slow part of a duplicate check; each file is
        // hashed at most once per import.
        var libraryDigests: [String: String] = [:]
        try preflightVideos(
            manifest.videos, from: packageRootDir, duplicateResolution: duplicateResolution,
            libraryDigests: &libraryDigests
        )

        var importedVideoPaths: [String: String] = [:]
        // Must not fall back to an empty set: rollback deletes every imported path not in it,
        // and a package that points at an already-present video imports that path.
        // Spelled like the paths importVideo returns (see findExistingVideoPath).
        let videosDirectory = try appSupportVideosDir()
        let existingFilesBeforeImport = try Set(
            fileManager.contentsOfDirectory(at: videosDirectory, includingPropertiesForKeys: nil)
                .map { videosDirectory.appendingPathComponent($0.lastPathComponent).path }
        )
        let rollbackDirectory = tempDir.appendingPathComponent("rollback", isDirectory: true)
        try fileManager.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)
        var replacementBackups: [String: URL] = [:]
        var webSources: [String: StagedWebWallpaper] = [:]
        var scenePresets: [ScenePreset] = []

        do {
            for video in manifest.videos {
                if case .replace = duplicateResolution,
                   let existingPath = try findExistingVideoPath(
                       for: video,
                       libraryDigests: &libraryDigests
                   ),
                   replacementBackups[existingPath] == nil
                {
                    let backupURL = rollbackDirectory.appendingPathComponent(UUID().uuidString)
                    try fileManager.copyItem(atPath: existingPath, toPath: backupURL.path)
                    replacementBackups[existingPath] = backupURL
                }
                if let videoPath = try importVideo(
                    video,
                    from: packageRootDir,
                    duplicateResolution: duplicateResolution,
                    libraryDigests: &libraryDigests
                ) {
                    importedVideoPaths[video.id] = videoPath
                }
            }
            try stageWebWallpapers(
                manifest.webWallpapers ?? [],
                from: packageRootDir,
                into: &webSources
            )
            try stageScenePresets(
                manifest.scenePresets ?? [],
                from: packageRootDir,
                into: &scenePresets
            )
        } catch {
            removeStaged(webSources: webSources.values, scenePresets: scenePresets)
            for path in importedVideoPaths.values where !existingFilesBeforeImport.contains(path) {
                do {
                    try fileManager.removeItem(atPath: path)
                } catch {
                    AppLog.persistence.error(
                        "import rollback could not remove \(path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            for (path, backupURL) in replacementBackups {
                let targetURL = URL(fileURLWithPath: path)
                let stagedURL = targetURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString).rollback")
                do {
                    try fileManager.copyItem(at: backupURL, to: stagedURL)
                    _ = try fileManager.replaceItemAt(targetURL, withItemAt: stagedURL)
                } catch {
                    AppLog.persistence.error(
                        "import rollback could not restore \(path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    try? fileManager.removeItem(at: stagedURL)
                }
            }
            throw error
        }
        return StagedImport(
            manifest: manifest, packageRoot: packageRootDir, importedVideoPaths: importedVideoPaths,
            webSources: webSources, scenePresets: scenePresets
        )
    }

    private struct ImportedScene {
        let document: SceneDocument
        let videoPath: String
    }

    /// A broken scene leaves the baked video as a plain wallpaper rather than failing
    /// the import. video.id was checked by validatedVideoURL.
    private static func importSceneFiles(
        of manifest: PackageManifest,
        importedVideoPaths: [String: String],
        packageRoot: URL
    ) -> [ImportedScene] {
        var scenes: [ImportedScene] = []
        for video in manifest.videos where video.scene == true || video.scriptScene != nil {
            guard let videoPath = importedVideoPaths[video.id] else {
                continue
            }
            let source = packageRoot.appendingPathComponent("scenes", isDirectory: true)
                .appendingPathComponent(video.id, isDirectory: true)
            do {
                let document = try SceneStore.importScene(from: source, videoPath: videoPath)
                scenes.append(ImportedScene(document: document, videoPath: videoPath))
            } catch {
                AppLog.persistence.error(
                    "skipped scene of imported video id=\(video.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return scenes
    }

    struct ZipArchiveInspection {
        let totalEntries: Int
        let totalUncompressedBytes: Int64
    }

    @discardableResult
    static func inspectZipArchive(
        at fileURL: URL,
        limits: Limits = .local
    ) throws -> ZipArchiveInspection {
        let archiveSize = try Int64(fileURL.regularFileSize())
        guard archiveSize <= limits.maximumPackageFileBytes else {
            throw ImportError.packageTooLarge(archiveSize, max: limits.maximumPackageFileBytes)
        }
        guard archiveSize >= 22 else {
            throw ImportError.invalidPackageFormat
        }

        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        let searchSize = min(UInt64(archiveSize), 65535 + 22)
        try fileHandle.seek(toOffset: UInt64(archiveSize) - searchSize)
        guard let tailData = try fileHandle.readToEnd() else {
            throw ImportError.invalidPackageFormat
        }

        let eocdOffsetInTail = try zipEndOffset(in: tailData)

        let eocd = tailData.subdata(in: eocdOffsetInTail ..< tailData.count)
        guard eocd.count >= 22 else { throw ImportError.invalidPackageFormat }

        let (cdData, totalEntries) = try readZipDirectory(
            fileHandle: fileHandle, archiveSize: UInt64(archiveSize), eocd: eocd,
            eocdOffset: UInt64(archiveSize) - searchSize + UInt64(eocdOffsetInTail),
            limits: limits
        )

        var offset = 0
        var totalUncompressed: Int64 = 0

        for _ in 0 ..< totalEntries {
            guard offset + 46 <= cdData.count else { throw ImportError.invalidPackageFormat }
            let headerSig = readUInt32(from: cdData, at: offset)
            guard headerSig == 0x0201_4B50 else { throw ImportError.invalidPackageFormat }

            let legacySize = readUInt32(from: cdData, at: offset + 24)
            let filenameLen = Int(readUInt16(from: cdData, at: offset + 28))
            let extraLen = Int(readUInt16(from: cdData, at: offset + 30))
            let commentLen = Int(readUInt16(from: cdData, at: offset + 32))
            let externalAttr = readUInt32(from: cdData, at: offset + 38)

            let unixMode = (externalAttr >> 16) & 0o170000
            if unixMode == 0o120000 {
                throw ImportError.unsafeFileReference("symlink")
            }

            let nameStart = offset + 46
            let extraStart = nameStart + filenameLen
            let entryEnd = extraStart + extraLen + commentLen
            guard entryEnd <= cdData.count else { throw ImportError.invalidPackageFormat }
            let uncompressedSize = try zipUncompressedSize(
                legacySize: legacySize,
                extra: cdData.subdata(in: extraStart ..< extraStart + extraLen)
            )
            let nameData = cdData
                .subdata(in: (cdData.startIndex + nameStart) ..<
                    (cdData.startIndex + nameStart + filenameLen))
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw ImportError.invalidPackageFormat
            }

            if name.split(separator: "/").contains("..") || name.hasPrefix("/") || name
                .contains("\\") || name.contains("\0")
            {
                throw ImportError.unsafeFileReference(name)
            }

            guard uncompressedSize <= UInt64(limits.maximumExtractedBytes - totalUncompressed)
            else {
                let total = totalUncompressed
                    .addingReportingOverflow(Int64(clamping: uncompressedSize))
                throw ImportError.extractedSizeTooLarge(
                    total.overflow ? Int64.max : total.partialValue,
                    max: limits.maximumExtractedBytes
                )
            }
            totalUncompressed += Int64(uncompressedSize)
            offset = entryEnd
        }

        guard offset == cdData.count else {
            throw ImportError.invalidPackageFormat
        }

        return ZipArchiveInspection(
            totalEntries: totalEntries,
            totalUncompressedBytes: totalUncompressed
        )
    }

    private static func zipEndOffset(in tail: Data) throws -> Int {
        guard tail.count >= 22 else { throw ImportError.invalidPackageFormat }
        for offset in stride(from: tail.count - 22, through: 0, by: -1) {
            if readUInt32(from: tail, at: offset) == 0x0605_4B50,
               offset + 22 + Int(readUInt16(from: tail, at: offset + 20)) == tail.count
            {
                return offset
            }
        }
        throw ImportError.invalidPackageFormat
    }

    private static func readZipDirectory(
        fileHandle: FileHandle,
        archiveSize: UInt64,
        eocd: Data,
        eocdOffset: UInt64,
        limits: Limits
    ) throws -> (Data, Int) {
        func read(at offset: UInt64, count: Int) throws -> Data {
            guard offset <= archiveSize, UInt64(count) <= archiveSize - offset else {
                throw ImportError.invalidPackageFormat
            }
            try fileHandle.seek(toOffset: offset)
            guard let data = try fileHandle.read(upToCount: count), data.count == count else {
                throw ImportError.invalidPackageFormat
            }
            return data
        }
        guard readUInt16(from: eocd, at: 4) == 0, readUInt16(from: eocd, at: 6) == 0,
              readUInt16(from: eocd, at: 8) == readUInt16(from: eocd, at: 10)
        else { throw ImportError.invalidPackageFormat }
        var count = UInt64(readUInt16(from: eocd, at: 10))
        var size = UInt64(readUInt32(from: eocd, at: 12))
        var offset = UInt64(readUInt32(from: eocd, at: 16))
        if count == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
            guard eocdOffset >= 20 else { throw ImportError.invalidPackageFormat }
            let locator = try read(at: eocdOffset - 20, count: 20)
            guard readUInt32(from: locator, at: 0) == 0x0706_4B50,
                  readUInt32(from: locator, at: 4) == 0,
                  readUInt32(from: locator, at: 16) == 1
            else { throw ImportError.invalidPackageFormat }
            let record = try read(at: readUInt64(from: locator, at: 8), count: 56)
            guard readUInt32(from: record, at: 0) == 0x0606_4B50,
                  readUInt64(from: record, at: 4) >= 44,
                  readUInt32(from: record, at: 16) == 0,
                  readUInt32(from: record, at: 20) == 0,
                  readUInt64(from: record, at: 24) == readUInt64(from: record, at: 32)
            else { throw ImportError.invalidPackageFormat }
            count = readUInt64(from: record, at: 32)
            size = readUInt64(from: record, at: 40)
            offset = readUInt64(from: record, at: 48)
        }
        guard count <= UInt64(limits.maximumEntryCount) else {
            throw ImportError.excessiveEntryCount(
                Int(clamping: count),
                max: limits.maximumEntryCount
            )
        }
        // The exporter uses short generated names; a giant directory must not size an allocation.
        guard size <= 32 * 1024 * 1024 else { throw ImportError.invalidPackageFormat }
        return try (read(at: offset, count: Int(size)), Int(count))
    }

    private static func zipUncompressedSize(legacySize: UInt32, extra: Data) throws -> UInt64 {
        guard legacySize == UInt32.max else { return UInt64(legacySize) }
        var offset = 0
        while offset + 4 <= extra.count {
            let tag = readUInt16(from: extra, at: offset)
            let length = Int(readUInt16(from: extra, at: offset + 2))
            let start = offset + 4
            guard length <= extra.count - start else { throw ImportError.invalidPackageFormat }
            if tag == 1 {
                guard length >= 8 else { throw ImportError.invalidPackageFormat }
                return readUInt64(from: extra, at: start)
            }
            offset = start + length
        }
        throw ImportError.invalidPackageFormat
    }

    private static func readUInt64(from data: Data, at offset: Int) -> UInt64 {
        UInt64(readUInt32(from: data, at: offset))
            | (UInt64(readUInt32(from: data, at: offset + 4)) << 32)
    }

    private static func readUInt16(from data: Data, at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let idx = data.startIndex + offset
        return UInt16(data[idx]) | (UInt16(data[idx + 1]) << 8)
    }

    private static func readUInt32(from data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let idx = data.startIndex + offset
        let b0 = UInt32(data[idx])
        let b1 = UInt32(data[idx + 1]) << 8
        let b2 = UInt32(data[idx + 2]) << 16
        let b3 = UInt32(data[idx + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    private static func extractPackage(from packageURL: URL, to targetDir: URL) throws {
        do {
            try ProcessRunner.runSynchronously(
                "/usr/bin/unzip", arguments: ["-q", packageURL.path, "-d", targetDir.path]
            )
        } catch let failure as ProcessRunner.Failure {
            AppLog.persistence.error(
                "package extraction failed: \(failure.localizedDescription, privacy: .public)"
            )
            throw ImportError.extractionFailed
        }
    }

    private func loadManifest(from tempDir: URL) throws -> (PackageManifest, URL) {
        let directMetadataURL = tempDir.appendingPathComponent("metadata.json")
        let contentMetadataURL = tempDir.appendingPathComponent("content/metadata.json")

        let metadataURL: URL
        let packageRootDir: URL

        if fileManager.fileExists(atPath: directMetadataURL.path) {
            metadataURL = directMetadataURL
            packageRootDir = tempDir
        } else if fileManager.fileExists(atPath: contentMetadataURL.path) {
            metadataURL = contentMetadataURL
            packageRootDir = tempDir.appendingPathComponent("content")
        } else {
            throw ImportError.missingMetadata
        }

        let metadataSize = try Int64(metadataURL.regularFileSize())
        guard metadataSize <= limits.maximumMetadataBytes else {
            throw ImportError.metadataTooLarge(metadataSize, max: limits.maximumMetadataBytes)
        }

        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()

        do {
            return try (decoder.decode(PackageManifest.self, from: data), packageRootDir)
        } catch {
            throw ImportError.invalidMetadataJSON(error.localizedDescription)
        }
    }

    static let supportedVersions: Set<String> = ["1.0", "1.1", "1.2"]

    func validateManifest(_ manifest: PackageManifest) throws {
        guard Self.supportedVersions.contains(manifest.version) else {
            throw ImportError.unsupportedPackageVersion
        }
    }

    /// 取り込んだ動画ファイルの実尺(読めなければ nil)。
    static func assetDurationSeconds(path: String) async -> Double? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let duration = try? await asset.load(.duration) else {
            return nil
        }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// パッケージ由来の trimEnd を、ローカルの実尺の内側へ収める。尺が読めなければ
    /// そのまま通す(その場合の最終防衛線は `WallpaperLoopBuilder.makeLooper` の
    /// 全体ループへのフォールバック)。
    static func loopSafeTrimEnd(_ trimEnd: Double?, assetDuration: Double?) -> Double? {
        guard let trimEnd, let assetDuration else {
            return trimEnd
        }
        return min(trimEnd, assetDuration - WallpaperLoopBuilder.loopEndGuard)
    }

    /// パッケージ由来のループ開始位置を、クランプ後のカット範囲の内側に収める。
    /// 収まらなければ捨てる(= 途中ループなし)。半端な位置へ丸めるより、他人の
    /// 環境で決めた演出を落とす方が事故が少ない。
    static func loopSafeLoopStart(
        _ loopStart: Double?,
        trimStart: Double,
        trimEnd: Double?
    ) -> Double? {
        guard let loopStart, loopStart > trimStart else {
            return nil
        }
        guard let trimEnd else {
            return loopStart
        }
        return loopStart < trimEnd ? loopStart : nil
    }

    /// パッケージの metadata.json はパッケージ製作者(第三者)が自由に書ける値なので、
    /// video.id や source.fileName をそのままファイルパス構築に使うとパストラバーサル
    /// (例: "../../Library/LaunchAgents/evil.plist")の入力になり得る。単一のファイル名
    /// 構成要素として妥当な値だけを許可する。
    private static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("\0")
    }

    private func validatedVideoURL(
        _ video: PackageManifest.PackageVideo,
        from packageRoot: URL
    ) throws -> URL {
        let sourceFileName = video.source.fileName
        guard Self.isSafePathComponent(video.id) else {
            throw ImportError.unsafeFileReference(video.id)
        }
        guard Self.isSafePathComponent(sourceFileName) else {
            throw ImportError.unsafeFileReference(sourceFileName)
        }
        let videosDir = packageRoot.appendingPathComponent("videos", isDirectory: true)
        let videoURL = videosDir.appendingPathComponent("\(video.id).mp4")
        let resolvedRoot = packageRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedVideo = videoURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedVideo.hasPrefix(resolvedRoot + "/") else {
            throw ImportError.unsafeFileReference(sourceFileName)
        }
        guard fileManager.fileExists(atPath: videoURL.path) else {
            throw ImportError.videoNotFound(sourceFileName)
        }
        let values = try videoURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ImportError.unsafeFileReference(sourceFileName)
        }
        return videoURL
    }

    private func preflightVideos(
        _ videos: [PackageManifest.PackageVideo],
        from packageRoot: URL,
        duplicateResolution: DuplicateResolution,
        libraryDigests: inout [String: String]
    ) throws {
        var ids = Set<String>()
        for video in videos {
            guard ids.insert(video.id).inserted else {
                throw ImportError.invalidPackageFormat
            }
            let videosDir = packageRoot.appendingPathComponent("videos", isDirectory: true)
            if !fileManager.fileExists(atPath: videosDir.path) {
                guard try findExistingVideoPath(for: video, libraryDigests: &libraryDigests) != nil
                else {
                    throw ImportError.videoNotFound(video.source.fileName)
                }
                continue
            }
            let videoURL = try validatedVideoURL(video, from: packageRoot)
            let attrs = try fileManager.attributesOfItem(atPath: videoURL.path)
            let size = attrs[.size] as? UInt64 ?? 0
            if let expected = video.source.size, expected > 0, size != expected {
                throw ImportError.corruptedVideoFile(video.source.fileName)
            }
            if let expected = video.sha256,
               try !Self.digestsMatch(computeSHA256(for: videoURL.path), expected)
            {
                throw ImportError.invalidChecksum(video.source.fileName)
            }
            if case .abort = duplicateResolution,
               try findExistingVideoPath(for: video, libraryDigests: &libraryDigests) != nil
            {
                throw ImportError.duplicateVideo(video.displayName)
            }
        }
    }

    // MARK: - Web wallpapers and presets

    private func stageWebWallpapers(
        _ webWallpapers: [PackageManifest.PackageWebWallpaper],
        from packageRoot: URL,
        into staged: inout [String: StagedWebWallpaper]
    ) throws {
        for web in webWallpapers {
            guard Self.isSafePathComponent(web.id), staged[web.id] == nil else {
                throw ImportError.invalidPackageFormat
            }
            if let folder = web.folder {
                let source = try validatedPackageFolder(folder, kind: "web", in: packageRoot)
                let destination = webWallpapersDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try LocalWebWallpaperPackage.copy(from: source, to: destination)
                let package = try LocalWebWallpaperPackage.load(folder: destination)
                let settings = web.settings.map { $0.portable(for: package) }
                staged[web.id] = StagedWebWallpaper(
                    source: WebWallpaperSource(
                        url: destination.appendingPathComponent(package.entryPoint),
                        displayName: web.displayName,
                        localFolderPath: destination.path,
                        warnings: package.warnings,
                        thumbnailPath: package.preview
                            .map { destination.appendingPathComponent($0).path }
                    ),
                    settings: settings
                )
            } else if let urlString = web.url {
                let url = try WebWallpaperURLResolver.normalizeURLString(urlString)
                guard url.scheme == "https" || url.scheme == "http" else {
                    throw ImportError.unsafeFileReference(urlString)
                }
                staged[web.id] = StagedWebWallpaper(
                    source: WebWallpaperSource(url: url, displayName: web.displayName),
                    settings: nil
                )
            } else {
                throw ImportError.invalidPackageFormat
            }
        }
    }

    private func stageScenePresets(
        _ presets: [PackageManifest.PackageScenePreset],
        from packageRoot: URL,
        into staged: inout [ScenePreset]
    ) throws {
        guard !presets.isEmpty else { return }
        guard let scenePresetStore else { throw ImportError.extractionFailed }
        for item in presets {
            let folder = try validatedPackageFolder(item.folder, kind: "presets", in: packageRoot)
            let documentURL = folder.appendingPathComponent("preset.json")
            let prepared = try StoredFormat.scenePreset.prepare(Data(contentsOf: documentURL))
            var preset = try JSONDecoder().decode(ScenePreset.self, from: prepared.data)
            for name in preset.referencedFiles where !Self.isSafePathComponent(name) {
                throw ImportError.unsafeFileReference(name)
            }
            // A fresh id: the receiver may already hold this preset, and ids name folders.
            preset.id = UUID()
            preset.builtIn = nil
            try scenePresetStore.save(preset, filesFrom: folder)
            staged.append(preset)
        }
    }

    /// `folder` comes from the package author, so it must be exactly `<kind>/<one name>`
    /// and resolve inside the package.
    private func validatedPackageFolder(
        _ folder: String,
        kind: String,
        in packageRoot: URL
    ) throws -> URL {
        let parts = folder.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == kind, Self.isSafePathComponent(String(parts[1]))
        else {
            throw ImportError.unsafeFileReference(folder)
        }
        let url = packageRoot.appendingPathComponent(kind, isDirectory: true)
            .appendingPathComponent(String(parts[1]), isDirectory: true)
        let resolvedRoot = packageRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard resolved.hasPrefix(resolvedRoot + "/"),
              fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ImportError.unsafeFileReference(folder)
        }
        return url
    }

    private func removeStaged(
        webSources: some Sequence<StagedWebWallpaper>,
        scenePresets: [ScenePreset]
    ) {
        for web in webSources {
            guard let folder = web.source.localFolderPath else { continue }
            do {
                try fileManager.removeItem(atPath: folder)
            } catch {
                AppLog.persistence.error(
                    "import rollback could not remove \(folder, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        for preset in scenePresets {
            do {
                try scenePresetStore?.delete(preset.id)
            } catch {
                AppLog.persistence.error(
                    "import rollback could not remove preset \(preset.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    // MARK: - Preview

    struct Preview {
        let manifest: PackageManifest
        let thumbnail: NSImage?
        let packageBytes: Int64
    }

    /// Reads only the manifest and thumbnails, so the user can decide before the whole
    /// package (possibly gigabytes) is unpacked.
    func preview(of packageURL: URL) async throws -> Preview {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { BlockingWork.removeInBackground(tempDir) }
        return try await BlockingWork.run(on: Self.stagingQueue) { [self] in
            try Self.inspectZipArchive(at: packageURL, limits: limits)
            do {
                try ProcessRunner.runSynchronously("/usr/bin/unzip", arguments: [
                    "-q", packageURL.path,
                    "metadata.json", "content/metadata.json", "previews/*", "content/previews/*",
                    "-d", tempDir.path
                ])
            } catch let failure as ProcessRunner.Failure
                where failure.status == Self.unzipSomeNamesMissing
            {
                // Expected: a package holds only one of the two layouts.
            } catch let failure as ProcessRunner.Failure {
                AppLog.persistence.error(
                    "package preview extraction failed: \(failure.localizedDescription, privacy: .public)"
                )
                throw ImportError.extractionFailed
            }
            let (manifest, root) = try loadManifest(from: tempDir)
            try validateManifest(manifest)
            let candidates = manifest.videos.compactMap(\.thumbnail)
                + (manifest.webWallpapers ?? []).compactMap(\.thumbnail)
            let thumbnail = candidates.lazy.compactMap { path -> NSImage? in
                let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count == 2, parts[0] == "previews",
                      Self.isSafePathComponent(String(parts[1]))
                else { return nil }
                return NSImage(contentsOf: root.appendingPathComponent(path))
            }.first
            return try Preview(
                manifest: manifest,
                thumbnail: thumbnail,
                packageBytes: Int64(packageURL.regularFileSize())
            )
        }
    }

    /// unzip's exit status when some of the names it was given matched no entry.
    private static let unzipSomeNamesMissing: Int32 = 11

    private func importVideo(
        _ video: PackageManifest.PackageVideo,
        from tempDir: URL,
        duplicateResolution: DuplicateResolution,
        libraryDigests: inout [String: String]
    ) throws -> String? {
        let sourceFileName = video.source.fileName
        guard Self.isSafePathComponent(video.id), Self.isSafePathComponent(sourceFileName) else {
            throw ImportError.unsafeFileReference(sourceFileName)
        }
        let videosDir = tempDir.appendingPathComponent("videos")

        if !fileManager.fileExists(atPath: videosDir.path) {
            if let matchedPath = try findExistingVideoPath(
                for: video,
                libraryDigests: &libraryDigests
            ) {
                return matchedPath
            }
            throw ImportError.videoNotFound(sourceFileName)
        }
        let videoFile = try validatedVideoURL(video, from: tempDir)

        let attrs = try fileManager.attributesOfItem(atPath: videoFile.path)
        let fileSize = attrs[.size] as? UInt64 ?? 0

        if let expectedSize = video.source.size, expectedSize > 0 {
            guard fileSize == expectedSize else {
                throw ImportError.corruptedVideoFile(sourceFileName)
            }
        }

        if let expectedSHA256 = video.sha256 {
            let actualSHA256 = try computeSHA256(for: videoFile.path)
            guard Self.digestsMatch(actualSHA256, expectedSHA256) else {
                throw ImportError.invalidChecksum(sourceFileName)
            }
        }

        if let existingPath = try findExistingVideoPath(
            for: video,
            libraryDigests: &libraryDigests
        ) {
            switch duplicateResolution {
            case .abort:
                throw ImportError.duplicateVideo(video.displayName)
            case .replace:
                let existingURL = URL(fileURLWithPath: existingPath)
                let stagedURL = existingURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString).import")
                try fileManager.copyItem(at: videoFile, to: stagedURL)
                do {
                    _ = try fileManager.replaceItemAt(existingURL, withItemAt: stagedURL)
                } catch {
                    try? fileManager.removeItem(at: stagedURL)
                    throw error
                }
                return existingPath
            }
        }

        let destPath = try makeImportDestinationPath(forVideoNamed: sourceFileName)
        try fileManager.copyItem(atPath: videoFile.path, toPath: destPath)

        return destPath
    }

    private func computeSHA256(for filePath: String) throws -> String {
        let fileURL = URL(fileURLWithPath: filePath)
        let chunkSize = 1024 * 1024
        var hasher = SHA256()

        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        while true {
            let data = fileHandle.readData(ofLength: chunkSize)
            if data.isEmpty { break }
            hasher.update(data: data)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func appSupportVideosDir() throws -> URL {
        if let videosDirectory {
            try fileManager.createDirectory(at: videosDirectory, withIntermediateDirectories: true)
            return videosDirectory
        }
        let libraryDir = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let appSupportDir =
            libraryDir
                .appendingPathComponent("Application Support/LiveWallpaper/Videos")
        try fileManager.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        return appSupportDir
    }

    private func makeImportDestinationPath(forVideoNamed fileName: String) throws -> String {
        let appSupportDir = try appSupportVideosDir()

        let baseURL = appSupportDir.appendingPathComponent(fileName)
        var destPath = baseURL.path

        var counter = 0
        while fileManager.fileExists(atPath: destPath) {
            counter += 1
            let name = baseURL.deletingPathExtension().lastPathComponent
            let ext = baseURL.pathExtension
            let newFileName = "\(name)_\(counter).\(ext)"
            destPath = appSupportDir.appendingPathComponent(newFileName).path
        }

        return destPath
    }

    /// The manifest's digest is written by whoever made the package, so its letter case is not
    /// ours.
    private static func digestsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private func findExistingVideoPath(
        for video: PackageManifest.PackageVideo,
        libraryDigests: inout [String: String]
    ) throws -> String? {
        let appSupportDir = try appSupportVideosDir()
        let existingFiles = try fileManager.contentsOfDirectory(
            at: appSupportDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for fileURL in existingFiles where fileURL.hasDirectoryPath == false {
            // contentsOfDirectory resolves symlinks in the folder's path; the library stores
            // the spelling new imports get, so a replaced video must not come back as a second
            // entry.
            let path = appSupportDir.appendingPathComponent(fileURL.lastPathComponent).path
            let attrs = try? fileManager.attributesOfItem(atPath: path)
            let existingSize = attrs?[.size] as? UInt64

            if let expectedSHA256 = video.sha256 {
                let actualSHA256: String
                if let cached = libraryDigests[path] {
                    actualSHA256 = cached
                } else {
                    actualSHA256 = try computeSHA256(for: path)
                    libraryDigests[path] = actualSHA256
                }
                if Self.digestsMatch(actualSHA256, expectedSHA256) {
                    return path
                }
                continue
            }

            let sameName = fileURL.lastPathComponent == video.source.fileName
            if sameName, let expectedSize = video.source.size, expectedSize > 0,
               existingSize == expectedSize
            {
                return path
            }
        }

        return nil
    }
}

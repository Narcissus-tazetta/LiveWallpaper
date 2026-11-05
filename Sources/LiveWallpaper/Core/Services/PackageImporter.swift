import AppKit
import AVFoundation
import CryptoKit
import Foundation

@MainActor
final class PackageImporter {
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
                return String(format: NSLocalizedString("metadata.jsonが破損しています: %@", comment: ""), details)
            case .unsupportedPackageVersion:
                return NSLocalizedString("サポートされていないパッケージバージョンです", comment: "")
            case let .duplicateVideo(name):
                return String(format: NSLocalizedString("重複するビデオが既に存在します: %@", comment: ""), name)
            case let .videoNotFound(name):
                return String(format: NSLocalizedString("ビデオファイルが見つかりません: %@", comment: ""), name)
            case let .corruptedVideoFile(name):
                return String(format: NSLocalizedString("ビデオファイルが破損しています: %@", comment: ""), name)
            case let .invalidChecksum(name):
                return String(format: NSLocalizedString("ビデオファイルのチェックサムが一致しません: %@", comment: ""), name)
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
                let template = NSLocalizedString("空き容量が不足しているため、パッケージを展開できません(必要: %@、空き: %@)", comment: "")
                return String(format: template, formatter.string(fromByteCount: required), formatter.string(fromByteCount: available))
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
            maximumEntryCount: 20_000,
            maximumMetadataBytes: 10 * 1024 * 1024
        )

        /// Store packages are capped at upload time, so anything bigger is not from the Store.
        static let store = Limits(
            maximumPackageFileBytes: 500 * 1024 * 1024,
            maximumExtractedBytes: 2 * 1024 * 1024 * 1024,
            maximumEntryCount: 1_000,
            maximumMetadataBytes: 10 * 1024 * 1024
        )
    }

    /// Free space that must remain after extraction, so a large import cannot fill the disk.
    static let extractionHeadroomBytes: Int64 = 2 * 1024 * 1024 * 1024

    private let fileManager: FileManager
    private let videosDirectory: URL?
    private let limits: Limits

    init(fileManager: FileManager = .default, videosDirectory: URL? = nil, limits: Limits = .local) {
        self.fileManager = fileManager
        self.videosDirectory = videosDirectory
        self.limits = limits
    }

    func importPackage(
        from packageURL: URL,
        into model: WallpaperModel,
        duplicateResolution: DuplicateResolution = .abort
    ) async throws {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        let inspection = try Self.inspectZipArchive(at: packageURL, limits: limits)
        let availableBytes = StorageUsage.availableDiskSpace(for: tempDir)
        guard inspection.totalUncompressedBytes + Self.extractionHeadroomBytes <= availableBytes else {
            throw ImportError.insufficientDiskSpace(
                requiredBytes: inspection.totalUncompressedBytes + Self.extractionHeadroomBytes, availableBytes: availableBytes
            )
        }
        try extractPackage(from: packageURL, to: tempDir)
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
            throw ImportError.extractedSizeTooLarge(extractedSize, max: limits.maximumExtractedBytes)
        }
        let (manifest, packageRootDir) = try loadManifest(from: tempDir)
        try validateManifest(manifest)
        try preflightVideos(
            manifest.videos, from: packageRootDir, duplicateResolution: duplicateResolution
        )

        var importedVideoPaths: [String: String] = [:]
        let existingFilesBeforeImport = Set(
            (try? fileManager.contentsOfDirectory(
                at: appSupportVideosDir(), includingPropertiesForKeys: nil
            ))?.map(\.path) ?? []
        )
        let rollbackDirectory = tempDir.appendingPathComponent("rollback", isDirectory: true)
        try fileManager.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)
        var replacementBackups: [String: URL] = [:]

        do {
            for video in manifest.videos {
                if case .replace = duplicateResolution,
                   let existingPath = try findExistingVideoPath(for: video),
                   replacementBackups[existingPath] == nil
                {
                    let backupURL = rollbackDirectory.appendingPathComponent(UUID().uuidString)
                    try fileManager.copyItem(atPath: existingPath, toPath: backupURL.path)
                    replacementBackups[existingPath] = backupURL
                }
                if let videoPath = try importVideo(
                    video,
                    from: packageRootDir,
                    duplicateResolution: duplicateResolution
                ) {
                    importedVideoPaths[video.id] = videoPath
                }
            }
        } catch {
            for path in importedVideoPaths.values where !existingFilesBeforeImport.contains(path) {
                try? fileManager.removeItem(atPath: path)
            }
            for (path, backupURL) in replacementBackups {
                let targetURL = URL(fileURLWithPath: path)
                let stagedURL = targetURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString).rollback")
                do {
                    try fileManager.copyItem(at: backupURL, to: stagedURL)
                    _ = try fileManager.replaceItemAt(targetURL, withItemAt: stagedURL)
                } catch {
                    try? fileManager.removeItem(at: stagedURL)
                }
            }
            throw error
        }

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

        importScenes(of: manifest, importedVideoPaths: importedVideoPaths, packageRoot: packageRootDir, into: model)

        var importedPlaylistIDs: [UUID] = []
        for playlist in manifest.playlists {
            let videoPaths = playlist.videoIds.compactMap { importedVideoPaths[$0] }
            if !videoPaths.isEmpty {
                if let playlistID = model.createPlaylist(named: playlist.name) {
                    for videoPath in videoPaths {
                        model.addRegisteredVideo(path: videoPath, to: playlistID)
                    }
                    importedPlaylistIDs.append(playlistID)
                }
            }
        }

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
        }
    }

    /// A broken scene leaves the baked video as a plain wallpaper rather than failing
    /// the import. video.id was checked by validatedVideoURL.
    private func importScenes(
        of manifest: PackageManifest,
        importedVideoPaths: [String: String],
        packageRoot: URL,
        into model: WallpaperModel
    ) {
        for video in manifest.videos where video.scene == true || video.scriptScene != nil {
            guard let videoPath = importedVideoPaths[video.id] else {
                continue
            }
            let source = packageRoot.appendingPathComponent("scenes", isDirectory: true)
                .appendingPathComponent(video.id, isDirectory: true)
            do {
                let document = try SceneStore.importScene(from: source, videoPath: videoPath)
                model.registerImportedScene(document, path: videoPath, asksAgain: true)
            } catch {
                AppLog.persistence.error(
                    "skipped scene of imported video id=\(video.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    struct ZipArchiveInspection {
        let totalEntries: Int
        let totalUncompressedBytes: Int64
    }

    @discardableResult
    static func inspectZipArchive(at fileURL: URL, limits: Limits = .local) throws -> ZipArchiveInspection {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let archiveSize = (attrs[.size] as? Int64) ?? 0
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

        var eocdOffsetInTail: Int?
        let sig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        if tailData.count >= 22 {
            for i in stride(from: tailData.count - 22, through: 0, by: -1) {
                if tailData[i] == sig[0] && tailData[i + 1] == sig[1] && tailData[i + 2] == sig[2] && tailData[i + 3] == sig[3] {
                    eocdOffsetInTail = i
                    break
                }
            }
        }
        guard let eocdOffsetInTail else {
            throw ImportError.invalidPackageFormat
        }

        let eocd = tailData.subdata(in: eocdOffsetInTail..<tailData.count)
        guard eocd.count >= 22 else { throw ImportError.invalidPackageFormat }

        let totalEntries = Int(readUInt16(from: eocd, at: 10))
        let cdSize = UInt64(readUInt32(from: eocd, at: 12))
        let cdOffset = UInt64(readUInt32(from: eocd, at: 16))

        guard totalEntries <= limits.maximumEntryCount else {
            throw ImportError.excessiveEntryCount(totalEntries, max: limits.maximumEntryCount)
        }
        guard cdOffset + cdSize <= UInt64(archiveSize) else {
            throw ImportError.invalidPackageFormat
        }

        try fileHandle.seek(toOffset: cdOffset)
        guard let cdData = try fileHandle.read(upToCount: Int(cdSize)), cdData.count == Int(cdSize) else {
            throw ImportError.invalidPackageFormat
        }

        var offset = 0
        var totalUncompressed: Int64 = 0

        for _ in 0..<totalEntries {
            guard offset + 46 <= cdData.count else { throw ImportError.invalidPackageFormat }
            let headerSig = readUInt32(from: cdData, at: offset)
            guard headerSig == 0x02014B50 else { throw ImportError.invalidPackageFormat }

            let uncompressedSize = UInt64(readUInt32(from: cdData, at: offset + 24))
            let filenameLen = Int(readUInt16(from: cdData, at: offset + 28))
            let extraLen = Int(readUInt16(from: cdData, at: offset + 30))
            let commentLen = Int(readUInt16(from: cdData, at: offset + 32))
            let externalAttr = readUInt32(from: cdData, at: offset + 38)

            let unixMode = (externalAttr >> 16) & 0o170000
            if unixMode == 0o120000 {
                throw ImportError.unsafeFileReference("symlink")
            }

            let nameStart = offset + 46
            guard nameStart + filenameLen <= cdData.count else { throw ImportError.invalidPackageFormat }
            let nameData = cdData.subdata(in: (cdData.startIndex + nameStart)..<(cdData.startIndex + nameStart + filenameLen))
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw ImportError.invalidPackageFormat
            }

            if name.split(separator: "/").contains("..") || name.hasPrefix("/") || name.contains("\\") || name.contains("\0") {
                throw ImportError.unsafeFileReference(name)
            }

            totalUncompressed += Int64(uncompressedSize)
            guard totalUncompressed <= limits.maximumExtractedBytes else {
                throw ImportError.extractedSizeTooLarge(totalUncompressed, max: limits.maximumExtractedBytes)
            }

            offset = nameStart + filenameLen + extraLen + commentLen
        }

        guard offset == cdData.count else {
            throw ImportError.invalidPackageFormat
        }

        return ZipArchiveInspection(totalEntries: totalEntries, totalUncompressedBytes: totalUncompressed)
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

    private func extractPackage(from packageURL: URL, to targetDir: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-q", packageURL.path, "-d", targetDir.path]

        let errorPipe = Pipe()
        task.standardError = errorPipe

        try task.run()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
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

        let metadataAttrs = try fileManager.attributesOfItem(atPath: metadataURL.path)
        let metadataSize = (metadataAttrs[.size] as? Int64) ?? 0
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

    static let supportedVersions: Set<String> = ["1.0", "1.1"]

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
        duplicateResolution: DuplicateResolution
    ) throws {
        var ids = Set<String>()
        for video in videos {
            guard ids.insert(video.id).inserted else {
                throw ImportError.invalidPackageFormat
            }
            let videosDir = packageRoot.appendingPathComponent("videos", isDirectory: true)
            if !fileManager.fileExists(atPath: videosDir.path) {
                guard try findExistingVideoPath(for: video) != nil else {
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
               try computeSHA256(for: videoURL.path)
               .caseInsensitiveCompare(expected) != .orderedSame
            {
                throw ImportError.invalidChecksum(video.source.fileName)
            }
            if case .abort = duplicateResolution,
               try findExistingVideoPath(for: video) != nil
            {
                throw ImportError.duplicateVideo(video.source.fileName)
            }
        }
    }

    private func importVideo(
        _ video: PackageManifest.PackageVideo,
        from tempDir: URL,
        duplicateResolution: DuplicateResolution
    ) throws -> String? {
        let sourceFileName = video.source.fileName
        guard Self.isSafePathComponent(video.id), Self.isSafePathComponent(sourceFileName) else {
            throw ImportError.unsafeFileReference(sourceFileName)
        }
        let videosDir = tempDir.appendingPathComponent("videos")

        if !fileManager.fileExists(atPath: videosDir.path) {
            if let matchedPath = try findExistingVideoPath(for: video) {
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
            guard actualSHA256 == expectedSHA256 else {
                throw ImportError.invalidChecksum(sourceFileName)
            }
        }

        if let existingPath = try findExistingVideoPath(for: video) {
            switch duplicateResolution {
            case .abort:
                throw ImportError.duplicateVideo(sourceFileName)
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

    private func findExistingVideoPath(for video: PackageManifest.PackageVideo) throws -> String? {
        let appSupportDir = try appSupportVideosDir()
        let existingFiles = try fileManager.contentsOfDirectory(
            at: appSupportDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for fileURL in existingFiles where fileURL.hasDirectoryPath == false {
            let path = fileURL.path
            let attrs = try? fileManager.attributesOfItem(atPath: path)
            let existingSize = attrs?[.size] as? UInt64

            if let expectedSHA256 = video.sha256 {
                let actualSHA256 = try computeSHA256(for: path)
                if actualSHA256 == expectedSHA256 {
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

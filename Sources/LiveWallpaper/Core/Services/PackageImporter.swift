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

        var errorDescription: String? {
            switch self {
            case .invalidPackageFormat:
                return "不正なパッケージ形式です"
            case .missingMetadata:
                return "metadata.jsonが見つかりません"
            case .invalidMetadataJSON(let details):
                return "metadata.jsonが破損しています: \(details)"
            case .unsupportedPackageVersion:
                return "サポートされていないパッケージバージョンです"
            case .duplicateVideo(let name):
                return "重複するビデオが既に存在します: \(name)"
            case .videoNotFound(let name):
                return "ビデオファイルが見つかりません: \(name)"
            case .corruptedVideoFile(let name):
                return "ビデオファイルが破損しています: \(name)"
            case .invalidChecksum(let name):
                return "ビデオファイルのチェックサムが一致しません: \(name)"
            case .extractionFailed:
                return "パッケージの展開に失敗しました"
            }
        }
    }

    private let fileManager = FileManager.default

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

        try extractPackage(from: packageURL, to: tempDir)
        let (manifest, packageRootDir) = try loadManifest(from: tempDir)
        try validateManifest(manifest)

        var importedVideoPaths: [String: String] = [:]

        for video in manifest.videos {
            if let videoPath = try importVideo(
                video,
                from: packageRootDir,
                duplicateResolution: duplicateResolution
            ) {
                importedVideoPaths[video.id] = videoPath

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
            }
        }

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

        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()

        do {
            return (try decoder.decode(PackageManifest.self, from: data), packageRootDir)
        } catch {
            throw ImportError.invalidMetadataJSON(error.localizedDescription)
        }
    }

    private func validateManifest(_ manifest: PackageManifest) throws {
        guard manifest.version == "1.0" else {
            throw ImportError.unsupportedPackageVersion
        }
    }

    private func importVideo(
        _ video: PackageManifest.PackageVideo,
        from tempDir: URL,
        duplicateResolution: DuplicateResolution
    ) throws -> String? {
        let sourceFileName = video.source.fileName
        let videosDir = tempDir.appendingPathComponent("videos")
        let videoFile = videosDir.appendingPathComponent("\(video.id).mp4")

        if fileManager.fileExists(atPath: videoFile.path) {
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
                    try fileManager.removeItem(atPath: existingPath)
                    try fileManager.copyItem(atPath: videoFile.path, toPath: existingPath)
                    return existingPath
                }
            }

            let destPath = try makeImportDestinationPath(forVideoNamed: sourceFileName)
            try fileManager.copyItem(atPath: videoFile.path, toPath: destPath)

            return destPath
        } else if !fileManager.fileExists(atPath: videosDir.path) {
            if let matchedPath = try findExistingVideoPath(for: video) {
                return matchedPath
            }
            throw ImportError.videoNotFound(sourceFileName)
        } else {
            throw ImportError.videoNotFound(sourceFileName)
        }
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
        let libraryDir = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let appSupportDir = libraryDir.appendingPathComponent("Application Support/LiveWallpaper/Videos")
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
            if sameName, let expectedSize = video.source.size, expectedSize > 0, existingSize == expectedSize {
                return path
            }
        }

        return nil
    }
}

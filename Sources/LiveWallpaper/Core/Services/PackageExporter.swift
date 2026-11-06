import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What goes into one package. Playlists may only name videos and web wallpapers that are
/// in the selection too; entries outside it are left out of the playlist.
struct PackageSelection {
    var name: String
    var description: String
    var videoPaths: [String] = []
    var webWallpaperIDs: [UUID] = []
    var scenePresetIDs: [UUID] = []
    var playlists: [WallpaperPlaylist] = []
    var license: String?

    var isEmpty: Bool {
        videoPaths.isEmpty && webWallpaperIDs.isEmpty && scenePresetIDs.isEmpty
    }
}

@MainActor
extension PackageSelection {
    static func library(of model: WallpaperModel) -> Self {
        model.loadUserScenePresetsIfNeeded()
        return Self(
            name: "Wallpaper Package",
            description: "Exported wallpaper configuration",
            videoPaths: model.allRegisteredVideoPaths,
            webWallpaperIDs: model.webWallpaperSources.map(\.id),
            scenePresetIDs: (model.userScenePresets ?? []).map(\.id),
            playlists: model.playlists
        )
    }

    static func playlist(_ playlist: WallpaperPlaylist) -> Self {
        Self(
            name: playlist.name,
            description: "Exported playlist",
            videoPaths: playlist.videoPaths,
            webWallpaperIDs: playlist.webWallpaperIDs,
            playlists: [playlist]
        )
    }

    static func video(_ path: String, model: WallpaperModel, license: String? = nil) -> Self {
        Self(
            name: model.registeredVideoDisplayName(for: path),
            description: "Exported single wallpaper",
            videoPaths: [path],
            license: license
        )
    }

    static func webWallpaper(_ source: WebWallpaperSource) -> Self {
        Self(
            name: source.displayName,
            description: "Exported web wallpaper",
            webWallpaperIDs: [source.id]
        )
    }

    static func scenePreset(_ preset: ScenePreset) -> Self {
        Self(name: preset.name, description: "Exported scene preset", scenePresetIDs: [preset.id])
    }
}

@MainActor
final class PackageExporter {
    enum ExportError: LocalizedError {
        case sceneAwaitingScriptApproval(String)
        case nothingToExport

        var errorDescription: String? {
            switch self {
            case let .sceneAwaitingScriptApproval(message):
                return message
            case .nothingToExport:
                return AppLocalization.localizedString("書き出せる壁紙がありません")
            }
        }
    }

    /// Overall progress of an export, 0...1.
    typealias Progress = @Sendable (Double) -> Void

    private let fileManager: FileManager
    private let manifestBuilder: PackageManifestBuilder
    private let archiveWriter: PackageArchiveWriter
    private let thumbnailGenerator: ThumbnailGenerator

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        manifestBuilder = PackageManifestBuilder(fileManager: fileManager)
        archiveWriter = PackageArchiveWriter(fileManager: fileManager)
        thumbnailGenerator = ThumbnailGenerator()
    }

    /// - Parameter bakedVideoDestination: when the selection's one video is a scene that
    ///   had to be re-baked, the new video is also copied here, so a loose copy shared next
    ///   to the package needs no second bake. Left untouched otherwise.
    func exportPackage(
        model: WallpaperModel,
        selection: PackageSelection,
        outputURL: URL,
        maximumStorePackageBytes: Int? = nil,
        bakedVideoDestination: URL? = nil,
        progress: @escaping Progress = { _ in }
    ) async throws {
        guard !selection.isEmpty else { throw ExportError.nothingToExport }
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { BlockingWork.removeInBackground(tempDir) }

        let contentDir = tempDir.appendingPathComponent("content")
        let previewsDir = contentDir.appendingPathComponent("previews")
        let folders = ["videos", "previews", "web", "presets"]
            .map { contentDir.appendingPathComponent($0) }
        for folder in folders {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let total = Double(max(selection.videoPaths.count, 1))
        var packagedVideos: [PackageManifestBuilder.PackagedVideo] = []
        var videoIDsByPath: [String: String] = [:]
        for (index, path) in selection.videoPaths.enumerated() {
            try Task.checkCancellation()
            let videoId = UUID().uuidString
            let snapshot = try await snapshotVideo(
                model: model,
                videoPath: path,
                videoId: videoId,
                contentDir: contentDir
            ) { fraction in progress(min((Double(index) + fraction) / total, 0.99)) }
            if snapshot.wasBaked, let bakedVideoDestination {
                try await replaceItem(at: bakedVideoDestination, withCopyOf: snapshot.url)
            }
            if let maximumStorePackageBytes, snapshot.hasScene {
                try await StoreSceneVideoCompressor.compressIfNeeded(
                    videoURL: snapshot.url, contentDirectory: contentDir,
                    maximumPackageBytes: maximumStorePackageBytes
                )
            }
            var thumbnail: String?
            if let image = await thumbnailGenerator.generateThumbnail(
                for: snapshot.url.path,
                maxSize: Self.thumbnailSize
            ), let pngData = ThumbnailGenerator.pngData(from: image) {
                try pngData.write(to: previewsDir.appendingPathComponent("\(videoId).png"))
                thumbnail = "previews/\(videoId).png"
            }
            videoIDsByPath[path] = videoId
            packagedVideos.append(.init(
                path: path,
                id: videoId,
                mediaPath: snapshot.url.path,
                thumbnail: thumbnail
            ))
            progress(min(Double(index + 1) / total, 0.99))
        }

        var webIDs: [UUID: String] = [:]
        var packagedWebs: [PackageManifest.PackageWebWallpaper] = []
        for id in selection.webWallpaperIDs {
            try Task.checkCancellation()
            guard let source = model.webWallpaperSources.first(where: { $0.id == id }) else {
                continue
            }
            let packaged = try await packageWebWallpaper(source, contentDir: contentDir)
            webIDs[id] = packaged.id
            packagedWebs.append(packaged)
        }

        var packagedPresets: [PackageManifest.PackageScenePreset] = []
        if !selection.scenePresetIDs.isEmpty, let store = model.scenePresetStore {
            model.loadUserScenePresetsIfNeeded()
            for id in selection.scenePresetIDs {
                guard let preset = model.userScenePresets?.first(where: { $0.id == id })
                else { continue }
                let packageID = UUID().uuidString
                let folder = "presets/\(packageID)"
                try await copyItem(
                    atPath: store.folderURL(of: id).path,
                    toPath: contentDir.appendingPathComponent(folder).path
                )
                packagedPresets.append(.init(id: packageID, name: preset.name, folder: folder))
            }
        }

        let playlists = selection.playlists.compactMap { playlist -> PackageManifest
            .PackagePlaylist? in
            let videoIds = playlist.videoPaths.compactMap { videoIDsByPath[$0] }
            let webIds = playlist.webWallpaperIDs.compactMap { webIDs[$0] }
            guard !videoIds.isEmpty || !webIds.isEmpty else { return nil }
            return .init(
                id: playlist.id.uuidString,
                name: playlist.name,
                videoIds: videoIds,
                shuffle: false,
                webWallpaperIds: webIds.isEmpty ? nil : webIds
            )
        }

        var manifest = try await manifestBuilder.buildManifest(
            model: model,
            name: selection.name,
            description: selection.description,
            license: selection.license,
            videos: packagedVideos,
            playlists: playlists,
            webWallpapers: packagedWebs,
            scenePresets: packagedPresets
        )
        for video in packagedVideos {
            try markPackagedScene(videoId: video.id, contentDir: contentDir, manifest: &manifest)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: contentDir.appendingPathComponent("metadata.json"))

        try Task.checkCancellation()
        try await archiveWriter.createPackage(from: contentDir, outputURL: outputURL)
        if let maximumStorePackageBytes {
            let bytes = try outputURL.regularFileSize()
            guard bytes <= maximumStorePackageBytes else {
                throw StoreClientError.fileTooLarge(
                    sizeBytes: bytes,
                    maxBytes: maximumStorePackageBytes
                )
            }
        }
        progress(1)
    }

    /// The loose video comes first in the list, the package (when asked for) after it.
    func exportSingleWallpaper(
        model: WallpaperModel,
        videoPath: String,
        outputFolderURL: URL,
        includePackage: Bool,
        progress: @escaping Progress = { _ in }
    ) async throws -> [URL] {
        let baseFileName = ExportFileNameSanitizer.sanitizedExportFileName(
            model.registeredVideoDisplayName(for: videoPath)
        )
        guard includePackage else {
            return try await [copyCurrentVideo(
                model: model,
                videoPath: videoPath,
                to: outputFolderURL,
                baseFileName: baseFileName,
                progress: progress
            )]
        }
        let packageURL = outputFolderURL.appendingPathComponent("\(baseFileName).lwpkg")
        let bakedURL = outputFolderURL.appendingPathComponent("\(baseFileName).mp4")
        try await exportPackage(
            model: model,
            selection: .video(videoPath, model: model),
            outputURL: packageURL,
            bakedVideoDestination: bakedURL,
            progress: progress
        )
        if fileManager.fileExists(atPath: bakedURL.path) {
            return [bakedURL, packageURL]
        }
        let videoURL = try await copyOriginalVideo(
            from: URL(fileURLWithPath: videoPath),
            to: outputFolderURL,
            baseFileName: baseFileName
        )
        return [videoURL, packageURL]
    }

    /// Store共有(StoreClient)からも、パッケージ本体だけを作りたい場合に直接呼べるよう
    /// internal にしている(exportSingleWallpaper は常に生動画コピーも作ってしまうため)。
    func exportSingleWallpaperPackage(
        model: WallpaperModel,
        videoPath: String,
        outputFolderURL: URL,
        baseFileName: String,
        license: String? = nil,
        maximumStorePackageBytes: Int? = nil
    ) async throws -> URL {
        let packageURL = outputFolderURL.appendingPathComponent("\(baseFileName).lwpkg")
        try await exportPackage(
            model: model,
            selection: .video(videoPath, model: model, license: license),
            outputURL: packageURL,
            maximumStorePackageBytes: maximumStorePackageBytes
        )
        return packageURL
    }

    // MARK: - Videos

    private struct VideoSnapshot {
        let url: URL
        let hasScene: Bool
        let wasBaked: Bool
    }

    private func snapshotVideo(
        model: WallpaperModel,
        videoPath: String,
        videoId: String,
        contentDir: URL,
        progress: @escaping Progress
    ) async throws -> VideoSnapshot {
        let videoURL = contentDir.appendingPathComponent("videos/\(videoId).mp4")
        model.flushSceneSave(path: videoPath)
        guard let loaded = try SceneStore.load(videoPath: videoPath) else {
            try await copyItem(atPath: videoPath, toPath: videoURL.path)
            return VideoSnapshot(url: videoURL, hasScene: false, wasBaked: false)
        }
        let document = SceneScriptPermissions.restored(loaded, path: videoPath)
        // Its video predates the edits, and baking would run scripts nobody allowed.
        if document.hasUnapprovedScripts, SceneStore.isNewerThanVideo(videoPath: videoPath) {
            throw ExportError.sceneAwaitingScriptApproval(String(
                format: model
                    .localizedString(
                        "「%@」には未許可のスクリプトがあり、動画が最新の編集を反映していません。スクリプトを許可するか停止してから書き出してください。"
                    ),
                model.registeredVideoDisplayName(for: videoPath)
            ))
        }
        let snapshotFolder = SceneStore.folderURL(forVideoPath: videoURL.path)
        // Capture assets before suspending, on the main actor: another edit may prune the
        // originals while the snapshot is being rendered, and scene saves run here.
        try SceneStore.copyScene(videoPath: videoPath, to: snapshotFolder)
        let isStale = model.scenesBaking.contains(videoPath) || SceneStore
            .isNewerThanVideo(videoPath: videoPath)
        let bakes = !document.hasUnapprovedScripts && isStale
        if bakes {
            try await SceneVideoBaker.bake(
                document: document, videoPath: videoURL.path,
                quality: BakeQuality.maximum.compressionQuality, to: videoURL,
                progress: progress
            )
        } else {
            try await copyItem(atPath: videoPath, toPath: videoURL.path)
        }
        let scenesDirectory = contentDir.appendingPathComponent("scenes", isDirectory: true)
        try fileManager.createDirectory(at: scenesDirectory, withIntermediateDirectories: true)
        try fileManager.moveItem(
            at: snapshotFolder,
            to: scenesDirectory.appendingPathComponent(videoId)
        )
        return VideoSnapshot(url: videoURL, hasScene: true, wasBaked: bakes)
    }

    /// The package re-bakes a scene whose video predates its edits; the loose video has to
    /// show the same picture instead of the stale file.
    private func copyCurrentVideo(
        model: WallpaperModel,
        videoPath: String,
        to outputFolderURL: URL,
        baseFileName: String,
        progress: @escaping Progress
    ) async throws -> URL {
        model.flushSceneSave(path: videoPath)
        let isStale = model.scenesBaking.contains(videoPath)
            || SceneStore.isNewerThanVideo(videoPath: videoPath)
        guard isStale, let loaded = try SceneStore.load(videoPath: videoPath) else {
            return try await copyOriginalVideo(
                from: URL(fileURLWithPath: videoPath),
                to: outputFolderURL,
                baseFileName: baseFileName
            )
        }
        let document = SceneScriptPermissions.restored(loaded, path: videoPath)
        // Baking would run scripts nobody allowed, so the old video is all there is to share.
        guard !document.hasUnapprovedScripts else {
            return try await copyOriginalVideo(
                from: URL(fileURLWithPath: videoPath),
                to: outputFolderURL,
                baseFileName: baseFileName
            )
        }
        let outputURL = outputFolderURL.appendingPathComponent("\(baseFileName).mp4")
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        try await SceneVideoBaker.bake(
            document: document, videoPath: videoPath,
            quality: BakeQuality.maximum.compressionQuality, to: outputURL,
            progress: progress
        )
        return outputURL
    }

    private func markPackagedScene(
        videoId: String,
        contentDir: URL,
        manifest: inout PackageManifest
    ) throws {
        guard fileManager
            .fileExists(atPath: contentDir.appendingPathComponent("scenes/\(videoId)/scene.json")
                .path),
            let index = manifest.videos.firstIndex(where: { $0.id == videoId })
        else { return }
        let source = contentDir.appendingPathComponent("scenes/\(videoId)/scene.json")
        let document = try JSONDecoder().decode(SceneDocument.self, from: Data(contentsOf: source))
        if let apiVersion = document.scripts.map(\.version).max() {
            // Older importers understand scene=true and would erase unknown script fields on edit.
            manifest.videos[index].scriptScene = .init(apiVersion: apiVersion)
            manifest.videos[index].scene = nil
        } else {
            manifest.videos[index].scene = true
        }
    }

    // MARK: - Web wallpapers

    private func packageWebWallpaper(
        _ source: WebWallpaperSource,
        contentDir: URL
    ) async throws -> PackageManifest.PackageWebWallpaper {
        let packageID = UUID().uuidString
        var packaged = PackageManifest.PackageWebWallpaper(
            id: packageID,
            displayName: source.displayName
        )
        if let folderPath = source.localFolderPath {
            let folder = "web/\(packageID)"
            try await copyItem(
                atPath: folderPath,
                toPath: contentDir.appendingPathComponent(folder).path
            )
            packaged.folder = folder
            packaged.settings = try LocalWebSettings.load(id: source.id).portable(
                for: LocalWebWallpaperPackage.load(folder: URL(fileURLWithPath: folderPath))
            )
        } else {
            packaged.url = source.url.absoluteString
        }
        if let thumbnailPath = source.thumbnailPath,
           let png = Self.imageThumbnailPNG(
               path: thumbnailPath,
               maxPixelSize: Int(Self.thumbnailSize.width)
           )
        {
            let name = "previews/\(packageID).png"
            try png.write(to: contentDir.appendingPathComponent(name))
            packaged.thumbnail = name
        }
        return packaged
    }

    static let thumbnailSize = CGSize(width: 512, height: 288)

    static func imageThumbnailPNG(path: String, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
              ] as CFDictionary)
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: - Files

    /// Videos run to gigabytes; copying one on the main actor would freeze the app.
    private func copyItem(atPath source: String, toPath destination: String) async throws {
        let files = SendableFileManager(manager: fileManager)
        try await BlockingWork
            .run { try files.manager.copyItem(atPath: source, toPath: destination) }
    }

    private func replaceItem(at destination: URL, withCopyOf source: URL) async throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try await copyItem(atPath: source.path, toPath: destination.path)
    }

    private func copyOriginalVideo(
        from sourceURL: URL,
        to outputFolderURL: URL,
        baseFileName: String
    ) async throws -> URL {
        let fileExtension = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let videoFileName = "\(baseFileName).\(fileExtension)"
        let videoOutputURL = outputFolderURL.appendingPathComponent(videoFileName)

        if sourceURL.standardizedFileURL.path == videoOutputURL.standardizedFileURL.path {
            return videoOutputURL
        }
        try await replaceItem(at: videoOutputURL, withCopyOf: sourceURL)
        return videoOutputURL
    }
}

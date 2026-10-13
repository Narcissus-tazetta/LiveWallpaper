import CoreGraphics
import Foundation

@MainActor
final class PackageExporter {
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

    func exportPackage(
        model: WallpaperModel,
        includeVideos: Bool,
        outputURL: URL
    ) async throws {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        let contentDir = tempDir.appendingPathComponent("content")
        try fileManager.createDirectory(at: contentDir, withIntermediateDirectories: true)

        let videosDir = contentDir.appendingPathComponent("videos")
        let previewsDir = contentDir.appendingPathComponent("previews")

        if includeVideos {
            try fileManager.createDirectory(at: videosDir, withIntermediateDirectories: true)
        }
        try fileManager.createDirectory(at: previewsDir, withIntermediateDirectories: true)

        var videoMap: [String: String] = [:]
        var videoThumbnails: [String: String] = [:]
        var mediaPathsByVideoID: [String: String] = [:]
        var totalBytes: UInt64 = 0

        for path in model.allRegisteredVideoPaths {
            let videoId = UUID().uuidString
            videoMap[path] = videoId

            if includeVideos {
                let snapshot = try await snapshotVideo(model: model, videoPath: path, videoId: videoId, contentDir: contentDir)
                mediaPathsByVideoID[videoId] = snapshot.path
                let attrs = try fileManager.attributesOfItem(atPath: snapshot.path)
                let fileSize = attrs[.size] as? UInt64 ?? 0
                totalBytes += fileSize
            }

            let thumbPath = previewsDir.appendingPathComponent("\(videoId).png")
            if let thumbnail = await thumbnailGenerator.generateThumbnail(
                for: mediaPathsByVideoID[videoId] ?? path,
                maxSize: CGSize(width: 256, height: 144)
            ),
                let pngData = ThumbnailGenerator.pngData(from: thumbnail)
            {
                try pngData.write(to: thumbPath)
                videoThumbnails[videoId] = "previews/\(videoId).png"
            }
        }

        var manifest = try await manifestBuilder.buildManifest(
            model: model,
            videoMap: videoMap,
            videoThumbnails: videoThumbnails,
            includeVideos: includeVideos,
            totalBytes: totalBytes,
            mediaPathsByVideoID: mediaPathsByVideoID
        )
        if includeVideos {
            for videoId in videoMap.values {
                markPackagedScene(videoId: videoId, contentDir: contentDir, manifest: &manifest)
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        let manifestURL = contentDir.appendingPathComponent("metadata.json")
        try manifestData.write(to: manifestURL)

        try archiveWriter.createPackage(from: contentDir, outputURL: outputURL)
    }

    func exportSingleWallpaper(
        model: WallpaperModel,
        videoPath: String,
        outputFolderURL: URL,
        includePackage: Bool
    ) async throws -> [URL] {
        let baseFileName = ExportFileNameSanitizer.sanitizedExportFileName(
            model.registeredVideoDisplayName(for: videoPath)
        )
        var outputURLs: [URL] = []
        if includePackage {
            let packageURL = try await exportSingleWallpaperPackage(
                model: model,
                videoPath: videoPath,
                outputFolderURL: outputFolderURL,
                baseFileName: baseFileName
            )
            outputURLs.append(packageURL)
        }
        let videoURL = try copyOriginalVideo(
            from: URL(fileURLWithPath: videoPath),
            to: outputFolderURL,
            baseFileName: baseFileName
        )
        outputURLs.append(videoURL)
        return outputURLs
    }

    /// Store共有(StoreClient)からも、パッケージ本体だけを作りたい場合に直接呼べるよう
    /// internal にしている(exportSingleWallpaper は常に生動画コピーも作ってしまうため)。
    func exportSingleWallpaperPackage(
        model: WallpaperModel,
        videoPath: String,
        outputFolderURL: URL,
        baseFileName: String,
        license: String? = nil
    ) async throws -> URL {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        let contentDir = tempDir.appendingPathComponent("content")
        try fileManager.createDirectory(at: contentDir, withIntermediateDirectories: true)

        let videosDir = contentDir.appendingPathComponent("videos")
        let previewsDir = contentDir.appendingPathComponent("previews")
        try fileManager.createDirectory(at: videosDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: previewsDir, withIntermediateDirectories: true)

        let videoId = UUID().uuidString
        var videoThumbnails: [String: String] = [:]

        let packagedVideoURL = try await snapshotVideo(model: model, videoPath: videoPath, videoId: videoId, contentDir: contentDir)
        let attrs = try fileManager.attributesOfItem(atPath: packagedVideoURL.path)
        let fileSize = attrs[.size] as? UInt64 ?? 0

        let thumbPath = previewsDir.appendingPathComponent("\(videoId).png")
        if let thumbnail = await thumbnailGenerator.generateThumbnail(
            for: packagedVideoURL.path,
            maxSize: CGSize(width: 256, height: 144)
        ),
            let pngData = ThumbnailGenerator.pngData(from: thumbnail)
        {
            try pngData.write(to: thumbPath)
            videoThumbnails[videoId] = "previews/\(videoId).png"
        }

        var manifest = try await manifestBuilder.buildSingleVideoManifest(
            model: model,
            videoPath: videoPath,
            videoId: videoId,
            videoThumbnails: videoThumbnails,
            fileSize: fileSize,
            mediaPath: packagedVideoURL.path,
            license: license
        )
        markPackagedScene(videoId: videoId, contentDir: contentDir, manifest: &manifest)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        let manifestURL = contentDir.appendingPathComponent("metadata.json")
        try manifestData.write(to: manifestURL)

        let packageFileName = "\(baseFileName).lwpkg"
        let packageURL = outputFolderURL.appendingPathComponent(packageFileName)
        try archiveWriter.createPackage(from: contentDir, outputURL: packageURL)
        return packageURL
    }

    private func snapshotVideo(
        model: WallpaperModel,
        videoPath: String,
        videoId: String,
        contentDir: URL
    ) async throws -> URL {
        let videoURL = contentDir.appendingPathComponent("videos/\(videoId).mp4")
        if let document = try SceneStore.load(videoPath: videoPath) {
            let snapshotFolder = SceneStore.folderURL(forVideoPath: videoURL.path)
            // Capture assets before suspending: another edit may prune the originals
            // while the snapshot is being rendered.
            try SceneStore.copyScene(videoPath: videoPath, to: snapshotFolder)
            if model.scenesBaking.contains(videoPath) || SceneStore.isNewerThanVideo(videoPath: videoPath) {
                try await SceneVideoBaker.bake(document: document, videoPath: videoURL.path, to: videoURL) { _ in }
            } else {
                try fileManager.copyItem(atPath: videoPath, toPath: videoURL.path)
            }
            let scenesDirectory = contentDir.appendingPathComponent("scenes", isDirectory: true)
            try fileManager.createDirectory(at: scenesDirectory, withIntermediateDirectories: true)
            try fileManager.moveItem(at: snapshotFolder, to: scenesDirectory.appendingPathComponent(videoId))
        } else {
            try fileManager.copyItem(atPath: videoPath, toPath: videoURL.path)
        }
        return videoURL
    }

    private func markPackagedScene(videoId: String, contentDir: URL, manifest: inout PackageManifest) {
        guard fileManager.fileExists(atPath: contentDir.appendingPathComponent("scenes/\(videoId)/scene.json").path),
              let index = manifest.videos.firstIndex(where: { $0.id == videoId })
        else { return }
        manifest.videos[index].scene = true
    }

    private func copyOriginalVideo(
        from sourceURL: URL,
        to outputFolderURL: URL,
        baseFileName: String
    ) throws -> URL {
        let fileExtension = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let videoFileName = "\(baseFileName).\(fileExtension)"
        let videoOutputURL = outputFolderURL.appendingPathComponent(videoFileName)

        if sourceURL.standardizedFileURL.path == videoOutputURL.standardizedFileURL.path {
            return videoOutputURL
        }
        if fileManager.fileExists(atPath: videoOutputURL.path) {
            try fileManager.removeItem(at: videoOutputURL)
        }
        try fileManager.copyItem(at: sourceURL, to: videoOutputURL)
        return videoOutputURL
    }
}

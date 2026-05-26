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
        var totalBytes: UInt64 = 0

        for path in model.allRegisteredVideoPaths {
            let videoId = UUID().uuidString
            videoMap[path] = videoId

            if includeVideos {
                let attrs = try fileManager.attributesOfItem(atPath: path)
                let fileSize = attrs[.size] as? UInt64 ?? 0
                totalBytes += fileSize

                let destURL = videosDir.appendingPathComponent("\(videoId).mp4")
                try fileManager.copyItem(atPath: path, toPath: destURL.path)
            }

            let thumbPath = previewsDir.appendingPathComponent("\(videoId).png")
            if let thumbnail = await thumbnailGenerator.generateThumbnail(
                for: path,
                maxSize: CGSize(width: 256, height: 144)
            ),
                let pngData = ThumbnailGenerator.pngData(from: thumbnail)
            {
                try pngData.write(to: thumbPath)
                videoThumbnails[videoId] = "previews/\(videoId).png"
            }
        }

        let manifest = manifestBuilder.buildManifest(
            model: model,
            videoMap: videoMap,
            videoThumbnails: videoThumbnails,
            includeVideos: includeVideos,
            totalBytes: totalBytes
        )

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
        outputFolderURL: URL
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
        try fileManager.createDirectory(at: videosDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: previewsDir, withIntermediateDirectories: true)

        let videoId = UUID().uuidString
        var videoThumbnails: [String: String] = [:]

        let attrs = try fileManager.attributesOfItem(atPath: videoPath)
        let fileSize = attrs[.size] as? UInt64 ?? 0

        // Keep original bytes (no transcoding) to avoid any quality loss.
        let packagedVideoURL = videosDir.appendingPathComponent("\(videoId).mp4")
        try fileManager.copyItem(atPath: videoPath, toPath: packagedVideoURL.path)

        let thumbPath = previewsDir.appendingPathComponent("\(videoId).png")
        if let thumbnail = await thumbnailGenerator.generateThumbnail(
            for: videoPath,
            maxSize: CGSize(width: 256, height: 144)
        ),
            let pngData = ThumbnailGenerator.pngData(from: thumbnail)
        {
            try pngData.write(to: thumbPath)
            videoThumbnails[videoId] = "previews/\(videoId).png"
        }

        let manifest = manifestBuilder.buildSingleVideoManifest(
            model: model,
            videoPath: videoPath,
            videoId: videoId,
            videoThumbnails: videoThumbnails,
            fileSize: fileSize
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        let manifestURL = contentDir.appendingPathComponent("metadata.json")
        try manifestData.write(to: manifestURL)

        let baseFileName = ExportFileNameSanitizer.sanitizedExportFileName(
            model.registeredVideoDisplayName(for: videoPath)
        )
        let packageFileName = "\(baseFileName).lwpkg"
        let packageURL = outputFolderURL.appendingPathComponent(packageFileName)
        try archiveWriter.createPackage(from: contentDir, outputURL: packageURL)

        let videoFileName = "\(baseFileName).mov"
        let videoOutputURL = outputFolderURL.appendingPathComponent(videoFileName)
        if fileManager.fileExists(atPath: videoOutputURL.path) {
            try fileManager.removeItem(at: videoOutputURL)
        }
        try fileManager.copyItem(atPath: videoPath, toPath: videoOutputURL.path)
    }
}

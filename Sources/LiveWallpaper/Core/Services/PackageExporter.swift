import AppKit
import AVFoundation
import CryptoKit
import Foundation

@MainActor
final class PackageExporter {
    private let fileManager = FileManager.default

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
            if let thumbnail = await generateThumbnail(for: path),
               let pngData = Self.pngData(from: thumbnail)
            {
                try pngData.write(to: thumbPath)
                videoThumbnails[videoId] = "previews/\(videoId).png"
            }
        }

        let manifest = buildManifest(
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

        try createPackage(from: contentDir, outputURL: outputURL)
    }

    private func buildManifest(
        model: WallpaperModel,
        videoMap: [String: String],
        videoThumbnails: [String: String],
        includeVideos: Bool,
        totalBytes: UInt64
    ) -> PackageManifest {
        let isoFormatter = ISO8601DateFormatter()
        let createdAt = isoFormatter.string(from: Date())

        let packageVideos = model.allRegisteredVideoPaths
            .compactMap { path -> PackageManifest.PackageVideo? in
                guard let videoId = videoMap[path] else { return nil }

                var presentations: [String: PackageManifest.PackageVideo.ScreenPresentation] = [:]
                if let screenPresentations = model.wallpaperPresentationByPath[path] {
                    for (screenId, pres) in screenPresentations {
                        presentations[screenId] = PackageManifest.PackageVideo.ScreenPresentation(
                            fitMode: pres.fitMode.rawValue,
                            zoom: pres.zoom,
                            offsetX: pres.offsetX,
                            offsetY: pres.offsetY
                        )
                    }
                }

                let attrs = try? fileManager.attributesOfItem(atPath: path)
                let fileSize = attrs?[.size] as? UInt64

                let sha256: String? = {
                    do {
                        let data = try Data(contentsOf: URL(fileURLWithPath: path))
                        let digest = SHA256.hash(data: data)
                        return digest.map { String(format: "%02x", $0) }.joined()
                    } catch {
                        return nil
                    }
                }()

                return PackageManifest.PackageVideo(
                    id: videoId,
                    source: .init(
                        fileName: URL(fileURLWithPath: path).lastPathComponent,
                        size: fileSize
                    ),
                    displayName: model.registeredVideoDisplayName(for: path),
                    sha256: sha256,
                    thumbnail: videoThumbnails[videoId],
                    presentations: presentations.isEmpty ? ["main": .init(
                        fitMode: "fill",
                        zoom: 1.0,
                        offsetX: 0,
                        offsetY: 0
                    )] : presentations
                )
            }

        let packagePlaylists = model.playlists.map { playlist -> PackageManifest.PackagePlaylist in
            PackageManifest.PackagePlaylist(
                id: playlist.id.uuidString,
                name: playlist.name,
                videoIds: playlist.videoPaths.compactMap { videoMap[$0] },
                shuffle: false
            )
        }

        return PackageManifest(
            version: "1.0",
            manifest: .init(
                name: "Wallpaper Package",
                author: NSFullUserName(),
                createdAt: createdAt,
                description: "Exported wallpaper configuration"
            ),
            videos: packageVideos,
            playlists: packagePlaylists,
            packaging: .init(videosIncluded: includeVideos, packageSizeBytes: totalBytes)
        )
    }

    private func generateThumbnail(for path: String) async -> NSImage? {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 144)

        do {
            let duration = try await asset.load(.duration)
            let durationSeconds = CMTimeGetSeconds(duration)
            let targetTime = CMTime(
                seconds: min(max(durationSeconds * 0.3, 0.1), durationSeconds - 0.1),
                preferredTimescale: 600
            )

            let cgImage = try generator.copyCGImage(at: targetTime, actualTime: nil)
            return NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        } catch {
            return nil
        }
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

        let previewsDir = contentDir.appendingPathComponent("previews")
        try fileManager.createDirectory(at: previewsDir, withIntermediateDirectories: true)

        let videoId = UUID().uuidString
        var videoThumbnails: [String: String] = [:]

        let attrs = try fileManager.attributesOfItem(atPath: videoPath)
        let fileSize = attrs[.size] as? UInt64 ?? 0

        let thumbPath = previewsDir.appendingPathComponent("\(videoId).png")
        if let thumbnail = await generateThumbnail(for: videoPath),
           let pngData = Self.pngData(from: thumbnail)
        {
            try pngData.write(to: thumbPath)
            videoThumbnails[videoId] = "previews/\(videoId).png"
        }

        let manifest = buildSingleVideoManifest(
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

        let baseFileName = sanitizedExportFileName(model.registeredVideoDisplayName(for: videoPath))
        let packageFileName = "\(baseFileName).lwpkg"
        let packageURL = outputFolderURL.appendingPathComponent(packageFileName)
        try createPackage(from: contentDir, outputURL: packageURL)

        let videoFileName = "\(baseFileName).mov"
        let videoOutputURL = outputFolderURL.appendingPathComponent(videoFileName)
        if fileManager.fileExists(atPath: videoOutputURL.path) {
            try fileManager.removeItem(at: videoOutputURL)
        }
        try fileManager.copyItem(atPath: videoPath, toPath: videoOutputURL.path)
    }

    private func buildSingleVideoManifest(
        model: WallpaperModel,
        videoPath: String,
        videoId: String,
        videoThumbnails: [String: String],
        fileSize: UInt64
    ) -> PackageManifest {
        let isoFormatter = ISO8601DateFormatter()
        let createdAt = isoFormatter.string(from: Date())

        var presentations: [String: PackageManifest.PackageVideo.ScreenPresentation] = [:]
        if let screenPresentations = model.wallpaperPresentationByPath[videoPath] {
            for (screenId, pres) in screenPresentations {
                presentations[screenId] = PackageManifest.PackageVideo.ScreenPresentation(
                    fitMode: pres.fitMode.rawValue,
                    zoom: pres.zoom,
                    offsetX: pres.offsetX,
                    offsetY: pres.offsetY
                )
            }
        }

        let sha256: String? = {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: videoPath))
                let digest = SHA256.hash(data: data)
                return digest.map { String(format: "%02x", $0) }.joined()
            } catch {
                return nil
            }
        }()

        let packageVideo = PackageManifest.PackageVideo(
            id: videoId,
            source: .init(
                fileName: URL(fileURLWithPath: videoPath).lastPathComponent,
                size: fileSize
            ),
            displayName: model.registeredVideoDisplayName(for: videoPath),
            sha256: sha256,
            thumbnail: videoThumbnails[videoId],
            presentations: presentations.isEmpty ? ["main": .init(
                fitMode: "fill",
                zoom: 1.0,
                offsetX: 0,
                offsetY: 0
            )] : presentations
        )

        return PackageManifest(
            version: "1.0",
            manifest: .init(
                name: model.registeredVideoDisplayName(for: videoPath),
                author: NSFullUserName(),
                createdAt: createdAt,
                description: "Exported single wallpaper"
            ),
            videos: [packageVideo],
            playlists: [],
            packaging: .init(videosIncluded: false, packageSizeBytes: 0)
        )
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func sanitizedExportFileName(_ rawValue: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let components = rawValue.components(separatedBy: invalidCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = components.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        return collapsed.isEmpty ? "Wallpaper" : collapsed
    }

    private func createPackage(from contentDir: URL, outputURL: URL) throws {
        let outputDir = outputURL.deletingLastPathComponent()
        let tempOutputURL = outputDir.appendingPathComponent("\(UUID().uuidString).lwpkg")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = [
            "-c",
            "-k",
            "--sequesterRsrc",
            "--keepParent",
            contentDir.path,
            tempOutputURL.path
        ]
        try task.run()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            throw NSError(
                domain: "PackageExporter",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "ZIP creation failed"]
            )
        }

        do {
            if fileManager.fileExists(atPath: outputURL.path) {
                _ = try fileManager.replaceItemAt(outputURL, withItemAt: tempOutputURL)
            } else {
                try fileManager.moveItem(at: tempOutputURL, to: outputURL)
            }
        } catch {
            try? fileManager.removeItem(at: tempOutputURL)
            throw NSError(
                domain: "PackageExporter",
                code: -2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to write package to destination",
                    NSUnderlyingErrorKey: error
                ]
            )
        }
    }
}

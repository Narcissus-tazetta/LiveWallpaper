@preconcurrency import AVFoundation
import Foundation
import ImageIO

enum ReconvertedSceneFiles {
    static func replace(source: URL, videoPath: String, backup: URL) async throws -> SceneDocument {
        let fm = FileManager.default
        let video = URL(fileURLWithPath: videoPath)
        let staging = video.deletingLastPathComponent().appendingPathComponent(".reconversion-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            do { try fm.removeItem(at: staging) }
            catch { AppLog.persistence.error("reconversion cleanup failed: \(error.localizedDescription, privacy: .public)") }
        }
        let preparedVideo = staging.appendingPathComponent("wallpaper.mp4")
        let document = try SceneStore.importScene(from: source, videoPath: preparedVideo.path)
        let permitted = SceneScriptPermissions.restored(document, path: videoPath)
        try await SceneVideoBaker.bake(document: permitted, videoPath: preparedVideo.path,
                                       stillOnly: true, to: preparedVideo) { _ in }
        let preparedPreview = VideoThumbnailGenerator.expectedSidecarURL(for: preparedVideo.path)
        try writePreview(video: preparedVideo, destination: preparedPreview)
        let scene = SceneStore.folderURL(forVideoPath: videoPath)
        let preview = VideoThumbnailGenerator.expectedSidecarURL(for: videoPath)
        let files = [(scene, SceneStore.folderURL(forVideoPath: preparedVideo.path)),
                     (video, preparedVideo), (preview, preparedPreview)]
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        for (destination, _) in files where fm.fileExists(atPath: destination.path) {
            let saved = backup.appendingPathComponent(destination.lastPathComponent)
            if !fm.fileExists(atPath: saved.path) { try fm.copyItem(at: destination, to: saved) }
        }
        do {
            for (destination, prepared) in files {
                if fm.fileExists(atPath: destination.path) {
                    _ = try fm.replaceItemAt(destination, withItemAt: prepared)
                } else {
                    try fm.moveItem(at: prepared, to: destination)
                }
            }
            if document.isAnimated { try SceneStore.markVideoOutOfDate(videoPath: videoPath) }
        } catch {
            let installationError = error
            for (destination, _) in files {
                let saved = backup.appendingPathComponent(destination.lastPathComponent)
                if fm.fileExists(atPath: saved.path) {
                    let restore = staging.appendingPathComponent(UUID().uuidString)
                    try fm.copyItem(at: saved, to: restore)
                    if fm.fileExists(atPath: destination.path) {
                        _ = try fm.replaceItemAt(destination, withItemAt: restore)
                    } else {
                        try fm.moveItem(at: restore, to: destination)
                    }
                }
            }
            throw installationError
        }
        return document
    }

    static func writePreview(video: URL, destination: URL) throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        let image = try generator.copyCGImage(at: .zero, actualTime: nil)
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw SceneStore.StoreError.unreadableImage(destination.lastPathComponent)
        }
        CGImageDestinationAddImage(encoder, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else {
            throw SceneStore.StoreError.unreadableImage(destination.lastPathComponent)
        }
        try (data as Data).write(to: destination, options: .atomic)
    }
}

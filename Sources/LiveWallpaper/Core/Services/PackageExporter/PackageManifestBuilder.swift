import AVFoundation
import CryptoKit
import Foundation

@MainActor
final class PackageManifestBuilder {
    static let currentVersion = "1.1"
    static let webAndPresetVersion = "1.2"

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    private func loadDurationAndAudioFlag(path: String) async
        -> (duration: Double?, hasAudio: Bool?)
    {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let duration = try? await asset.load(.duration).seconds
        let audioTracks = try? await asset.loadTracks(withMediaType: .audio)
        return (duration, audioTracks.map { !$0.isEmpty })
    }

    private func editMetadata(
        model: WallpaperModel,
        path: String
    ) -> PackageManifest.PackageVideo.EditMetadata? {
        guard let edit = model.wallpaperEdit(for: path) else {
            return nil
        }
        return .init(trimStart: edit.trimStart, trimEnd: edit.trimEnd, loopStart: edit.loopStart)
    }

    struct PackagedVideo {
        let path: String
        let id: String
        /// The file inside the package, which differs from `path` for a re-baked scene.
        let mediaPath: String
        let thumbnail: String?
    }

    func buildManifest(
        model: WallpaperModel,
        name: String,
        description: String,
        license: String? = nil,
        videos: [PackagedVideo],
        playlists: [PackageManifest.PackagePlaylist] = [],
        webWallpapers: [PackageManifest.PackageWebWallpaper] = [],
        scenePresets: [PackageManifest.PackageScenePreset] = []
    ) async throws -> PackageManifest {
        var packageVideos: [PackageManifest.PackageVideo] = []
        var totalBytes: UInt64 = 0
        for video in videos {
            let packaged = try await packageVideo(model: model, video: video)
            totalBytes += packaged.source.size ?? 0
            packageVideos.append(packaged)
        }
        let carriesNewKinds = !webWallpapers.isEmpty || !scenePresets.isEmpty
        return PackageManifest(
            version: carriesNewKinds ? Self.webAndPresetVersion : Self.currentVersion,
            manifest: .init(
                name: name,
                author: NSFullUserName(),
                createdAt: ISO8601DateFormatter().string(from: Date()),
                description: description,
                license: license
            ),
            videos: packageVideos,
            playlists: playlists,
            packaging: .init(videosIncluded: true, packageSizeBytes: totalBytes),
            webWallpapers: webWallpapers.isEmpty ? nil : webWallpapers,
            scenePresets: scenePresets.isEmpty ? nil : scenePresets
        )
    }

    private func packageVideo(
        model: WallpaperModel,
        video: PackagedVideo
    ) async throws -> PackageManifest.PackageVideo {
        var presentations: [String: PackageManifest.PackageVideo.ScreenPresentation] = [:]
        for (screenId, pres) in model.wallpaperPresentationByPath[video.path] ?? [:] {
            presentations[screenId] = .init(
                fitMode: pres.fitMode.rawValue,
                zoom: pres.zoom,
                offsetX: pres.offsetX,
                offsetY: pres.offsetY
            )
        }
        let fileSize = try UInt64(URL(fileURLWithPath: video.mediaPath).regularFileSize())
        let sha256 = try await checksum(path: video.mediaPath)
        let (duration, hasAudio) = await loadDurationAndAudioFlag(path: video.mediaPath)
        return PackageManifest.PackageVideo(
            id: video.id,
            source: .init(
                fileName: URL(fileURLWithPath: video.path).lastPathComponent,
                size: fileSize
            ),
            displayName: model.registeredVideoDisplayName(for: video.path),
            sha256: sha256,
            thumbnail: video.thumbnail,
            presentations: presentations.isEmpty ? ["main": .init(
                fitMode: "fill",
                zoom: 1.0,
                offsetX: 0,
                offsetY: 0
            )] : presentations,
            edit: editMetadata(model: model, path: video.path),
            duration: duration,
            hasAudio: hasAudio,
            cursorEffects: model.cursorEffectsOverride(path: video.path)
        )
    }

    /// Hashing a multi-gigabyte video takes seconds, so it stays off the main actor.
    private func checksum(path: String) async throws -> String {
        try await BlockingWork.run {
            let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}

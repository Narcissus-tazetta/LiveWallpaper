import AVFoundation
import CryptoKit
import Foundation

@MainActor
final class PackageManifestBuilder {
    static let currentVersion = "1.1"

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    private func loadDurationAndAudioFlag(path: String) async -> (duration: Double?, hasAudio: Bool?) {
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

    func buildManifest(
        model: WallpaperModel,
        videoMap: [String: String],
        videoThumbnails: [String: String],
        includeVideos: Bool,
        totalBytes: UInt64
    ) async -> PackageManifest {
        let isoFormatter = ISO8601DateFormatter()
        let createdAt = isoFormatter.string(from: Date())

        var packageVideos: [PackageManifest.PackageVideo] = []
        for path in model.allRegisteredVideoPaths {
            guard let videoId = videoMap[path] else { continue }

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

            let (duration, hasAudio) = await loadDurationAndAudioFlag(path: path)

            packageVideos.append(
                PackageManifest.PackageVideo(
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
                    )] : presentations,
                    edit: editMetadata(model: model, path: path),
                    duration: duration,
                    hasAudio: hasAudio
                )
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
            version: Self.currentVersion,
            manifest: .init(
                name: "Wallpaper Package",
                author: NSFullUserName(),
                createdAt: createdAt,
                description: "Exported wallpaper configuration",
                license: nil
            ),
            videos: packageVideos,
            playlists: packagePlaylists,
            packaging: .init(videosIncluded: includeVideos, packageSizeBytes: totalBytes)
        )
    }

    func buildSingleVideoManifest(
        model: WallpaperModel,
        videoPath: String,
        videoId: String,
        videoThumbnails: [String: String],
        fileSize: UInt64,
        license: String? = nil
    ) async -> PackageManifest {
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

        let (duration, hasAudio) = await loadDurationAndAudioFlag(path: videoPath)

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
            )] : presentations,
            edit: editMetadata(model: model, path: videoPath),
            duration: duration,
            hasAudio: hasAudio
        )

        return PackageManifest(
            version: Self.currentVersion,
            manifest: .init(
                name: model.registeredVideoDisplayName(for: videoPath),
                author: NSFullUserName(),
                createdAt: createdAt,
                description: "Exported single wallpaper",
                license: license
            ),
            videos: [packageVideo],
            playlists: [],
            packaging: .init(videosIncluded: true, packageSizeBytes: fileSize)
        )
    }
}

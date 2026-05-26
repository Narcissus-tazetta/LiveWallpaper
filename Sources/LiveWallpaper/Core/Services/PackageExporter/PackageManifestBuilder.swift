import CryptoKit
import Foundation

@MainActor
final class PackageManifestBuilder {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func buildManifest(
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

    func buildSingleVideoManifest(
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
            packaging: .init(videosIncluded: true, packageSizeBytes: fileSize)
        )
    }
}

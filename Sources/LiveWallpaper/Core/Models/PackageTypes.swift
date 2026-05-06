import Foundation

struct PackageManifest: Codable {
    let version: String
    let manifest: PackageInfo
    let videos: [PackageVideo]
    let playlists: [PackagePlaylist]
    let packaging: PackagingInfo

    struct PackageInfo: Codable {
        let name: String
        let author: String
        let createdAt: String
        let description: String
    }

    struct PackageVideo: Codable {
        let id: String
        let source: VideoSource
        let displayName: String
        let sha256: String?
        let thumbnail: String?
        let presentations: [String: ScreenPresentation]

        struct VideoSource: Codable {
            let fileName: String
            let size: UInt64?
        }

        struct ScreenPresentation: Codable {
            let fitMode: String
            let zoom: Double
            let offsetX: Double
            let offsetY: Double
        }
    }

    struct PackagePlaylist: Codable {
        let id: String
        let name: String
        let videoIds: [String]
        let shuffle: Bool
    }

    struct PackagingInfo: Codable {
        let videosIncluded: Bool
        let packageSizeBytes: UInt64?
    }
}

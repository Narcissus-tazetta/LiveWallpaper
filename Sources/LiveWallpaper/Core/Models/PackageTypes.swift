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
        /// 投稿者が意図するライセンス表記(例: "CC-BY-4.0")。nil = 著作権者に一任。
        var license: String?
    }

    struct PackageVideo: Codable {
        let id: String
        let source: VideoSource
        let displayName: String
        let sha256: String?
        let thumbnail: String?
        let presentations: [String: ScreenPresentation]
        /// 非破壊のトリム/ループ編集。既存(1.0)パッケージにはキー自体が無く nil になる。
        var edit: EditMetadata?
        /// 動画の長さ(秒)。ダウンロード前のStoreカタログ表示や編集範囲の検証に使う。
        var duration: Double?
        /// 音声トラックの有無。ダウンロード後の音声デフォルト挙動の判断材料。
        var hasAudio: Bool?

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

        struct EditMetadata: Codable {
            let trimStart: Double
            let trimEnd: Double?
            /// 任意。取り込み側はローカルの実尺で必ず検証し、範囲外なら捨てる
            /// (`PackageImporter.loopSafeLoopStart`)。
            let loopStart: Double?
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

import Foundation

struct StoreEntry: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let author: String
    let description: String?
    let sha256: String
    let sizeBytes: Int
    let durationSeconds: Double?
    let hasAudio: Bool?
    let license: String?
    let createdAt: String
    let downloadCount: Int
    let downloadURL: String
    let thumbnailURL: String?
}

struct StoreCatalogResponse: Decodable {
    let entries: [StoreEntry]
    let nextCursor: String?
}

enum StoreSortOption: String, CaseIterable, Identifiable {
    case newest
    case popular

    var id: String { rawValue }
}

/// GET /entries/:id/status のレスポンス。/catalog と違いstatus='published'に
/// 限定されない(投稿者自身が審査中/却下も確認できるように)。
struct StoreEntryStatusResponse: Decodable {
    let id: String
    let title: String
    let author: String
    let status: String
    let createdAt: String
}

/// この端末から送信したStore投稿のローカル記録。サーバー側は投稿者アカウントの
/// 概念を持たないため、「自分の投稿」一覧はこの端末が覚えているidをキーに
/// /entries/:id/status を都度引いて表示する。
struct StoreMySubmission: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let createdAt: String
    var lastKnownStatus: String
    /// DELETE /entries/:id/withdraw に必要な秘密トークン。この機能を追加する前に
    /// 保存されたローカル記録には無い(Codableの合成デコードでキー欠落時は自動的に
    /// nilになる)ため、nilの場合はサーバー側での取り下げができず、ローカルの
    /// リストから消すことしかできない。
    var withdrawToken: String?
}

/// store-worker側は理由を自由文字列として保存するのみ(store-worker/src/index.ts の
/// handleReport)なので、UIから送るローカライズキーをそのままreasonとして送信する。
enum StoreReportReason: String, CaseIterable, Identifiable {
    case inappropriate = "不適切なコンテンツ"
    case copyright = "著作権侵害の疑い"
    case spam = "スパムまたは無関係なコンテンツ"

    var id: String { rawValue }
    var localizationKey: String { rawValue }
}

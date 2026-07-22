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

/// store-worker側は理由を自由文字列として保存するのみ(store-worker/src/index.ts の
/// handleReport)なので、UIから送るローカライズキーをそのままreasonとして送信する。
enum StoreReportReason: String, CaseIterable, Identifiable {
    case inappropriate = "不適切なコンテンツ"
    case copyright = "著作権侵害の疑い"
    case spam = "スパムまたは無関係なコンテンツ"

    var id: String { rawValue }
    var localizationKey: String { rawValue }
}

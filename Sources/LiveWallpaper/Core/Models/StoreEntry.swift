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
}

struct StoreCatalogResponse: Decodable {
    let entries: [StoreEntry]
    let nextCursor: String?
}

import Foundation

struct WebWallpaperSource: Codable, Identifiable, Equatable {
    let id: UUID
    var url: URL
    var displayName: String
    var addedAt: Date

    init(url: URL, displayName: String? = nil) {
        self.id = UUID()
        self.url = url
        self.displayName = displayName ?? url.host ?? url.absoluteString
        self.addedAt = Date()
    }
}

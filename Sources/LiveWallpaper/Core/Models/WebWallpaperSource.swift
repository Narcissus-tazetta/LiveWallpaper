import Foundation

struct WebWallpaperSource: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var url: URL
    var displayName: String
    var addedAt: Date
    /// The entry can be nested; retaining its package root keeps file access inside
    /// the original package when its loopback URL is rebuilt on the next launch.
    var localFolderPath: String?
    var warnings: [String]?
    var thumbnailPath: String?

    init(id: UUID = UUID(), url: URL, displayName: String? = nil, localFolderPath: String? = nil, warnings: [String]? = nil, thumbnailPath: String? = nil) {
        self.id = id
        self.url = url
        self.displayName = displayName ?? url.host ?? url.absoluteString
        self.addedAt = Date()
        self.localFolderPath = localFolderPath
        self.warnings = warnings
        self.thumbnailPath = thumbnailPath
    }
}

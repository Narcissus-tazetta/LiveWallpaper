import Foundation

struct WallpaperPlaylist: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var videoPaths: [String]
}

import Foundation

struct WallpaperPlaylist: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var videoPaths: [String]
    var webWallpaperIDs: [UUID] = []

    private enum CodingKeys: String, CodingKey {
        case id, name, videoPaths, webWallpaperIDs
    }

    init(id: UUID, name: String, videoPaths: [String], webWallpaperIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.videoPaths = videoPaths
        self.webWallpaperIDs = webWallpaperIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        videoPaths = try container.decode([String].self, forKey: .videoPaths)
        webWallpaperIDs = try container.decodeIfPresent([UUID].self, forKey: .webWallpaperIDs) ?? []
    }
}

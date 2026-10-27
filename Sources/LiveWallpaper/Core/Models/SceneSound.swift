import Foundation

/// A sound the scene plays on its own, such as background music. Files sit in the scene
/// folder under plain names. Whether it plays at all follows the app's audio setting,
/// never the scene.
struct SceneSound: Codable, Equatable, Identifiable {
    static let maximumCount = 64
    static let maximumFiles = 64

    enum Mode: String, Codable {
        /// The files one after another, round and round.
        case loop
        /// One of the files now and then, after a pause between `minimumPause` and `maximumPause`.
        case random
        /// Only when something asks for it; a scene with no script never hears it.
        case single
    }

    var id = UUID()
    var name: String
    var files: [String]
    var mode: Mode = .loop
    /// 0...1, before the app's own volume.
    var volume: Double = 1
    var minimumPause: Double = 1
    var maximumPause: Double = 5
    /// `random` waits a pause before the first sound; `single` waits to be asked.
    var startsSilent = false
    /// A script sets the volume every frame, so the sound stays quiet until it has.
    var volumeIsScripted = false

    init(name: String, files: [String]) {
        self.name = name
        self.files = files
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        files = try c.decode([String].self, forKey: .files)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .loop
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        minimumPause = try c.decodeIfPresent(Double.self, forKey: .minimumPause) ?? 1
        maximumPause = try c.decodeIfPresent(Double.self, forKey: .maximumPause) ?? 5
        startsSilent = try c.decodeIfPresent(Bool.self, forKey: .startsSilent) ?? false
        volumeIsScripted = try c.decodeIfPresent(Bool.self, forKey: .volumeIsScripted) ?? false
        // Packages come from anyone: the names are opened inside the scene folder.
        guard files.count <= Self.maximumFiles,
              files.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("\\") && !$0.contains("\0") && $0 != "." && $0 != ".." }),
              [volume, minimumPause, maximumPause].allSatisfy(\.isFinite)
        else {
            throw DecodingError.dataCorruptedError(forKey: .files, in: c, debugDescription: "Invalid sound")
        }
        volume = min(max(volume, 0), 1)
        minimumPause = max(minimumPause, 0)
        maximumPause = max(maximumPause, minimumPause)
    }
}

extension SceneDocument {
    /// Some sounds start or get their volume only from a script, which needs the scene drawn live.
    var soundsNeedScripts: Bool {
        scripts.contains(where: \.canRun) && sounds.contains { $0.volumeIsScripted || $0.startsSilent }
    }
}

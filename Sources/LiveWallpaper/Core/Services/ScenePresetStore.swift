import Foundation

/// The user's presets: one folder per preset holding preset.json and copies of the
/// painted files it uses, so a preset outlives the scene it was made from.
struct ScenePresetStore {
    private static let documentFileName = "preset.json"

    let directory: URL

    static var standard: ScenePresetStore? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first.map {
            ScenePresetStore(directory: $0.appendingPathComponent("LiveWallpaper/ScenePresets", isDirectory: true))
        }
    }

    func folderURL(of id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Oldest first. A preset that cannot be read is skipped and logged, so one bad
    /// folder does not hide the rest.
    func loadAll() throws -> [ScenePreset] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        let folders = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
        )
        var loaded: [(Date, ScenePreset)] = []
        for folder in folders {
            let url = folder.appendingPathComponent(Self.documentFileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            do {
                let preset = try JSONDecoder().decode(ScenePreset.self, from: Data(contentsOf: url))
                let created = try folder.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
                loaded.append((created, preset))
            } catch {
                AppLog.persistence.error(
                    "scene preset unreadable path=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return loaded.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Writes the preset, copying the painted files it names from `sceneFolder`.
    func save(_ preset: ScenePreset, filesFrom sceneFolder: URL) throws {
        let staging = directory.appendingPathComponent(".\(preset.id.uuidString)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for name in preset.referencedFiles {
                try FileManager.default.copyItem(
                    at: sceneFolder.appendingPathComponent(name), to: staging.appendingPathComponent(name)
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(preset).write(to: staging.appendingPathComponent(Self.documentFileName))
            let destination = folderURL(of: preset.id)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        } catch {
            if FileManager.default.fileExists(atPath: staging.path) {
                do {
                    try FileManager.default.removeItem(at: staging)
                } catch let cleanupError {
                    AppLog.persistence.error(
                        "scene preset cleanup failed: \(cleanupError.localizedDescription, privacy: .public)"
                    )
                }
            }
            throw error
        }
    }

    func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: folderURL(of: id))
    }

    /// Copies the preset's files into the scene folder under new names and returns
    /// stored name → name in the scene. A missing file is left out (the preset then
    /// asks for that area to be painted).
    func copyFiles(of preset: ScenePreset, into sceneFolder: URL) throws -> [String: String] {
        var names: [String: String] = [:]
        for name in preset.referencedFiles {
            let source = folderURL(of: preset.id).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else {
                AppLog.persistence.error("scene preset file missing: \(source.path, privacy: .public)")
                continue
            }
            let ext = (name as NSString).pathExtension
            let prefix = name.split(separator: "-").first.map(String.init) ?? "paint"
            let newName = "\(prefix)-\(UUID().uuidString).\(ext.isEmpty ? "png" : ext)"
            try FileManager.default.copyItem(at: source, to: sceneFolder.appendingPathComponent(newName))
            names[name] = newName
        }
        return names
    }
}

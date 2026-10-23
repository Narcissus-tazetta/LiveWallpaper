import CryptoKit
import Foundation

/// What scene scripts keep with localStorage: per scene one global area and one per
/// screen, under one size limit together, kept across restarts. Values arrive as JSON
/// text from the script.
final class SceneScriptStorage: @unchecked Sendable {
    /// A value counts as its JSON's UTF-8 bytes plus 8, keys free, all areas of a
    /// scene together.
    static let capacity = 100_000
    static let entryOverhead = 8
    /// Scripts may write every frame; the file follows within this many seconds.
    static let saveDelay: TimeInterval = 1

    static let shared = SceneScriptStorage(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveWallpaper/SceneScriptStorage", isDirectory: true)
    )

    enum Area: Hashable, Codable {
        case global
        case screen(String)
    }

    /// One scene's values. Instances on several screens share it from their own threads.
    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        /// Held from encoding to writing, so a delayed save and a flush at quit cannot
        /// leave the older of two states in the file.
        private let saveLock = NSLock()
        private var areas: [Area: [Data: Data]]
        private var used: Int
        private let file: URL?
        private var isSavePending = false
        private var isDirty = false

        init(areas: [Area: [Data: Data]] = [:], file: URL?) {
            self.areas = areas
            self.file = file
            used = areas.values.reduce(0) { total, values in
                values.values.reduce(total) { $0 + $1.count + SceneScriptStorage.entryOverhead }
            }
        }

        func copy() -> Store {
            lock.withLock { Store(areas: areas, file: nil) }
        }

        func get(_ key: Data, in area: Area) -> Data? {
            lock.withLock { areas[area]?[key] }
        }

        /// false when it does not fit; the old value stays.
        func set(_ key: Data, _ value: Data, in area: Area) -> Bool {
            lock.withLock {
                let old = areas[area]?[key].map { $0.count + SceneScriptStorage.entryOverhead } ?? 0
                let next = used - old + value.count + SceneScriptStorage.entryOverhead
                guard next <= SceneScriptStorage.capacity else { return false }
                areas[area, default: [:]][key] = value
                used = next
                changed()
                return true
            }
        }

        func delete(_ key: Data, in area: Area) -> Bool {
            lock.withLock {
                guard let old = areas[area]?.removeValue(forKey: key) else { return false }
                used -= old.count + SceneScriptStorage.entryOverhead
                changed()
                return true
            }
        }

        func clear(_ cleared: Set<Area>) {
            lock.withLock {
                for area in cleared {
                    guard let values = areas.removeValue(forKey: area) else { continue }
                    used -= values.values.reduce(0) { $0 + $1.count + SceneScriptStorage.entryOverhead }
                    changed()
                }
            }
        }

        /// Called with the lock held.
        private func changed() {
            guard file != nil else { return }
            isDirty = true
            guard !isSavePending else { return }
            isSavePending = true
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + SceneScriptStorage.saveDelay) { [self] in
                save()
            }
        }

        func save() {
            guard let file else { return }
            saveLock.lock()
            defer { saveLock.unlock() }
            let data: Data
            do {
                data = try lock.withLock {
                    isSavePending = false
                    guard isDirty else { return Data() }
                    isDirty = false
                    return try PropertyListEncoder.binary.encode(areas)
                }
            } catch {
                AppLog.persistence.error("scene script storage encode failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard !data.isEmpty else { return }
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch {
                AppLog.persistence.error("scene script storage save failed \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// What one running instance of a scene uses: its screen's area, or, for an instance
    /// on no screen (the editor preview), the global area under both names.
    final class Session: @unchecked Sendable {
        let store: Store
        let screen: String?

        init(store: Store, screen: String?) {
            self.store = store
            self.screen = screen
        }

        /// Nothing kept, nothing saved.
        static func scratch() -> Session {
            Session(store: Store(file: nil), screen: nil)
        }

        func area(global: Bool) -> Area {
            global ? .global : screen.map(Area.screen) ?? .global
        }
    }

    private let directory: URL
    private let lock = NSLock()
    private var stores: [String: Store] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    func session(path: String, screen: String?) -> Session {
        Session(store: store(path: path), screen: screen)
    }

    /// Reads the saved values but keeps its writes to itself, for frames drawn ahead
    /// of time: a bake would otherwise advance the scene's values by every frame it draws.
    func snapshot(path: String, screen: String? = nil) -> Session {
        Session(store: store(path: path).copy(), screen: screen)
    }

    /// Writes every pending change now, for quitting.
    func flush() {
        for store in lock.withLock({ Array(stores.values) }) { store.save() }
    }

    private func store(path: String) -> Store {
        lock.withLock {
            let key = URL(fileURLWithPath: path).standardizedFileURL.path
            if let store = stores[key] { return store }
            let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            let file = directory.appendingPathComponent(digest + ".plist")
            var areas: [Area: [Data: Data]] = [:]
            if FileManager.default.fileExists(atPath: file.path) {
                do {
                    areas = try PropertyListDecoder().decode([Area: [Data: Data]].self, from: Data(contentsOf: file))
                } catch {
                    AppLog.persistence.error("scene script storage unreadable, starting empty \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            let store = Store(areas: areas, file: file)
            stores[key] = store
            return store
        }
    }
}

private extension PropertyListEncoder {
    static var binary: PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }
}

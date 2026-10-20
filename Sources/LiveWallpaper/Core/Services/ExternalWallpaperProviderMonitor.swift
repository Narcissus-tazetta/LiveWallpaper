import CryptoKit
import Foundation

/// A wallpaper another running app offers. It exists only while that app runs and is
/// never saved.
struct ExternalWallpaper: Identifiable, Equatable {
    /// Unique across providers: "<manifest file name>/<item id>".
    let id: String
    let providerName: String
    let name: String
    /// The video the desktop plays. For a scene it is where LiveWallpaper bakes it,
    /// and exists only once the scene is ready (WallpaperModel+ExternalWallpapers).
    /// Web items leave this empty because they have no video player.
    let path: String
    /// An image to show in lists; nil when the provider gave none or it is missing.
    var thumbnailPath: String?
    /// The provider's scene folder (scene.json and its images), for scene items.
    var sceneFolderPath: String?
    /// When the provider last wrote scene.json, so a rewritten scene is baked again.
    var sceneRevision: Date?
    var webSource: WebWallpaperSource?
    var providerPID: pid_t? = nil

    var isScene: Bool {
        sceneFolderPath != nil
    }
}

/// The JSON a provider app writes to `Providers/<anything>.json` in the app's
/// Application Support folder. Writing it atomically (write to a temporary file, then
/// rename) is what makes the folder report the change.
///
///     { "processIdentifier": 123, "name": "My Provider",
///       "wallpapers": [{ "id": "a", "name": "Rain", "path": "/abs/path/video.mp4",
///                        "thumbnail": "/abs/path/preview.jpg" },
///                      { "id": "b", "name": "Snow", "scene": "/abs/path/snow.scene" },
///                      { "id": "c", "name": "Clock", "web": "/abs/path/clock.web" }] }
///
/// Exactly one payload is required. Web packages contain web-wallpaper.json with
/// entryPoint, warnings and an optional preview. Modules and fetch need an HTTP
/// origin, so LiveWallpaper serves these folders through its loopback server.
struct ExternalWallpaperManifest: Decodable {
    struct Item: Decodable {
        let id: String
        let name: String
        let path: String?
        let scene: String?
        let web: String?
        let thumbnail: String?
    }

    let processIdentifier: Int32
    let name: String
    let wallpapers: [Item]
}

/// Watches the providers folder and reports the wallpapers of providers whose process
/// is still alive. A provider that quits or crashes drops out through its exit event,
/// so a manifest left behind by a dead process shows nothing.
@MainActor
final class ExternalWallpaperProviderMonitor {
    nonisolated static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveWallpaper/Providers", isDirectory: true)
    }

    private let directoryURL: URL
    private let onChange: ([ExternalWallpaper]) -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var exitSources: [pid_t: DispatchSourceProcess] = [:]

    init(
        directoryURL: URL = ExternalWallpaperProviderMonitor.directoryURL,
        onChange: @escaping ([ExternalWallpaper]) -> Void
    ) {
        self.directoryURL = directoryURL
        self.onChange = onChange
    }

    func start() {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            AppLog.externalWallpapers.error(
                "cannot create providers folder: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            AppLog.externalWallpapers.error("cannot watch providers folder errno=\(errno)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.rescan() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        directorySource = source
        rescan()
    }

    func rescan() {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            AppLog.externalWallpapers.error(
                "cannot list providers folder: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        var wallpapers: [ExternalWallpaper] = []
        var livePIDs = Set<pid_t>()
        for file in files {
            let manifest: ExternalWallpaperManifest
            do {
                manifest = try JSONDecoder().decode(
                    ExternalWallpaperManifest.self, from: Data(contentsOf: file)
                )
            } catch {
                AppLog.externalWallpapers.error(
                    "skipped provider \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
            let pid = manifest.processIdentifier
            guard pid > 0, Self.isAlive(pid) else {
                continue
            }
            livePIDs.insert(pid)
            watchExit(of: pid)
            for item in manifest.wallpapers {
                let id = "\(file.lastPathComponent)/\(item.id)"
                let thumbnail = item.thumbnail.flatMap { Self.isRegularFile($0) ? $0 : nil }
                if let path = item.path, item.scene == nil, item.web == nil, Self.isRegularFile(path) {
                    wallpapers.append(ExternalWallpaper(
                        id: id, providerName: manifest.name, name: item.name, path: path, thumbnailPath: thumbnail,
                        providerPID: pid
                    ))
                } else if let scene = item.scene, item.path == nil, item.web == nil,
                          let revision = Self.sceneRevision(folder: scene)
                {
                    wallpapers.append(ExternalWallpaper(
                        id: id, providerName: manifest.name, name: item.name,
                        path: Self.bakedScenePath(forID: id), thumbnailPath: thumbnail,
                        sceneFolderPath: scene, sceneRevision: revision,
                        providerPID: pid
                    ))
                } else if let web = item.web, item.path == nil, item.scene == nil {
                    do {
                        let folder = URL(fileURLWithPath: web, isDirectory: true)
                        let package = try LocalWebWallpaperPackage.load(folder: folder)
                        let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
                        let text = "\(hash.prefix(8))-\(hash.dropFirst(8).prefix(4))-\(hash.dropFirst(12).prefix(4))-\(hash.dropFirst(16).prefix(4))-\(hash.dropFirst(20).prefix(12))"
                        var source = WebWallpaperSource(
                            id: UUID(uuidString: text)!, url: folder.appendingPathComponent(package.entryPoint),
                            displayName: item.name, localFolderPath: folder.path, warnings: package.warnings,
                            thumbnailPath: package.preview.map { folder.appendingPathComponent($0).path }
                        )
                        source.addedAt = Date(timeIntervalSince1970: 0)
                        wallpapers.append(ExternalWallpaper(
                            id: id, providerName: manifest.name, name: item.name, path: "",
                            thumbnailPath: thumbnail ?? source.thumbnailPath, webSource: source,
                            providerPID: pid
                        ))
                    } catch {
                        AppLog.externalWallpapers.error("invalid web package of \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                } else {
                    AppLog.externalWallpapers.error(
                        "skipped item \(item.id, privacy: .public) of \(file.lastPathComponent, privacy: .public): needs one existing path, scene or web package"
                    )
                }
            }
        }
        for (pid, source) in exitSources where !livePIDs.contains(pid) {
            source.cancel()
            exitSources.removeValue(forKey: pid)
        }
        onChange(wallpapers)
    }

    private func watchExit(of pid: pid_t) {
        guard exitSources[pid] == nil else {
            return
        }
        let source = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.rescan() }
        }
        source.resume()
        exitSources[pid] = source
    }

    /// LiveWallpaper's own copies of the scenes providers offer, baked into videos.
    /// Kept apart from the library folder, so clearing the cache or restoring the
    /// library never meets them; emptied on launch and as providers go away.
    nonisolated static var bakedScenesDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveWallpaper/ExternalScenes", isDirectory: true)
    }

    struct BakedSceneMeta: Codable, Equatable {
        var sceneRevision: Date
        var appSignature: String
    }

    nonisolated static var currentAppSignature: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version)-\(build)"
    }

    /// One folder per item, named by a hash: item IDs are the provider's strings.
    nonisolated static func bakedScenePath(forID id: String) -> String {
        let digest = SHA256.hash(data: Data(id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return bakedScenesDirectoryURL.appendingPathComponent(digest, isDirectory: true)
            .appendingPathComponent("wallpaper.mp4").path
    }

    nonisolated static func bakedSceneMetaURL(forID id: String) -> URL {
        URL(fileURLWithPath: bakedScenePath(forID: id)).deletingLastPathComponent().appendingPathComponent("bake_meta.json")
    }

    private static func sceneRevision(folder: String) -> Date? {
        guard folder.hasPrefix("/") else {
            return nil
        }
        let document = URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("scene.json")
        return try? FileManager.default.attributesOfItem(atPath: document.path)[.modificationDate] as? Date
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func isRegularFile(_ path: String) -> Bool {
        guard path.hasPrefix("/") else {
            return false
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}

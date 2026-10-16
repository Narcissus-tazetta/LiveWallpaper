import Foundation

/// A wallpaper another running app offers. It exists only while that app runs and is
/// never saved.
struct ExternalWallpaper: Identifiable, Equatable {
    /// Unique across providers: "<manifest file name>/<item id>".
    let id: String
    let providerName: String
    let name: String
    let path: String
    /// An image to show in lists; nil when the provider gave none or it is missing.
    var thumbnailPath: String?
}

/// The JSON a provider app writes to `Providers/<anything>.json` in the app's
/// Application Support folder. Writing it atomically (write to a temporary file, then
/// rename) is what makes the folder report the change.
///
///     { "processIdentifier": 123, "name": "My Provider",
///       "wallpapers": [{ "id": "a", "name": "Rain", "path": "/abs/path/video.mp4",
///                        "thumbnail": "/abs/path/preview.jpg" }] }
///
/// `thumbnail` is optional.
struct ExternalWallpaperManifest: Decodable {
    struct Item: Decodable {
        let id: String
        let name: String
        let path: String
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
                guard Self.isRegularFile(item.path) else {
                    AppLog.externalWallpapers.error(
                        "skipped item \(item.id, privacy: .public) of \(file.lastPathComponent, privacy: .public): not a file"
                    )
                    continue
                }
                wallpapers.append(ExternalWallpaper(
                    id: "\(file.lastPathComponent)/\(item.id)",
                    providerName: manifest.name,
                    name: item.name,
                    path: item.path,
                    thumbnailPath: item.thumbnail.flatMap { Self.isRegularFile($0) ? $0 : nil }
                ))
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

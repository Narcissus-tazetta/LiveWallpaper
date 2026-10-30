import Foundation

/// Folders the user picks for a web wallpaper's `directory` properties.
///
/// Pages are written for the original on Windows, which hands them `C:/…` folder values and
/// `C%3A/…` file entries that they prefix with `file:///`. A Mac path fits neither the drive
/// checks pages run nor that prefix, so pages see each folder under a drive of its own, and the
/// host runtime sends the resulting `file:///Z:/…` loads to the local server.
enum LocalWebUserDirectory {
    struct Selection: Equatable {
        var path: String
        var fileType: String?
    }

    static let drive = "Z:"
    static let servedPrefix = "_userdir"

    static func pageValue(path: String) -> String {
        path.isEmpty ? "" : drive + standardized(path)
    }

    /// The original escapes the colon, spaces and `&` and leaves non-ASCII letters as they are.
    /// Which other ASCII characters it escapes is unmeasured; this escapes every reserved one.
    static func pageFile(path: String) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/".utf8)
        var result = "Z%3A"
        for scalar in standardized(path).unicodeScalars {
            if scalar.isASCII, !unreserved.contains(UInt8(scalar.value)) {
                result += String(format: "%%%02X", scalar.value)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    // Measured: `image` folders list PNG and GIF and leave out WebM; `video` folders list WebM.
    // The rest of each set is assumed.
    private static let extensions: [String: Set<String>] = [
        "image": ["jpg", "jpeg", "png", "pnga", "gif", "webp", "bmp", "svg"],
        "video": ["webm", "mp4", "m4v", "mov", "ogv", "ogg"],
    ]

    /// Files directly inside the folder, with their modification dates. Whether the original
    /// also lists subfolders is unmeasured.
    static func listing(of selection: Selection) throws -> [String: Date] {
        let folder = URL(fileURLWithPath: selection.path, isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let allowed = selection.fileType.flatMap { extensions[$0] }
        var files: [String: Date] = [:]
        for url in try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            if let allowed, !allowed.contains(url.pathExtension.lowercased()) { continue }
            files[pageFile(path: url.path)] = values.contentModificationDate ?? .distantPast
        }
        return files
    }

    /// Whether a served path lies inside one of the chosen folders.
    static func file(_ path: String, inside folders: [URL]) -> URL? {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard folders.contains(where: {
            url.path.hasPrefix($0.standardizedFileURL.resolvingSymlinksInPath().path + "/")
        }),
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { return nil }
        return url
    }

    private static func standardized(_ path: String) -> String {
        let value = URL(fileURLWithPath: path).standardizedFileURL.path
        return value.count > 1 && value.hasSuffix("/") ? String(value.dropLast()) : value
    }
}

/// Lists a chosen folder and lists it again whenever its entries change.
@MainActor
final class LocalWebDirectoryWatcher {
    private let selection: LocalWebUserDirectory.Selection
    private let onChange: ([String: Date]) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var generation = 0

    init(selection: LocalWebUserDirectory.Selection, onChange: @escaping ([String: Date]) -> Void) {
        self.selection = selection
        self.onChange = onChange
        let descriptor = open(selection.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main
            )
            source.setEventHandler { [weak self] in self?.scheduleScan() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            self.source = source
        } else {
            AppLog.externalWallpapers.error(
                "web folder watch failed: \(String(cString: strerror(errno)), privacy: .public)"
            )
        }
        scan()
    }

    isolated deinit {
        source?.cancel()
    }

    func stop() {
        generation += 1
        pending?.cancel()
        source?.cancel()
        source = nil
    }

    private func scheduleScan() {
        // Copying a batch of files fires once per file; one listing covers the burst.
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func scan() {
        generation += 1
        let current = generation
        let selection = selection
        Task.detached(priority: .utility) {
            let files: [String: Date]
            do { files = try LocalWebUserDirectory.listing(of: selection) }
            catch {
                AppLog.externalWallpapers.error(
                    "web folder listing failed: \(error.localizedDescription, privacy: .public)"
                )
                files = [:]
            }
            await MainActor.run { [weak self] in
                guard let self, self.generation == current else { return }
                self.onChange(files)
            }
        }
    }
}

import Foundation
import os

/// Finds the image a package should be represented by, without extracting the archive.
enum PackageThumbnailLocator {
    static let maxManifestSize: UInt64 = 4 * 1024 * 1024
    static let maxThumbnailSize: UInt64 = 8 * 1024 * 1024
    private static let logger = Logger(
        subsystem: "com.sakana.livewallpaper.QuickLookThumbnail",
        category: "thumbnail"
    )

    /// Returns nil when the package has no usable thumbnail; malformed archives throw.
    static func thumbnailData(in url: URL) throws -> Data? {
        let archive = try ZipArchiveReader(url: url)
        // Skip AppleDouble files ("._x.png"): ditto writes them next to the real file when it
        // archives without --sequesterRsrc, and they would sort ahead of the real preview.
        let files = archive.entries.filter { entry in
            !entry.name.hasSuffix("/") && !entry.name.hasPrefix("__MACOSX/")
                && !(entry.name.split(separator: "/").last ?? "").hasPrefix("._")
        }
        var byName: [String: ZipArchiveReader.Entry] = [:]
        for entry in files where byName[entry.name] == nil {
            byName[entry.name] = entry
        }

        var candidates: [String] = []
        // The exporter archives with --keepParent, so the manifest normally sits one
        // directory deep ("content/metadata.json"); thumbnail paths are relative to it.
        if let manifest = manifestEntry(in: files) {
            let base = String(manifest.name.dropLast("metadata.json".count))
            let json = try archive.data(for: manifest, maxSize: maxManifestSize)
            candidates += thumbnailPaths(inManifest: json).map { base + normalized($0) }
        }
        candidates += files
            .map(\.name)
            .filter { isPreviewImage($0) }
            .sorted()

        var seen = Set<String>()
        for path in candidates where seen.insert(path).inserted {
            guard let entry = byName[path] else { continue }
            return try archive.data(for: entry, maxSize: maxThumbnailSize)
        }
        return nil
    }

    private static func manifestEntry(in files: [ZipArchiveReader.Entry]) -> ZipArchiveReader
        .Entry?
    {
        files
            .filter { entry in
                let parts = entry.name.split(separator: "/", omittingEmptySubsequences: false)
                return parts.last == "metadata.json" && parts.count <= 2
            }
            .min { $0.name.count < $1.name.count }
    }

    private static func isPreviewImage(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 3,
              parts[parts.count - 2] == "previews" else { return false }
        return parts.last!.lowercased().hasSuffix(".png")
    }

    private static func normalized(_ path: String) -> String {
        path.hasPrefix("./") ? String(path.dropFirst(2)) : path
    }

    /// Video thumbnails first, then any other "thumbnail" string anywhere in the manifest
    /// (newer package versions attach them to other kinds of wallpaper).
    static func thumbnailPaths(inManifest json: Data) -> [String] {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: json)
        } catch {
            // Still worth showing a preview image if the archive has one.
            logger
                .error(
                    "metadata.json is not valid JSON: \(error.localizedDescription, privacy: .public)"
                )
            return []
        }
        guard let root = parsed as? [String: Any] else { return [] }
        var paths: [String] = []
        if let videos = root["videos"] as? [[String: Any]] {
            paths += videos.compactMap { $0["thumbnail"] as? String }.filter { !$0.isEmpty }
        }
        collectThumbnails(in: root, into: &paths)
        return paths
    }

    private static func collectThumbnails(in value: Any, into paths: inout [String]) {
        if let dictionary = value as? [String: Any] {
            if let path = dictionary["thumbnail"] as? String, !path.isEmpty {
                paths.append(path)
            }
            for key in dictionary.keys.sorted() {
                collectThumbnails(in: dictionary[key]!, into: &paths)
            }
        } else if let array = value as? [Any] {
            for element in array {
                collectThumbnails(in: element, into: &paths)
            }
        }
    }
}

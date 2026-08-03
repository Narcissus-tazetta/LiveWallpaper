import Foundation

/// Aerial(ダイナミック壁紙)ディレクトリと manifest の探索、
/// 借用可能なダウンロード済みアセットの選定。
struct AerialManifestResolver {
    struct AerialsPaths {
        let baseURL: URL
        let videosDirectory: URL
        let entriesURL: URL
    }

    private struct ManifestAsset {
        let id: String
        let name: String
        let preferredOrder: Int
    }

    private let fileManager: FileManager
    private let injectedAerialsBaseURL: URL?

    private let preferredBorrowedAerialIDs = [
        "4C108785-A7BA-422E-9C79-B0129F1D5550",
        "6D6834A4-2F0F-479A-B053-7D4DC5CB8EB7"
    ]

    init(fileManager: FileManager, aerialsBaseURL: URL?) {
        self.fileManager = fileManager
        self.injectedAerialsBaseURL = aerialsBaseURL
    }

    func resolvePaths() throws -> AerialsPaths {
        let baseURL: URL
        if let injectedAerialsBaseURL {
            baseURL = injectedAerialsBaseURL
        } else {
            guard let appSupportURL = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw LockScreenSyncError.applicationSupportUnavailable
            }
            baseURL = appSupportURL
                .appendingPathComponent("com.apple.wallpaper", isDirectory: true)
                .appendingPathComponent("aerials", isDirectory: true)
        }

        return AerialsPaths(
            baseURL: baseURL,
            videosDirectory: baseURL.appendingPathComponent("videos", isDirectory: true),
            entriesURL: baseURL
                .appendingPathComponent("manifest", isDirectory: true)
                .appendingPathComponent("entries.json")
        )
    }

    func prepareAerialsDirectories(_ paths: AerialsPaths) throws {
        guard fileManager.fileExists(atPath: paths.baseURL.path) else {
            throw LockScreenSyncError.aerialsDirectoryMissing(paths.baseURL)
        }
        guard fileManager.fileExists(atPath: paths.entriesURL.path) else {
            throw LockScreenSyncError.manifestMissing(paths.entriesURL)
        }
        try fileManager.createDirectory(
            at: paths.videosDirectory,
            withIntermediateDirectories: true
        )
    }

    func detectBorrowableAerial(in paths: AerialsPaths) throws -> BorrowedAerialAsset {
        let manifestAssets = try loadManifestAssets(paths.entriesURL)
        let downloadedIDs = try downloadedAerialIDs(in: paths.videosDirectory)
        let candidates = manifestAssets
            .filter { downloadedIDs.contains($0.id) }
            .map { asset in
                BorrowedAerialAsset(
                    id: asset.id,
                    name: asset.name,
                    videoURL: paths.videosDirectory
                        .appendingPathComponent(asset.id)
                        .appendingPathExtension("mov")
                )
            }

        guard !candidates.isEmpty else {
            throw LockScreenSyncError.noDownloadedAerials
        }

        for preferredID in preferredBorrowedAerialIDs {
            if let candidate = candidates.first(where: { $0.id == preferredID }) {
                return candidate
            }
        }

        return candidates.sorted { lhs, rhs in
            let leftOrder = manifestAssets.first(where: { $0.id == lhs.id })?.preferredOrder ?? Int.max
            let rightOrder = manifestAssets.first(where: { $0.id == rhs.id })?.preferredOrder ?? Int.max
            return leftOrder < rightOrder
        }.first!
    }

    private func loadManifestAssets(_ entriesURL: URL) throws -> [ManifestAsset] {
        let data = try Data(contentsOf: entriesURL)
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawAssets = manifest["assets"] as? [[String: Any]]
        else {
            throw LockScreenSyncError.invalidManifest(entriesURL)
        }

        return rawAssets.compactMap { rawAsset in
            guard let id = rawAsset["id"] as? String else {
                return nil
            }
            let name = (rawAsset["accessibilityLabel"] as? String)
                ?? (rawAsset["localizedNameKey"] as? String)
                ?? id
            let preferredOrder = rawAsset["preferredOrder"] as? Int ?? Int.max
            return ManifestAsset(id: id, name: name, preferredOrder: preferredOrder)
        }
    }

    private func downloadedAerialIDs(in videosDirectory: URL) throws -> Set<String> {
        let urls = try fileManager.contentsOfDirectory(
            at: videosDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return Set(
            urls
                .filter { $0.pathExtension.lowercased() == "mov" }
                .map { $0.deletingPathExtension().lastPathComponent }
        )
    }
}

import Foundation

@MainActor
extension WallpaperModel {
    func localWebConfiguration(for source: WebWallpaperSource) throws
        -> (LocalWebWallpaperPackage, LocalWebSettings)
    {
        let package = try LocalWebWallpaperPackage
            .load(folder: URL(fileURLWithPath: source.localFolderPath!))
        return try (package, LocalWebSettings.load(id: source.id))
    }

    func saveLocalWebSettings(_ settings: LocalWebSettings, source: WebWallpaperSource) throws {
        try settings.save(id: source.id)
        refreshLocalWebEnvironment()
    }

    func configureLocalWebProperties(_ view: WebPlayerView) {
        guard let source = activeWebWallpaperSource, source.localFolderPath != nil else { return }
        do {
            let (package, settings) = try localWebConfiguration(for: source)
            var values = Dictionary(uniqueKeysWithValues: (package.properties ?? []).map { (
                $0.id,
                $0.value
            ) })
            values.merge(settings.values) { _, new in new }
            view.setLocalConfiguration(
                values: values,
                settings: settings,
                assets: (package.properties ?? []).filter { $0.kind == "file" }.map(\.id)
            )
        } catch {
            webWallpaperErrorMessage = error.localizedDescription
            AppLog.externalWallpapers
                .error("web settings failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func importLocalWebPropertyFile(_ url: URL, source: WebWallpaperSource) async throws -> String {
        let folder = URL(fileURLWithPath: source.localFolderPath!)
        let relative = ".livewallpaper-assets/\(UUID().uuidString).\(url.pathExtension)"
        let destination = folder.appendingPathComponent(relative)
        try await Task.detached(priority: .userInitiated) {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: url, to: destination)
        }.value
        return relative
    }
}

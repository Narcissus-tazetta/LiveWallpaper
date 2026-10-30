import Foundation

@MainActor
extension WallpaperModel {
    /// Copies a hand-written page folder into the library so the page keeps working when the
    /// original is moved or edited; re-adding the folder picks up changes.
    @discardableResult
    func addLocalWebWallpaper(folder: URL) async -> Bool {
        let destination = LocalWebWallpaperPackage.libraryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try await Task.detached(priority: .userInitiated) {
                try LocalWebWallpaperPackage.copy(from: folder, to: destination)
            }.value
            let package = try LocalWebWallpaperPackage.load(folder: destination)
            let source = WebWallpaperSource(
                url: destination.appendingPathComponent(package.entryPoint),
                displayName: folder.lastPathComponent,
                localFolderPath: destination.path,
                warnings: package.warnings,
                thumbnailPath: package.preview.map { destination.appendingPathComponent($0).path }
            )
            webWallpaperSources.append(source)
            webWallpaperErrorMessage = nil
            if selectedPlaylistID == nil { syncActivePlaylistPaths() }
            selectWebWallpaper(id: source.id)
            persistWebWallpaperState()
            return true
        } catch {
            removeLeftovers(of: [destination])
            webWallpaperErrorMessage = error.localizedDescription
            AppLog.externalWallpapers
                .error("could not add web folder: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

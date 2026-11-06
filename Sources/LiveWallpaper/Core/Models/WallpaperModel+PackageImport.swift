import Foundation

@MainActor
extension WallpaperModel {
    /// Adds without selecting it; the import picks what to show once everything is in.
    /// A page on the web that is already in the library is reused, as when adding by hand.
    /// - Returns: the id the library knows the wallpaper by.
    func addImportedWebWallpaper(_ source: WebWallpaperSource) -> UUID {
        if source.localFolderPath == nil {
            let key = WebWallpaperURLResolver.canonicalKey(for: source.url)
            if let existing = webWallpaperSources.first(where: {
                $0.localFolderPath == nil && WebWallpaperURLResolver
                    .canonicalKey(for: $0.url) == key
            }) {
                return existing.id
            }
        }
        webWallpaperSources.append(source)
        // Off by default, and while off the library hides Web wallpapers: the import the
        // user just accepted would otherwise look like it added nothing.
        setWebWallpaperFeatureEnabled(true)
        if selectedPlaylistID == nil { syncActivePlaylistPaths() }
        persistWebWallpaperState()
        return source.id
    }

    /// The presets are already saved in the store.
    func addImportedScenePresets(_ presets: [ScenePreset]) {
        guard !presets.isEmpty else { return }
        if userScenePresets == nil {
            loadUserScenePresetsIfNeeded()
        } else {
            userScenePresets?.append(contentsOf: presets)
        }
    }
}

import Foundation

/// Resolves wallpapers and playlists by display name for the URL scheme.
@MainActor
extension WallpaperModel {
    /// Searches the whole library (web wallpapers only while that feature is on),
    /// not just the play queue, so wallpapers outside the selected playlist can be named.
    func automationWallpaperMatch(named name: String) -> AutomationNameMatch<WallpaperPlaybackEntry> {
        var candidates: [(id: WallpaperPlaybackEntry, name: String)] = libraryVideoPaths.map {
            (id: .video($0), name: registeredVideoDisplayName(for: $0))
        }
        if webWallpaperFeatureEnabled {
            candidates += webWallpaperSources.map { (id: .web($0.id), name: $0.displayName) }
        }
        return AutomationNameResolver.resolve(name, among: candidates)
    }

    /// A `.unique(nil)` result means "All Wallpapers" (no playlist selected).
    func automationPlaylistMatch(named name: String) -> AutomationNameMatch<UUID?> {
        let allAliases = ["all", localizedString("すべての壁紙")]
        let candidates: [(id: UUID?, name: String)] =
            allAliases.map { (id: nil, name: $0) } + playlists.map { (id: $0.id, name: $0.name) }
        return AutomationNameResolver.resolve(name, among: candidates)
    }
}

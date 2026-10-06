import Foundation

/// URL スキームから表示名で壁紙・プレイリストを選ぶための解決。
@MainActor
extension WallpaperModel {
    /// ライブラリ全体(Web壁紙は機能が有効なときのみ)から表示名で探す。
    /// 選択中プレイリストの外にある壁紙も指定できるよう、再生キューではなく
    /// ライブラリを対象にする。
    func automationWallpaperMatch(named name: String) -> AutomationNameMatch<WallpaperPlaybackEntry> {
        var candidates: [(id: WallpaperPlaybackEntry, name: String)] = libraryVideoPaths.map {
            (id: .video($0), name: registeredVideoDisplayName(for: $0))
        }
        if webWallpaperFeatureEnabled {
            candidates += webWallpaperSources.map { (id: .web($0.id), name: $0.displayName) }
        }
        return AutomationNameResolver.resolve(name, among: candidates)
    }

    /// nil の `.unique` は「すべての壁紙」(プレイリスト未選択)を表す。
    func automationPlaylistMatch(named name: String) -> AutomationNameMatch<UUID?> {
        let allAliases = ["all", localizedString("すべての壁紙")]
        let candidates: [(id: UUID?, name: String)] =
            allAliases.map { (id: nil, name: $0) } + playlists.map { (id: $0.id, name: $0.name) }
        return AutomationNameResolver.resolve(name, among: candidates)
    }
}

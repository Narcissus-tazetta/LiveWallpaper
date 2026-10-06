import AppKit

/// `livewallpaper://` URL スキームによる外部自動化。
///
/// これにより、ショートカット.app の「URL を開く」、Raycast、`open` コマンド、
/// AppleScript などから壁紙の操作ができる。AppIntents 方式はメタデータ抽出が
/// Xcode ビルド前提で SwiftPM 構成では露出しないため、確実に動く URL スキームを
/// 自動化の入口として採用している。
///
/// 例:
///   open "livewallpaper://next"
///   open "livewallpaper://volume?level=0.3"
///   open "livewallpaper://audio?on=1"
///   open "livewallpaper://set?name=Ocean"
extension AppDelegate {
    static let urlScheme = "livewallpaper"

    func setupURLSchemeHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc func handleGetURLEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent _: NSAppleEventDescriptor
    ) {
        guard
            let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let url = URL(string: urlString)
        else {
            return
        }
        handleAutomationURL(url)
    }

    /// Runs the action for the URL. URLs it cannot interpret do nothing and report failure.
    func handleAutomationURL(_ url: URL) {
        guard url.scheme?.lowercased() == Self.urlScheme else {
            return
        }
        // host が無い形(livewallpaper:next 等)にも一応対応する。
        let command = (url.host ?? url.path.replacingOccurrences(of: "/", with: ""))
            .lowercased()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        func boolParam(_ names: [String]) -> Bool? {
            guard let value = queryItems.first(where: { names.contains($0.name.lowercased()) })?.value?
                .lowercased()
            else {
                return nil
            }
            switch value {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default: return nil
            }
        }

        func stringParam(_ name: String) -> String? {
            queryItems.first(where: { $0.name.lowercased() == name })?.value
        }

        switch command {
        case "pause":
            wallpaperModel.setManualPauseActive(true)
        case "resume", "play":
            wallpaperModel.setManualPauseActive(false)
        case "toggle-pause", "play-pause":
            wallpaperModel.toggleManualPause()
        case "set", "set-wallpaper":
            selectWallpaperByName(stringParam("name"))
        case "set-playlist":
            selectPlaylistByName(stringParam("name"))
        case "next", "next-wallpaper":
            wallpaperModel.playNextVideo()
        case "previous", "prev", "previous-wallpaper":
            wallpaperModel.playPreviousVideo()
        case "audio":
            if let value = boolParam(["on", "enabled", "value"]) {
                setAudioEnabled(value)
            } else {
                toggleAudioEnabled()
            }
        case "volume":
            if let level = queryItems.first(where: { $0.name.lowercased() == "level" })?.value,
               let value = Float(level)
            {
                wallpaperModel.setAudioVolume(min(max(value, 0), 1))
            }
        case "desktop-icons":
            wallpaperModel.setDesktopIconsVisible(
                boolParam(["visible", "on", "value"]) ?? !wallpaperModel.desktopIconsVisible
            )
        case "playlist":
            if let value = boolParam(["on", "enabled", "value"]) {
                wallpaperModel.setPlaylistPlaybackEnabled(value)
            } else {
                togglePlaylistPlayback()
            }
        case "shuffle":
            if let value = boolParam(["on", "enabled", "value"]) {
                wallpaperModel.setShufflePlaybackEnabled(value)
            } else {
                toggleShufflePlayback()
            }
        case "refresh":
            wallpaperModel.refreshPlaybackState()
        case "open-settings", "settings":
            openSettings()
        case "open-wallpaper", "wallpaper":
            openWallpaperTab()
        default:
            reportAutomationFailure("unknown command \(command)")
        }
    }

    private func selectWallpaperByName(_ name: String?) {
        guard let name else {
            reportAutomationFailure("set: missing name parameter")
            return
        }
        switch wallpaperModel.automationWallpaperMatch(named: name) {
        case let .unique(entry):
            wallpaperModel.selectPlaybackEntry(entry, clearsPin: true)
        case .notFound:
            reportAutomationFailure("set: no wallpaper named \(name)")
        case let .ambiguous(names):
            reportAutomationFailure("set: \(name) matches \(names)")
        }
    }

    private func selectPlaylistByName(_ name: String?) {
        guard let name else {
            reportAutomationFailure("set-playlist: missing name parameter")
            return
        }
        switch wallpaperModel.automationPlaylistMatch(named: name) {
        case let .unique(playlistID):
            wallpaperModel.selectPlaylist(playlistID)
        case .notFound:
            reportAutomationFailure("set-playlist: no playlist named \(name)")
        case let .ambiguous(names):
            reportAutomationFailure("set-playlist: \(name) matches \(names)")
        }
    }

    /// A URL scheme cannot return a result to its caller, so instead of failing
    /// silently, beep and log the cause (`log show --predicate 'category == "automation"'`).
    private func reportAutomationFailure(_ message: String) {
        AppLog.automation.error("\(message, privacy: .public)")
        NSSound.beep()
    }
}

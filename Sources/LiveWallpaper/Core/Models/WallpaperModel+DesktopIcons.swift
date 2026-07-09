import Foundation

@MainActor
extension WallpaperModel {
    func refreshDesktopIconsVisibility() {
        desktopIconsVisible = desktopIconsService.isDesktopIconsVisible()
        desktopIconsFailureMessage = nil
    }

    func setDesktopIconsVisible(_ visible: Bool) {
        let previous = desktopIconsVisible
        guard previous != visible else {
            return
        }
        do {
            try desktopIconsService.setDesktopIconsVisible(visible)
            desktopIconsVisible = visible
            desktopIconsFailureMessage = nil
            scheduleFinderRestartWindowRefresh()
        } catch {
            desktopIconsVisible = desktopIconsService.isDesktopIconsVisible()
            desktopIconsFailureMessage = localizedString(
                "デスクトップのアイコン表示を変更できませんでした。Finder 設定へのアクセスを確認してください。"
            )
            AppLog.desktopIcons.error(
                "failed to set visible=\(visible, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

import AppKit
import Combine

extension AppDelegate {
    /// Scenes saved by a newer app are left unloaded, so without this they would look like
    /// plain videos that lost their editor. Told once per launch, as a sheet for the same
    /// reason as the script approval: a modal alert would stop the wallpaper.
    func setupNewerSceneNotice() {
        wallpaperModel.$scenesFromNewerVersion
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.presentNewerSceneNotice() }
            .store(in: &cancellables)
    }

    private func presentNewerSceneNotice() {
        guard !wallpaperModel.scenesFromNewerVersion.isEmpty else { return }
        openSettings()
        guard let window = settingsWindowController?.window else { return }
        guard window.attachedSheet == nil else {
            window.afterAttachedSheetEnds { [weak self] in self?.presentNewerSceneNotice() }
            return
        }
        wallpaperModel.scenesFromNewerVersion = []
        let alert = NSAlert()
        alert.messageText = localized("新しい版のLiveWallpaperで作られたシーンがあります")
        alert.informativeText = localized("この版では編集できません。動画としては再生できます。LiveWallpaperを更新すると編集できます。")
        alert.addButton(withTitle: localized("閉じる"))
        alert.beginSheetModal(for: window)
    }
}

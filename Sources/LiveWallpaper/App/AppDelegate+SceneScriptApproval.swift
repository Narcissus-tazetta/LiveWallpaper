import AppKit
import Combine

extension AppDelegate {
    /// A downloaded scene with JavaScript asks before it runs. The question is a sheet
    /// on the settings window: a modal alert would stop the main queue, and with it
    /// the wallpaper.
    func setupSceneScriptApprovalPrompts() {
        wallpaperModel.$sceneScriptApprovalRequests
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.presentNextSceneScriptApproval() }
            .store(in: &cancellables)
    }

    private func presentNextSceneScriptApproval() {
        guard let request = wallpaperModel.sceneScriptApprovalRequests.first,
              !isPresentingSceneScriptApproval
        else { return }
        openSettings()
        guard let window = settingsWindowController?.window else { return }
        guard window.attachedSheet == nil else {
            // Another sheet is up; ask once it is gone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.presentNextSceneScriptApproval() }
            return
        }
        isPresentingSceneScriptApproval = true
        let alert = NSAlert()
        alert.messageText = String(format: localized("「%@」のJavaScriptを実行しますか？"), request.name)
        alert.informativeText = localized("この壁紙は、動きや表示をJavaScriptで変えます。許可すると、この壁紙を表示するたびに自動で実行します。あとからシーン編集の「スクリプト(JavaScript)」で止められます。")
        alert.addButton(withTitle: localized("実行を許可"))
        alert.addButton(withTitle: localized("許可しない"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            isPresentingSceneScriptApproval = false
            wallpaperModel.answerSceneScriptApproval(request, allow: response == .alertFirstButtonReturn)
        }
    }
}

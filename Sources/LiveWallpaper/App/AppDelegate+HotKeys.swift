import AppKit
import Combine

extension AppDelegate {
    /// グローバルホットキーの初期化。モデルの設定変更(有効/無効・割り当て)を
    /// 監視し、その都度 Carbon 登録を貼り直す。
    func setupGlobalHotKeys() {
        let center = GlobalHotKeyCenter()
        hotKeyCenter = center

        Publishers.CombineLatest(wallpaperModel.$hotKeysEnabled, wallpaperModel.$hotKeyCombos)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.reloadGlobalHotKeys()
            }
            .store(in: &cancellables)
    }

    /// 現在のモデル状態に合わせて全ホットキーを登録し直す。登録に失敗した操作は
    /// モデルへ記録し、設定UIで気づけるようにする。
    func reloadGlobalHotKeys() {
        guard let center = hotKeyCenter else {
            return
        }
        center.unregisterAll()
        guard wallpaperModel.hotKeysEnabled else {
            wallpaperModel.hotKeyRegistrationFailures = []
            return
        }
        var failures: Set<HotKeyAction> = []
        for action in HotKeyAction.allCases {
            guard let combo = wallpaperModel.hotKeyCombo(for: action) else {
                continue
            }
            let succeeded = center.register(id: action.hotKeyID, combo: combo) { [weak self] in
                self?.performHotKeyAction(action)
            }
            if !succeeded {
                failures.insert(action)
            }
        }
        wallpaperModel.hotKeyRegistrationFailures = failures
    }

    private func performHotKeyAction(_ action: HotKeyAction) {
        switch action {
        case .nextWallpaper:
            wallpaperModel.playNextVideo()
        case .previousWallpaper:
            wallpaperModel.playPreviousVideo()
        case .toggleAudio:
            toggleAudioEnabled()
        case .toggleDesktopIcons:
            wallpaperModel.setDesktopIconsVisible(!wallpaperModel.desktopIconsVisible)
        }
    }
}

extension HotKeyAction {
    /// Carbon 登録に使う安定した数値ID(allCases の並び順)。
    var hotKeyID: UInt32 {
        switch self {
        case .nextWallpaper: return 1
        case .previousWallpaper: return 2
        case .toggleAudio: return 3
        case .toggleDesktopIcons: return 4
        }
    }
}

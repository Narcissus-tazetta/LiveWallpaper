import AppKit
import ServiceManagement
import SwiftUI

extension AppDelegate {
    func setupSettingsWindow() {
        let root = SettingsRootView(model: wallpaperModel).environment(
            \.locale,
            wallpaperModel.appLocale
        )
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = localized("Live Wallpaper 設定")
        window.styleMask.insert(.resizable)
        window.minSize = NSSize(width: 880, height: 460)
        window.center()
        window.setContentSize(NSSize(width: 880, height: 460))
        window.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                self.wallpaperModel.scheduleActiveSpaceWindowRefresh()
            }
        }
        settingsWindowController = NSWindowController(window: window)
        settingsKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let characters = event.charactersIgnoringModifiers?.lowercased() else {
                return event
            }
            if event.modifierFlags.contains(.command) {
                if characters == "w" {
                    if let win = self?.settingsWindowController?.window, win.isKeyWindow {
                        win.close()
                        return nil
                    }
                }
                if characters == "q" {
                    if let win = self?.settingsWindowController?.window, win.isKeyWindow {
                        return nil
                    } else {
                        NSApp.terminate(nil)
                        return nil
                    }
                }
            }
            return event
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(showOpenPanel), name: .chooseVideo, object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCreatePlaylistAndChooseVideo),
            name: .createPlaylistAndChooseVideo,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleLaunchToggle(_:)), name: .toggleLaunchAtLogin,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleOpenCache), name: .openCacheFolder, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleClearCache), name: .clearCache, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAutoUpdateToggle(_:)), name: .toggleAutoUpdate,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(checkForUpdates), name: .checkUpdatesNow, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPlaybackState), name: .refreshPlayback, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(openReleasePage), name: .openReleasePage, object: nil
        )
        wallpaperModel.$appLanguage
            .receive(on: DispatchQueue.main)
            .sink { [weak hosting, weak self] _ in
                guard let hosting else { return }
                guard let self else { return }
                hosting.rootView = SettingsRootView(model: wallpaperModel)
                    .environment(\.locale, wallpaperModel.appLocale)
            }
            .store(in: &cancellables)
    }

    @objc func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        }

        guard panel.runModal() == .OK else {
            return
        }
        let urls = panel.urls
        guard !urls.isEmpty else {
            return
        }
        Task {
            for url in urls {
                await wallpaperModel.setVideo(path: url.path)
            }
        }
    }

    @objc func handleCreatePlaylistAndChooseVideo() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        }

        if panel.runModal() == .OK, let url: URL = panel.url {
            Task {
                _ = await wallpaperModel.createPlaylistAndSetVideo(path: url.path)
            }
        }
    }

    @objc func handleLaunchToggle(_ note: Notification) {
        if let enabled: Bool = note.object as? Bool {
            setLaunchAtLogin(enabled)
        }
    }

    func syncLaunchAtLoginState() {
        let enabled = currentLaunchAtLoginEnabled()
        launchAtLoginEnabled = enabled
        wallpaperModel.launchAtLoginEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "launchAtLogin")
    }

    @objc func handleAutoUpdateToggle(_ note: Notification) {
        if let enabled: Bool = note.object as? Bool {
            setAutoUpdateEnabled(enabled)
        }
    }

    @objc func handleOpenCache() {
        wallpaperModel.openCacheFolder()
    }

    @objc func handleClearCache() {
        if wallpaperModel.clearCache() {
            return
        }
        let alert = NSAlert()
        alert.messageText = localized("キャッシュの削除に失敗しました")
        alert.informativeText = localized("保存先フォルダへのアクセスに失敗した可能性があります。")
        alert.alertStyle = .warning
        alert.runModal()
    }

    func currentLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? false
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
                syncLaunchAtLoginState()
            } catch {
                let alert = NSAlert()
                alert.messageText = localized("ログイン時起動の設定に失敗しました")
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
                syncLaunchAtLoginState()
            }
        } else {
            let alert = NSAlert()
            alert.messageText = localized("このmacOSではログイン時起動設定に対応していません")
            alert.alertStyle = .informational
            alert.runModal()
            syncLaunchAtLoginState()
        }
    }

    func setAutoUpdateEnabled(_ enabled: Bool) {
        autoUpdateEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "autoUpdateEnabled")
        #if canImport(Sparkle)
            if let updater = updaterController?.updater {
                let shouldEnable = enabled && currentUpdateEnvironmentIssues().isEmpty
                updater.automaticallyChecksForUpdates = shouldEnable
                updater.automaticallyDownloadsUpdates = shouldEnable
            }
        #endif
    }
}

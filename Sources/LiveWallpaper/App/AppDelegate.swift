import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

#if canImport(Sparkle)
    import Sparkle
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindowController: NSWindowController?
    private let wallpaperModel = WallpaperModel()
    private var launchAtLoginEnabled: Bool = false
    private var autoUpdateEnabled: Bool = true
    #if canImport(Sparkle)
        private var updaterController: SPUStandardUpdaterController?
        private var sparkleStarted = false
        private var manualUpdateCheckPending = false
    #endif

    private enum UpdateEnvironmentIssue {
        case translocated
        case outsideApplications
        case notWritable
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
        launchAtLoginEnabled = currentLaunchAtLoginEnabled()
        autoUpdateEnabled =
            UserDefaults.standard.object(forKey: "autoUpdateEnabled") as? Bool ?? true
        NSApp.applicationIconImage = appIconImage()
        LocalizationManager.swizzle()
        LocalizationManager.setLanguage(wallpaperModel.effectiveAppLanguageCode)
        NSLog("[AppDelegate] Bundle.main.resourceURL=\(String(describing: Bundle.main.resourceURL))")
        setupStatusBar()
        setupSettingsWindow()
        verifyUpdatePrerequisites()
        setupSparkleUpdater()
    }

    private func bundleURL() -> URL {
        Bundle.main.bundleURL.resolvingSymlinksInPath()
    }

    private func applicationsDirectoryURL() -> URL? {
        FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first?
            .resolvingSymlinksInPath()
    }

    private func isRunningFromAppTranslocation(bundlePath: String) -> Bool {
        bundlePath.contains("/AppTranslocation/")
    }

    private func isInstalledInApplications(bundleURL: URL) -> Bool {
        guard let applicationsURL = applicationsDirectoryURL() else {
            return false
        }
        let appPath = bundleURL.path
        let applicationsPath = applicationsURL.path
        return appPath == applicationsPath || appPath.hasPrefix(applicationsPath + "/")
    }

    private func canWriteBundleLocation(bundleURL: URL) -> Bool {
        let bundlePath = bundleURL.path
        let parentPath = bundleURL.deletingLastPathComponent().path
        return FileManager.default.isWritableFile(atPath: bundlePath)
            || FileManager.default.isWritableFile(atPath: parentPath)
    }

    private func currentUpdateEnvironmentIssues() -> [UpdateEnvironmentIssue] {
        let bundle = bundleURL()
        let path = bundle.path
        var issues: [UpdateEnvironmentIssue] = []

        if isRunningFromAppTranslocation(bundlePath: path) {
            issues.append(.translocated)
        }
        if !isInstalledInApplications(bundleURL: bundle) {
            issues.append(.outsideApplications)
        }
        if !canWriteBundleLocation(bundleURL: bundle) {
            issues.append(.notWritable)
        }
        return issues
    }

    private func updateEnvironmentIssueDescription(_ issue: UpdateEnvironmentIssue) -> String {
        switch issue {
        case .translocated:
            return localized("一時実行領域（AppTranslocation）から起動されています。")
        case .outsideApplications:
            return localized("アプリが /Applications 配下にありません。")
        case .notWritable:
            return localized("現在の配置先に書き込みできません。")
        }
    }

    private func showUpdateEnvironmentAlert(issues: [UpdateEnvironmentIssue], title: String) {
        guard !issues.isEmpty else {
            return
        }
        let bulletText = issues
            .map { "・\(updateEnvironmentIssueDescription($0))" }
            .joined(separator: "\n")

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText =
            localized("アップデートの前提条件を満たしていません。")
            + "\n\n"
            + bulletText
            + "\n\n"
            + localized("LiveWallpaper.app を /Applications に移動して再起動してから、もう一度お試しください。")
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func ensureUpdateEnvironmentOrNotify(title: String) -> Bool {
        let issues = currentUpdateEnvironmentIssues()
        if issues.isEmpty {
            return true
        }
        showUpdateEnvironmentAlert(issues: issues, title: title)
        return false
    }

    private func verifyUpdatePrerequisites() {
        let bundlePath: String = bundleURL().path
        NSLog("[Sparkle] Bundle path: \(bundlePath)")
        let issues = currentUpdateEnvironmentIssues()
        if !issues.isEmpty {
            for issue in issues {
                NSLog("[Sparkle] Update prerequisite issue: \(updateEnvironmentIssueDescription(issue))")
            }
            DispatchQueue.main.async {
                self.showUpdateEnvironmentAlert(
                    issues: issues,
                    title: self.localized("アップデートを有効化するにはアプリをApplicationsに移動してください")
                )
            }
        }
    }

    private func setupSparkleUpdater() {
        #if canImport(Sparkle)
            guard let publicEDKey = Self.sparklePublicEDKeyValue(), !publicEDKey.isEmpty else {
                NSLog("[Sparkle] publicEDKey is empty")
                return
            }
            guard let feedURL = Self.sparkleFeedURLValue(), !feedURL.isEmpty else {
                NSLog("[Sparkle] feedURL is empty")
                return
            }
            NSLog("[Sparkle] feedURL=\(feedURL)")

            let updaterController = SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: self,
                userDriverDelegate: nil
            )
            self.updaterController = updaterController

            let updater = updaterController.updater
            let canUseAutomaticUpdates = autoUpdateEnabled
                && currentUpdateEnvironmentIssues().isEmpty
            updater.automaticallyChecksForUpdates = canUseAutomaticUpdates
            updater.automaticallyDownloadsUpdates = canUseAutomaticUpdates

            do {
                try updater.start()
                sparkleStarted = true
                NSLog("[Sparkle] updater.start() succeeded")
                if canUseAutomaticUpdates {
                    updater.checkForUpdatesInBackground()
                    NSLog("[Sparkle] checkForUpdatesInBackground() requested")
                } else {
                    NSLog("[Sparkle] automatic updates are disabled due to update prerequisites")
                }
            } catch {
                Self.reportSparkleError(error)
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = self.localized("アップデータ初期化に失敗しました")
                    alert.informativeText = message
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        #endif
    }

    private nonisolated static func reportSparkleError(_ error: Error) {
        NSLog("[Sparkle] \(error.localizedDescription)")
    }

    private nonisolated static func sparkleFeedURLValue() -> String? {
        if let value: String = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
           !value.isEmpty
        {
            return value
        }
        return AppConfig.sparkleAppcastURL
    }

    private nonisolated static func sparklePublicEDKeyValue() -> String? {
        if let value: String = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
           !value.isEmpty
        {
            return value
        }
        if !AppConfig.sparklePublicEDKey.isEmpty {
            return AppConfig.sparklePublicEDKey
        }
        return nil
    }

    private var cancellables = Set<AnyCancellable>()
    private enum MenuTag {
        static let openWallpaper = 1000
        static let openWallpaperFit = 1001
        static let openSettings = 1002
        static let audioToggle = 1003
        static let playlistToggle = 1004
        static let shuffleToggle = 1005
        static let previousVideo = 1006
        static let nextVideo = 1007
        static let exportPackage = 1008
        static let importPackage = 1009
        static let refreshPlayback = 1010
        static let updateMenu = 1011
        static let quitApp = 1012
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureStatusIcon()

        let menu = NSMenu()
        menu.showsStateColumn = false
        let openWallpaperItem = NSMenuItem(
            title: localized("壁紙を開く"),
            action: #selector(openWallpaperTab),
            keyEquivalent: ""
        )
        openWallpaperItem.image = wallpaperMenuIcon()
        openWallpaperItem.tag = MenuTag.openWallpaper
        menu.addItem(openWallpaperItem)
        let openWallpaperFitItem = NSMenuItem(
            title: localized("壁紙設定を開く"),
            action: #selector(openWallpaperFitTab),
            keyEquivalent: ""
        )
        openWallpaperFitItem.image = wallpaperFitMenuIcon()
        openWallpaperFitItem.tag = MenuTag.openWallpaperFit
        menu.addItem(openWallpaperFitItem)
        let openSettingsItem = NSMenuItem(
            title: localized("設定を開く"),
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        openSettingsItem.tag = MenuTag.openSettings
        menu.addItem(openSettingsItem)

        let toggleItem = NSMenuItem(
            title: audioMenuTitle(wallpaperModel.audioEnabled),
            action: #selector(toggleAudioEnabled),
            keyEquivalent: ""
        )
        toggleItem.image = audioMenuIcon(wallpaperModel.audioEnabled)
        toggleItem.tag = MenuTag.audioToggle
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        let playlistItem = NSMenuItem(
            title: playlistMenuTitle(wallpaperModel.playlistPlaybackEnabled),
            action: #selector(togglePlaylistPlayback),
            keyEquivalent: ""
        )
        playlistItem.image = playlistMenuIcon()
        playlistItem.tag = MenuTag.playlistToggle
        menu.addItem(playlistItem)

        let shuffleItem = NSMenuItem(
            title: shuffleMenuTitle(wallpaperModel.shufflePlaybackEnabled),
            action: #selector(toggleShufflePlayback),
            keyEquivalent: ""
        )
        shuffleItem.image = shuffleMenuIcon()
        shuffleItem.tag = MenuTag.shuffleToggle
        menu.addItem(shuffleItem)

        let previousItem = NSMenuItem(
            title: localized("前の動画"),
            action: #selector(playPreviousVideo),
            keyEquivalent: "["
        )
        previousItem.image = previousVideoMenuIcon()
        previousItem.tag = MenuTag.previousVideo
        menu.addItem(previousItem)

        let nextItem = NSMenuItem(
            title: localized("次の動画"),
            action: #selector(playNextVideo),
            keyEquivalent: "]"
        )
        nextItem.image = nextVideoMenuIcon()
        nextItem.tag = MenuTag.nextVideo
        menu.addItem(nextItem)

        let refreshItem = NSMenuItem(
            title: localized("再生をリフレッシュ"),
            action: #selector(refreshPlaybackState),
            keyEquivalent: "r"
        )
        refreshItem.image = refreshMenuIcon()
        refreshItem.tag = MenuTag.refreshPlayback
        menu.addItem(refreshItem)

        let exportItem = NSMenuItem(
            title: localized("壁紙を共有"),
            action: #selector(exportPackage),
            keyEquivalent: "e"
        )
        exportItem.image = NSImage(
            systemSymbolName: "square.and.arrow.up",
            accessibilityDescription: "Share"
        )
        exportItem.tag = MenuTag.exportPackage
        menu.addItem(exportItem)

        let importItem = NSMenuItem(
            title: localized("壁紙を読み込む"),
            action: #selector(importPackage),
            keyEquivalent: "i"
        )
        importItem.image = NSImage(
            systemSymbolName: "square.and.arrow.down",
            accessibilityDescription: "Import"
        )
        importItem.tag = MenuTag.importPackage
        menu.addItem(importItem)

        wallpaperModel.$audioEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let item = self?.statusItem?.menu?.item(withTag: MenuTag.audioToggle)
                else { return }
                item.title = self?.audioMenuTitle(enabled) ?? ""
                item.image = self?.audioMenuIcon(enabled)
            }
            .store(in: &cancellables)

        wallpaperModel.$playlistPlaybackEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else {
                    return
                }
                if let item = statusItem?.menu?.item(withTag: MenuTag.playlistToggle) {
                    item.title = playlistMenuTitle(enabled)
                    item.image = playlistMenuIcon()
                }
                refreshPlaylistMenuState()
            }
            .store(in: &cancellables)

        wallpaperModel.$shufflePlaybackEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else {
                    return
                }
                if let item = statusItem?.menu?.item(withTag: MenuTag.shuffleToggle) {
                    item.title = shuffleMenuTitle(enabled)
                    item.image = shuffleMenuIcon()
                }
            }
            .store(in: &cancellables)

        wallpaperModel.$registeredVideoPaths
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshPlaylistMenuState()
            }
            .store(in: &cancellables)

        wallpaperModel.$appLanguage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshLocalizedInterface()
            }
            .store(in: &cancellables)

        #if canImport(Sparkle)
            let updateItem = NSMenuItem(
                title: localized("アップデートを確認"),
                action: #selector(checkForUpdates),
                keyEquivalent: "u"
            )
            updateItem.image = updateMenuIcon()
            updateItem.tag = MenuTag.updateMenu
            menu.addItem(updateItem)
        #endif

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: localized("終了"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.tag = MenuTag.quitApp
        menu.addItem(quitItem)

        statusItem?.menu = menu
        refreshPlaylistMenuState()
        refreshLocalizedInterface()
    }

    private func configureStatusIcon() {
        guard let button = statusItem?.button else {
            return
        }

        if let image = selectWindowStatusIcon() {
            button.image = image
            button.image?.size = NSSize(width: 18, height: 18)
            button.image?.isTemplate = true
            button.title = ""
            return
        }

        if let fallback = NSImage(
            systemSymbolName: "macwindow.on.rectangle",
            accessibilityDescription: "Live Wallpaper"
        ) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            button.image = fallback.withSymbolConfiguration(config)
            button.image?.isTemplate = true
            button.title = ""
        } else {
            button.title = "LW"
        }
    }

    private func selectWindowStatusIcon() -> NSImage? {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else {
            return nil
        }

        context.setStrokeColor(NSColor.labelColor.cgColor)
        context.setLineWidth(1.6)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let backRect = CGRect(x: 3.1, y: 4.2, width: 9.4, height: 8.0)
        let frontRect = CGRect(x: 5.5, y: 6.4, width: 9.4, height: 8.0)
        context.stroke(backRect.insetBy(dx: 0.35, dy: 0.35))
        context.stroke(frontRect.insetBy(dx: 0.35, dy: 0.35))

        image.isTemplate = true
        return image
    }

    private func appIconImage() -> NSImage? {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            return NSImage(contentsOf: iconURL)
        }
        return nil
    }

    private var settingsKeyMonitor: Any?

    private func setupSettingsWindow() {
        let root = SettingsRootView(model: wallpaperModel).environment(\.locale, wallpaperModel.appLocale)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = localized("Live Wallpaper 設定")
        window.center()
        window.setContentSize(NSSize(width: 760, height: 460))
        window.isReleasedWhenClosed = false
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
                hosting.rootView = SettingsRootView(model: self.wallpaperModel)
                    .environment(\.locale, self.wallpaperModel.appLocale)
            }
            .store(in: &cancellables)
    }

    @objc private func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        }

        if panel.runModal() == .OK, let url: URL = panel.url {
            Task {
                await wallpaperModel.setVideo(path: url.path)
            }
        }
    }

    @objc private func handleCreatePlaylistAndChooseVideo() {
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

    @objc private func handleLaunchToggle(_ note: Notification) {
        if let enabled: Bool = note.object as? Bool {
            setLaunchAtLogin(enabled)
        }
    }

    @objc private func handleAutoUpdateToggle(_ note: Notification) {
        if let enabled: Bool = note.object as? Bool {
            setAutoUpdateEnabled(enabled)
        }
    }

    @objc private func handleOpenCache() {
        wallpaperModel.openCacheFolder()
    }

    @objc private func handleClearCache() {
        _ = wallpaperModel.clearCache()
    }

    private func setAudioEnabled(_ enabled: Bool) {
        wallpaperModel.setAudioEnabled(enabled)
        if let toggleItem = statusItem?.menu?.item(withTag: MenuTag.audioToggle) {
            toggleItem.title = audioMenuTitle(enabled)
            toggleItem.image = audioMenuIcon(enabled)
        }
    }

    private func refreshPlaylistMenuState() {
        let hasMultipleVideos = wallpaperModel.registeredVideoPaths.count > 1
        let playlistEnabled = wallpaperModel.playlistPlaybackEnabled

        if let shuffleItem = statusItem?.menu?.item(withTag: MenuTag.shuffleToggle) {
            shuffleItem.isEnabled = playlistEnabled && hasMultipleVideos
        }
        if let previousItem = statusItem?.menu?.item(withTag: MenuTag.previousVideo) {
            previousItem.isEnabled = hasMultipleVideos
        }
        if let nextItem = statusItem?.menu?.item(withTag: MenuTag.nextVideo) {
            nextItem.isEnabled = hasMultipleVideos
        }
    }

    private func currentLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? false
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
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
                launchAtLoginEnabled = currentLaunchAtLoginEnabled()
                UserDefaults.standard.set(launchAtLoginEnabled, forKey: "launchAtLogin")
            } catch {
                let alert = NSAlert()
                alert.messageText = localized("ログイン時起動の設定に失敗しました")
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
                launchAtLoginEnabled = currentLaunchAtLoginEnabled()
            }
        } else {
            let alert = NSAlert()
            alert.messageText = localized("このmacOSではログイン時起動設定に対応していません")
            alert.alertStyle = .informational
            alert.runModal()
            launchAtLoginEnabled = false
        }
    }

    private func setAutoUpdateEnabled(_ enabled: Bool) {
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

    @objc private func openReleasePage() {
        guard let url = URL(string: "https://github.com/Narcissus-tazetta/LiveWallpaper/releases") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func localized(_ key: String) -> String {
        wallpaperModel.localizedString(key)
    }

    private func refreshLocalizedInterface() {
        guard let menu = statusItem?.menu else {
            return
        }

        if let item = menu.item(withTag: MenuTag.openWallpaper) {
            item.title = localized("壁紙を開く")
        }
        if let item = menu.item(withTag: MenuTag.openWallpaperFit) {
            item.title = localized("壁紙設定を開く")
        }
        if let item = menu.item(withTag: MenuTag.openSettings) {
            item.title = localized("設定を開く")
        }
        if let item = menu.item(withTag: MenuTag.audioToggle) {
            item.title = audioMenuTitle(wallpaperModel.audioEnabled)
        }
        if let item = menu.item(withTag: MenuTag.playlistToggle) {
            item.title = playlistMenuTitle(wallpaperModel.playlistPlaybackEnabled)
        }
        if let item = menu.item(withTag: MenuTag.shuffleToggle) {
            item.title = shuffleMenuTitle(wallpaperModel.shufflePlaybackEnabled)
        }
        if let item = menu.item(withTag: MenuTag.previousVideo) {
            item.title = localized("前の動画")
        }
        if let item = menu.item(withTag: MenuTag.nextVideo) {
            item.title = localized("次の動画")
        }
        if let item = menu.item(withTag: MenuTag.exportPackage) {
            item.title = localized("壁紙を共有")
        }
        if let item = menu.item(withTag: MenuTag.importPackage) {
            item.title = localized("壁紙を読み込む")
        }
        if let item = menu.item(withTag: MenuTag.updateMenu) {
            item.title = localized("アップデートを確認")
        }
        if let item = menu.item(withTag: MenuTag.refreshPlayback) {
            item.title = localized("再生をリフレッシュ")
        }
        if let item = menu.item(withTag: MenuTag.quitApp) {
            item.title = localized("終了")
        }

        settingsWindowController?.window?.title = localized("Live Wallpaper 設定")
    }

    private func audioMenuTitle(_ enabled: Bool) -> String {
        localized("音声を再生") + ": " + (enabled ? localized("ON") : localized("OFF"))
    }

    private func playlistMenuTitle(_ enabled: Bool) -> String {
        localized("プレイリスト連続再生") + ": " + (enabled ? localized("ON") : localized("OFF"))
    }

    private func shuffleMenuTitle(_ enabled: Bool) -> String {
        localized("シャッフル") + ": " + (enabled ? localized("ON") : localized("OFF"))
    }

    private func audioMenuIcon(_ enabled: Bool) -> NSImage? {
        let symbolName: String = enabled ? "speaker.wave.2" : "speaker.slash"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "音声")
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = image?.withSymbolConfiguration(config)
        configured?.isTemplate = true
        return configured
    }

    private func updateMenuIcon() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: localized("アップデート")
        )
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = image?.withSymbolConfiguration(config)
        configured?.isTemplate = true
        return configured
    }

    private func wallpaperMenuIcon() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "photo.on.rectangle",
            accessibilityDescription: localized("壁紙")
        )
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = image?.withSymbolConfiguration(config)
        configured?.isTemplate = true
        return configured
    }

    private func playlistMenuIcon() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "rectangle.stack",
            accessibilityDescription: localized("プレイリスト")
        )
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = image?.withSymbolConfiguration(config)
        configured?.isTemplate = true
        return configured
    }

    private func shuffleMenuIcon() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "shuffle",
            accessibilityDescription: localized("シャッフル")
        )
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = image?.withSymbolConfiguration(config)
        configured?.isTemplate = true
        return configured
    }

    private func previousVideoMenuIcon() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "backward.fill",
            accessibilityDescription: localized("前の動画")
        )
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = image?.withSymbolConfiguration(config)
        configured?.isTemplate = true
        return configured
    }

    private func nextVideoMenuIcon() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "forward.fill",
            accessibilityDescription: localized("次の動画")
        )
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = image?.withSymbolConfiguration(config)
        configured?.isTemplate = true
        return configured
    }

    private func wallpaperFitMenuIcon() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "viewfinder",
            accessibilityDescription: localized("壁紙設定")
        )
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = image?.withSymbolConfiguration(config)
        configured?.isTemplate = true
        return configured
    }

    private func refreshMenuIcon() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: localized("再生をリフレッシュ")
        )
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = image?.withSymbolConfiguration(config)
        configured?.isTemplate = true
        return configured
    }

    @objc private func openSettings() {
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .openSettingsTab, object: nil)
    }

    @objc private func openWallpaperTab() {
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .openWallpaperTab, object: nil)
    }

    @objc private func openWallpaperFitTab() {
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .openWallpaperFitTab, object: nil)
    }

    @objc private func toggleAudioEnabled() {
        setAudioEnabled(!wallpaperModel.audioEnabled)
    }

    @objc private func togglePlaylistPlayback() {
        wallpaperModel.setPlaylistPlaybackEnabled(!wallpaperModel.playlistPlaybackEnabled)
    }

    @objc private func toggleShufflePlayback() {
        wallpaperModel.setShufflePlaybackEnabled(!wallpaperModel.shufflePlaybackEnabled)
    }

    @objc private func playPreviousVideo() {
        wallpaperModel.playPreviousVideo()
    }

    @objc private func playNextVideo() {
        wallpaperModel.playNextVideo()
    }

    @objc private func refreshPlaybackState() {
        wallpaperModel.refreshPlaybackState()
    }

    @objc private func exportPackage() {
        openWallpaperTab()
        NotificationCenter.default.post(name: .openWallpaperShareSheet, object: nil)
    }

    @objc private func importPackage() {
        let panel = NSOpenPanel()
        panel.title = localized("壁紙を読み込む")
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [UTType(filenameExtension: "lwpkg") ?? .data]
        } else {
            panel.allowedFileTypes = ["lwpkg"]
        }
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.urls.first else { return }

        let importer = PackageImporter()

        func showImportSucceededAlert() {
            let alert = NSAlert()
            alert.messageText = localized("インポート完了")
            alert.informativeText = localized("パッケージが正常にインポートされました。")
            alert.alertStyle = .informational
            alert.runModal()
        }

        func showImportFailedAlert(_ message: String) {
            let alert = NSAlert()
            alert.messageText = localized("インポートに失敗")
            alert.informativeText = message
            alert.alertStyle = .critical
            alert.runModal()
        }

        func importWithResolution(_ resolution: PackageImporter.DuplicateResolution) {
            Task {
                do {
                    try await importer.importPackage(
                        from: url,
                        into: wallpaperModel,
                        duplicateResolution: resolution
                    )
                    showImportSucceededAlert()
                } catch let PackageImporter.ImportError.duplicateVideo(name) {
                    let duplicateAlert = NSAlert()
                    duplicateAlert.messageText = localized("重複するビデオが見つかりました")
                    duplicateAlert.informativeText = "\(name) " + localized("は既に存在します。置き換えますか？")
                    duplicateAlert.alertStyle = .warning
                    duplicateAlert.addButton(withTitle: localized("中止"))
                    duplicateAlert.addButton(withTitle: localized("置き換える"))

                    if duplicateAlert.runModal() == .alertSecondButtonReturn {
                        importWithResolution(.replace)
                    }
                } catch {
                    showImportFailedAlert(error.localizedDescription)
                }
            }
        }

        importWithResolution(.abort)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func checkForUpdates() {
        #if canImport(Sparkle)
            guard ensureUpdateEnvironmentOrNotify(
                title: localized("アップデートを確認する前に移動が必要です")
            ) else {
                manualUpdateCheckPending = false
                return
            }

            settingsWindowController?.showWindow(nil)
            settingsWindowController?.window?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            NSLog("[Sparkle] manual checkForUpdates() requested")
            manualUpdateCheckPending = true
            guard let updater = updaterController?.updater else {
                NSLog("[Sparkle] updaterController is nil")
                manualUpdateCheckPending = false
                return
            }

            if !sparkleStarted {
                do {
                    try updater.start()
                    sparkleStarted = true
                    NSLog("[Sparkle] updater.start() succeeded from manual check")
                } catch {
                    Self.reportSparkleError(error)
                    manualUpdateCheckPending = false
                    let alert = NSAlert()
                    alert.messageText = localized("アップデータ初期化に失敗しました")
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                    return
                }
            }

            updaterController?.checkForUpdates(nil)
        #endif
    }

    deinit {
        if let monitor: Any = settingsKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

#if canImport(Sparkle)
    extension AppDelegate: SPUUpdaterDelegate {
        nonisolated func feedURLString(for _: SPUUpdater) -> String? {
            Self.sparkleFeedURLValue()
        }

        nonisolated func publicEDKey(for _: SPUUpdater) -> String? {
            Self.sparklePublicEDKeyValue()
        }

        nonisolated func updater(_: SPUUpdater, didAbortWithError error: Error) {
            Task { @MainActor in
                self.manualUpdateCheckPending = false
            }
            Self.reportSparkleError(error)
        }

        nonisolated func updaterDidNotFindUpdate(_: SPUUpdater) {
            Task { @MainActor in
                if self.manualUpdateCheckPending {
                    self.manualUpdateCheckPending = false
                }
            }
        }
    }
#endif

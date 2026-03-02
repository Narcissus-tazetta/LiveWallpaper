import AVFoundation
import AppKit
import Combine
import ServiceManagement
import SwiftUI

#if canImport(Sparkle)
    import Sparkle
#endif

enum AppConfig {
    static let defaultVersion = "0.0.3"
    static let sparkleAppcastURL =
        "https://raw.githubusercontent.com/Narcissus-tazetta/LiveWallpaper/main/docs/appcast.xml"
    static let sparklePublicEDKey = "uoATy8ItPd3DQDHahg8JEWgXUNS4//A29+JLUy2zxhY="
}

enum DisplayMode: String {
    case mainOnly
    case allScreens
}

enum VideoFitMode: String {
    case fill
    case fit
}

final class PlayerView: NSView {
    override func makeBackingLayer() -> CALayer {
        AVPlayerLayer()
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

@MainActor
final class WallpaperModel: ObservableObject {
    private var windows: [NSWindow] = []
    private var playerViews: [PlayerView] = []
    private let queuePlayer = AVQueuePlayer()
    private var playerLooper: AVPlayerLooper?
    private var screenChangeObserver: NSObjectProtocol?

    @Published private(set) var clickThrough = true
    @Published private(set) var displayMode: DisplayMode = .mainOnly
    @Published private(set) var fitMode: VideoFitMode = .fill
    @Published private(set) var lightweightMode = false

    @Published private(set) var currentVideoPath: String?

    init() {
        configurePlayer()
        restoreState()
        rebuildWindows()
        if let savedPath = currentVideoPath {
            playVideo(url: URL(fileURLWithPath: savedPath))
        }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildWindows()
            }
        }
    }

    deinit {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func configurePlayer() {
        queuePlayer.isMuted = true
        queuePlayer.allowsExternalPlayback = false
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
        queuePlayer.actionAtItemEnd = .none
        applyLightweightSettings()
    }

    private func targetScreens() -> [NSScreen] {
        switch displayMode {
        case .allScreens:
            return NSScreen.screens
        case .mainOnly:
            if let main = NSScreen.main {
                return [main]
            }
            if let first = NSScreen.screens.first {
                return [first]
            }
            return []
        }
    }

    private func rebuildWindows() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        playerViews.removeAll()

        let screens = targetScreens()
        for screen in screens {
            let frame = screen.frame
            let window = NSWindow(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )

            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = clickThrough
            window.setFrame(frame, display: true)

            let playerView = PlayerView(frame: .zero)
            playerView.wantsLayer = true
            playerView.playerLayer.videoGravity =
                fitMode == .fit ? .resizeAspect : .resizeAspectFill
            playerView.playerLayer.player = queuePlayer
            window.contentView = playerView
            window.orderBack(nil)
            window.orderFront(nil)

            windows.append(window)
            playerViews.append(playerView)
        }
    }

    func setClickThrough(_ enabled: Bool) {
        guard clickThrough != enabled else {
            return
        }
        clickThrough = enabled
        for window in windows {
            window.ignoresMouseEvents = enabled
        }
        UserDefaults.standard.set(enabled, forKey: "clickThrough")
    }

    func setDisplayMode(_ mode: DisplayMode) {
        guard displayMode != mode else {
            return
        }
        displayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "displayMode")
        rebuildWindows()
    }

    func setFitMode(_ mode: VideoFitMode) {
        guard fitMode != mode else {
            return
        }
        fitMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "fitMode")
        let gravity: AVLayerVideoGravity = mode == .fit ? .resizeAspect : .resizeAspectFill
        for playerView in playerViews {
            playerView.playerLayer.videoGravity = gravity
        }
    }

    func setLightweightMode(_ enabled: Bool) {
        guard lightweightMode != enabled else {
            return
        }
        lightweightMode = enabled
        UserDefaults.standard.set(enabled, forKey: "lightweightMode")
        applyLightweightSettings()
        if let currentPath = currentVideoPath {
            playVideo(url: URL(fileURLWithPath: currentPath))
        }
    }

    func setVideo(path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        let sourceURL = URL(fileURLWithPath: trimmed)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return
        }

        guard let localURL = importVideoToAppSupport(from: sourceURL) else {
            return
        }

        guard currentVideoPath != localURL.path else {
            return
        }

        currentVideoPath = localURL.path
        UserDefaults.standard.set(localURL.path, forKey: "videoPath")

        playVideo(url: localURL)
    }

    func openCacheFolder() {
        guard let directory = cacheDirectoryURL() else {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch {
            return
        }
    }

    func clearCache() -> Bool {
        guard let directory = cacheDirectoryURL() else {
            return false
        }

        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            if let currentPath = currentVideoPath, currentPath.hasPrefix(directory.path) {
                queuePlayer.pause()
                queuePlayer.removeAllItems()
                playerLooper = nil
                currentVideoPath = nil
                UserDefaults.standard.removeObject(forKey: "videoPath")
            }
            return true
        } catch {
            return false
        }
    }

    private func applyLightweightSettings() {
        queuePlayer.automaticallyWaitsToMinimizeStalling = lightweightMode
    }

    private func playVideo(url: URL) {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = lightweightMode ? 0 : 1
        item.preferredPeakBitRate = lightweightMode ? 1_500_000 : 0
        queuePlayer.pause()
        queuePlayer.removeAllItems()
        playerLooper = nil
        playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        queuePlayer.play()
    }

    private func cacheDirectoryURL() -> URL? {
        guard
            let appSupportURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            return nil
        }

        return
            appSupportURL
            .appendingPathComponent("LiveWallpaper", isDirectory: true)
            .appendingPathComponent("Videos", isDirectory: true)
    }

    private func importVideoToAppSupport(from sourceURL: URL) -> URL? {
        let fileManager = FileManager.default
        guard let targetDirectory = cacheDirectoryURL() else {
            return nil
        }

        do {
            try fileManager.createDirectory(
                at: targetDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }

        let ext = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
        let targetURL = targetDirectory.appendingPathComponent("wallpaper.\(ext)")

        if sourceURL.path == targetURL.path {
            return targetURL
        }

        do {
            if fileManager.fileExists(atPath: targetURL.path) {
                try fileManager.removeItem(at: targetURL)
            }
            try fileManager.copyItem(at: sourceURL, to: targetURL)
            return targetURL
        } catch {
            return nil
        }
    }

    private func restoreState() {
        clickThrough = UserDefaults.standard.object(forKey: "clickThrough") as? Bool ?? true
        if let modeValue = UserDefaults.standard.string(forKey: "displayMode"),
            let restoredMode = DisplayMode(rawValue: modeValue)
        {
            displayMode = restoredMode
        }
        if let fitValue = UserDefaults.standard.string(forKey: "fitMode"),
            let restoredFit = VideoFitMode(rawValue: fitValue)
        {
            fitMode = restoredFit
        }
        lightweightMode = UserDefaults.standard.object(forKey: "lightweightMode") as? Bool ?? false
        applyLightweightSettings()
        if let savedPath = UserDefaults.standard.string(forKey: "videoPath") {
            currentVideoPath = savedPath
        }
    }

    func currentAppVersion() -> String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String,
            !version.isEmpty
        {
            return version
        }
        return AppConfig.defaultVersion
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var settingsWindowController: NSWindowController!
    private let wallpaperModel = WallpaperModel()
    private var launchAtLoginEnabled = false
    private var autoUpdateEnabled = true
    #if canImport(Sparkle)
        private var updaterController: SPUStandardUpdaterController?
        private var sparkleStarted = false
        private var manualUpdateCheckPending = false
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        launchAtLoginEnabled = currentLaunchAtLoginEnabled()
        autoUpdateEnabled =
            UserDefaults.standard.object(forKey: "autoUpdateEnabled") as? Bool ?? true
        NSApp.applicationIconImage = appIconImage()
        setupStatusBar()
        setupSettingsWindow()
        verifyUpdatePrerequisites()
        setupSparkleUpdater()
    }

    private func verifyUpdatePrerequisites() {
        let bundlePath = Bundle.main.bundlePath
        NSLog("[Sparkle] Bundle path: \(bundlePath)")
        if bundlePath.contains("/AppTranslocation/") {
            let alert = NSAlert()
            alert.messageText = "アップデートを有効化するにはアプリをApplicationsに移動してください"
            alert.informativeText = "現在は一時実行領域から起動しているため、自動アップデートが失敗する場合があります。"
            alert.alertStyle = .warning
            alert.runModal()
            NSLog("[Sparkle] AppTranslocation detected")
        }
        if !FileManager.default.isWritableFile(atPath: bundlePath) {
            NSLog("[Sparkle] App path is not writable: \(bundlePath)")
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
            updater.automaticallyChecksForUpdates = autoUpdateEnabled
            updater.automaticallyDownloadsUpdates = autoUpdateEnabled

            do {
                try updater.start()
                sparkleStarted = true
                NSLog("[Sparkle] updater.start() succeeded")
                updater.checkForUpdatesInBackground()
                NSLog("[Sparkle] checkForUpdatesInBackground() requested")
            } catch {
                Self.reportSparkleError(error)
                let alert = NSAlert()
                alert.messageText = "アップデータ初期化に失敗しました"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        #endif
    }

    nonisolated private static func reportSparkleError(_ error: Error) {
        NSLog("[Sparkle] \(error.localizedDescription)")
    }

    nonisolated private static func sparkleFeedURLValue() -> String? {
        if let value = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            !value.isEmpty
        {
            return value
        }
        return AppConfig.sparkleAppcastURL
    }

    nonisolated private static func sparklePublicEDKeyValue() -> String? {
        if let value = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
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

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureStatusIcon()

        let menu = NSMenu()
        menu.showsStateColumn = false
        menu.addItem(NSMenuItem(title: "設定を開く", action: #selector(openSettings), keyEquivalent: ""))

        let toggleItem = NSMenuItem(
            title: clickThroughMenuTitle(wallpaperModel.clickThrough),
            action: #selector(toggleClickThrough),
            keyEquivalent: ""
        )
        toggleItem.image = clickThroughMenuIcon(wallpaperModel.clickThrough)
        toggleItem.tag = 1001
        menu.addItem(toggleItem)

        wallpaperModel.$clickThrough
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let item = self?.statusItem.menu?.item(withTag: 1001) else { return }
                item.title = self?.clickThroughMenuTitle(enabled) ?? ""
                item.image = self?.clickThroughMenuIcon(enabled)
            }
            .store(in: &cancellables)

        #if canImport(Sparkle)
            let updateItem = NSMenuItem(
                title: "アップデートを確認",
                action: #selector(checkForUpdates),
                keyEquivalent: "u"
            )
            updateItem.image = updateMenuIcon()
            menu.addItem(updateItem)
        #endif

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func configureStatusIcon() {
        guard let button = statusItem.button else {
            return
        }

        if let customIcon = appIconImage() {
            button.image = customIcon
            button.image?.size = NSSize(width: 18, height: 18)
            button.image?.isTemplate = false
            button.title = ""
            return
        }

        if let image = NSImage(
            systemSymbolName: "square.3.layers.3d",
            accessibilityDescription: "Live Wallpaper"
        ) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            button.image = image.withSymbolConfiguration(config)
            button.image?.isTemplate = true
            button.title = ""
        } else {
            button.title = "LW"
        }
    }

    private func appIconImage() -> NSImage? {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            return NSImage(contentsOf: iconURL)
        }
        return nil
    }

    private func setupSettingsWindow() {
        let hosting = NSHostingController(rootView: SettingsView(model: wallpaperModel))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Live Wallpaper 設定"
        window.center()
        window.setContentSize(NSSize(width: 760, height: 460))
        window.isReleasedWhenClosed = false
        settingsWindowController = NSWindowController(window: window)

        NotificationCenter.default.addObserver(
            self, selector: #selector(showOpenPanel), name: .chooseVideo, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleLaunchToggle(_:)), name: .toggleLaunchAtLogin,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleOpenCache), name: .openCacheFolder, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleClearCache), name: .clearCache, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAutoUpdateToggle(_:)), name: .toggleAutoUpdate,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(checkForUpdates), name: .checkUpdatesNow, object: nil)
    }

    private func currentAppVersion() -> String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String,
            !version.isEmpty
        {
            return version
        }
        return AppConfig.defaultVersion
    }

    @objc private func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        }

        if panel.runModal() == .OK, let url = panel.url {
            wallpaperModel.setVideo(path: url.path)
        }
    }
    @objc private func handleLaunchToggle(_ note: Notification) {
        if let enabled = note.object as? Bool {
            setLaunchAtLogin(enabled)
        }
    }

    @objc private func handleAutoUpdateToggle(_ note: Notification) {
        if let enabled = note.object as? Bool {
            setAutoUpdateEnabled(enabled)
        }
    }

    @objc private func handleOpenCache() {
        wallpaperModel.openCacheFolder()
    }

    @objc private func handleClearCache() {
        _ = wallpaperModel.clearCache()
    }

    private func setClickThrough(_ enabled: Bool) {
        wallpaperModel.setClickThrough(enabled)
        if let toggleItem = statusItem.menu?.item(withTag: 1001) {
            toggleItem.title = clickThroughMenuTitle(enabled)
            toggleItem.image = clickThroughMenuIcon(enabled)
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
                alert.messageText = "ログイン時起動の設定に失敗しました"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
                launchAtLoginEnabled = currentLaunchAtLoginEnabled()
            }
        } else {
            let alert = NSAlert()
            alert.messageText = "このmacOSではログイン時起動設定に対応していません"
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
                updater.automaticallyChecksForUpdates = enabled
                updater.automaticallyDownloadsUpdates = enabled
            }
        #endif
    }

    private func clickThroughMenuTitle(_ enabled: Bool) -> String {
        "クリック貫通: " + (enabled ? "ON" : "OFF")
    }

    private func clickThroughMenuIcon(_ enabled: Bool) -> NSImage? {
        let symbolName = enabled ? "cursorarrow.click" : "cursorarrow"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "クリック貫通")
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = image?.withSymbolConfiguration(config)
        configured?.isTemplate = true
        return configured
    }

    private func updateMenuIcon() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: "アップデート"
        )
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = image?.withSymbolConfiguration(config)
        configured?.isTemplate = true
        return configured
    }

    @objc private func openSettings() {
        settingsWindowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleClickThrough() {
        setClickThrough(!wallpaperModel.clickThrough)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func checkForUpdates() {
        #if canImport(Sparkle)
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
                    alert.messageText = "アップデータ初期化に失敗しました"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                    return
                }
            }

            updaterController?.checkForUpdates(nil)
        #endif
    }
}

#if canImport(Sparkle)
    extension AppDelegate: SPUUpdaterDelegate {
        nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
            Self.sparkleFeedURLValue()
        }

        nonisolated func publicEDKey(for updater: SPUUpdater) -> String? {
            Self.sparklePublicEDKeyValue()
        }

        nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
            Task { @MainActor in
                self.manualUpdateCheckPending = false
            }
            Self.reportSparkleError(error)
        }

        nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
            Task { @MainActor in
                if self.manualUpdateCheckPending {
                    self.manualUpdateCheckPending = false
                    let alert = NSAlert()
                    alert.messageText = "最新の状態です！"
                    alert.informativeText = "現在利用できるアップデートはありません。"
                    alert.alertStyle = .informational
                    alert.runModal()
                }
            }
        }
    }
#endif

@main
struct LiveWallpaperApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

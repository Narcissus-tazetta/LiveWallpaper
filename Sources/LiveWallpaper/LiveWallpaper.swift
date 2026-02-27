import AVFoundation
import AppKit
import Sparkle

enum AppConfig {
    static let defaultVersion = "0.0.1"
    static let sparkleAppcastURL = "https://narcissus-tazetta.github.io/LiveWallpaper/appcast.xml"
    static let sparklePublicEDKey = ""
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
final class SettingsWindowController: NSWindowController {
    private let pathField = NSTextField(string: "")
    private let clickThroughCheckbox = NSButton(
        checkboxWithTitle: "クリック貫通を有効にする", target: nil, action: nil)
    private let versionLabel = NSTextField(labelWithString: "")

    var onChooseVideo: (() -> Void)?
    var onApplyPath: ((String) -> Void)?
    var onToggleClickThrough: ((Bool) -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        self.init(window: window)
        setupUI()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else {
            return
        }

        window?.title = "Live Wallpaper 設定"
        window?.center()
        window?.isReleasedWhenClosed = false

        let titleLabel = NSTextField(labelWithString: "動画ファイル")
        let chooseButton = NSButton(title: "参照", target: self, action: #selector(chooseVideo))
        let applyButton = NSButton(title: "適用", target: self, action: #selector(applyVideo))

        pathField.placeholderString = "/Users/.../wallpaper.mp4"

        clickThroughCheckbox.target = self
        clickThroughCheckbox.action = #selector(toggleClickThrough)

        versionLabel.textColor = .secondaryLabelColor
        versionLabel.font = NSFont.systemFont(ofSize: 11)
        versionLabel.alignment = .right

        [titleLabel, pathField, chooseButton, applyButton, clickThroughCheckbox, versionLabel]
            .forEach {
                $0.translatesAutoresizingMaskIntoConstraints = false
                contentView.addSubview($0)
            }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            pathField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            pathField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            pathField.trailingAnchor.constraint(equalTo: chooseButton.leadingAnchor, constant: -8),

            chooseButton.centerYAnchor.constraint(equalTo: pathField.centerYAnchor),
            chooseButton.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -20),
            chooseButton.widthAnchor.constraint(equalToConstant: 72),

            applyButton.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 12),
            applyButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            applyButton.widthAnchor.constraint(equalToConstant: 72),

            clickThroughCheckbox.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: 20),
            clickThroughCheckbox.topAnchor.constraint(
                equalTo: applyButton.bottomAnchor, constant: 14),

            versionLabel.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -12),
            versionLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    func update(path: String?, clickThrough: Bool) {
        pathField.stringValue = path ?? ""
        clickThroughCheckbox.state = clickThrough ? .on : .off
    }

    func updateVersion(_ version: String) {
        versionLabel.stringValue = "v\(version)"
    }

    @objc private func chooseVideo() {
        onChooseVideo?()
    }

    @objc private func applyVideo() {
        onApplyPath?(pathField.stringValue)
    }

    @objc private func toggleClickThrough() {
        onToggleClickThrough?(clickThroughCheckbox.state == .on)
    }
}

@MainActor
final class WallpaperController {
    private var window: NSWindow!
    private let queuePlayer = AVQueuePlayer()
    private var playerLooper: AVPlayerLooper?
    private let playerView = PlayerView(frame: .zero)

    private(set) var clickThrough = true {
        didSet {
            window.ignoresMouseEvents = clickThrough
        }
    }

    private(set) var currentVideoPath: String?

    init() {
        setupWindow()
        configurePlayer()
        restoreState()
    }

    private func configurePlayer() {
        queuePlayer.isMuted = true
        queuePlayer.allowsExternalPlayback = false
        queuePlayer.automaticallyWaitsToMinimizeStalling = false
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
        queuePlayer.actionAtItemEnd = .none
    }

    private func setupWindow() {
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        window = NSWindow(
            contentRect: screen,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.setFrame(screen, display: true)

        playerView.wantsLayer = true
        playerView.playerLayer.videoGravity = .resizeAspectFill
        playerView.playerLayer.player = queuePlayer
        window.contentView = playerView
        window.orderBack(nil)
        window.orderFront(nil)
    }

    func setClickThrough(_ enabled: Bool) {
        guard clickThrough != enabled else {
            return
        }
        clickThrough = enabled
        UserDefaults.standard.set(enabled, forKey: "clickThrough")
    }

    func setVideo(path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        guard currentVideoPath != trimmed else {
            return
        }

        let url = URL(fileURLWithPath: trimmed)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        currentVideoPath = trimmed
        UserDefaults.standard.set(trimmed, forKey: "videoPath")

        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 1
        queuePlayer.pause()
        queuePlayer.removeAllItems()
        playerLooper = nil
        playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        queuePlayer.play()
    }

    private func restoreState() {
        let restoredClickThrough =
            UserDefaults.standard.object(forKey: "clickThrough") as? Bool ?? true
        setClickThrough(restoredClickThrough)

        if let savedPath = UserDefaults.standard.string(forKey: "videoPath") {
            setVideo(path: savedPath)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {

    private var statusItem: NSStatusItem!
    private var settingsWindowController: SettingsWindowController!
    private let wallpaperController = WallpaperController()
    private var updaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = appIconImage()
        setupStatusBar()
        setupSettingsWindow()
        setupSparkleUpdater()
    }

    private func setupSparkleUpdater() {
        guard let publicEDKey = Self.sparklePublicEDKeyValue(), !publicEDKey.isEmpty else {
            return
        }
        guard let feedURL = Self.sparkleFeedURLValue(), !feedURL.isEmpty else {
            return
        }

        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.updaterController = updaterController

        let updater = updaterController.updater
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = true

        do {
            try updater.start()
            updater.checkForUpdatesInBackground()
        } catch {
            return
        }
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        Self.sparkleFeedURLValue()
    }

    nonisolated func publicEDKey(for updater: SPUUpdater) -> String? {
        Self.sparklePublicEDKeyValue()
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
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

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureStatusIcon()

        let menu = NSMenu()
        menu.showsStateColumn = false
        menu.addItem(NSMenuItem(title: "設定を開く", action: #selector(openSettings), keyEquivalent: ""))

        let toggleItem = NSMenuItem(
            title: clickThroughMenuTitle(wallpaperController.clickThrough),
            action: #selector(toggleClickThrough),
            keyEquivalent: ""
        )
        toggleItem.image = clickThroughMenuIcon(wallpaperController.clickThrough)
        toggleItem.tag = 1001
        menu.addItem(toggleItem)

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
        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns") {
            return NSImage(contentsOf: iconURL)
        }
        return nil
    }

    private func setupSettingsWindow() {
        settingsWindowController = SettingsWindowController()
        settingsWindowController.update(
            path: wallpaperController.currentVideoPath,
            clickThrough: wallpaperController.clickThrough)
        settingsWindowController.updateVersion(currentAppVersion())

        settingsWindowController.onChooseVideo = { [weak self] in
            self?.showOpenPanel()
        }

        settingsWindowController.onApplyPath = { [weak self] path in
            self?.wallpaperController.setVideo(path: path)
        }

        settingsWindowController.onToggleClickThrough = { [weak self] enabled in
            self?.setClickThrough(enabled)
        }
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

    private func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        }

        if panel.runModal() == .OK, let url = panel.url {
            wallpaperController.setVideo(path: url.path)
            settingsWindowController.update(
                path: wallpaperController.currentVideoPath,
                clickThrough: wallpaperController.clickThrough)
        }
    }

    private func setClickThrough(_ enabled: Bool) {
        wallpaperController.setClickThrough(enabled)
        settingsWindowController.update(
            path: wallpaperController.currentVideoPath,
            clickThrough: wallpaperController.clickThrough)
        if let toggleItem = statusItem.menu?.item(withTag: 1001) {
            toggleItem.title = clickThroughMenuTitle(enabled)
            toggleItem.image = clickThroughMenuIcon(enabled)
        }
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

    @objc private func openSettings() {
        settingsWindowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleClickThrough() {
        setClickThrough(!wallpaperController.clickThrough)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

@main
struct LiveWallpaperApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

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
    var statusItem: NSStatusItem?
    var settingsWindowController: NSWindowController?
    let wallpaperModel = WallpaperModel()
    var launchAtLoginEnabled: Bool = false
    var autoUpdateEnabled: Bool = true
    var cancellables = Set<AnyCancellable>()
    var settingsKeyMonitor: Any?
    var screenUnlockObserver: NSObjectProtocol?
    var appearanceObserver: NSKeyValueObservation?
    #if canImport(Sparkle)
        var updaterController: SPUStandardUpdaterController?
        var sparkleStarted = false
        var manualUpdateCheckPending = false
    #endif

    enum MenuTag {
        static let openWallpaper = 1000
        static let openWallpaperFit = 1001
        static let openSettings = 1002
        static let audioToggle = 1003
        static let playlistToggle = 1004
        static let pinCurrentVideoToggle = 1013
        static let shuffleToggle = 1005
        static let previousVideo = 1006
        static let nextVideo = 1007
        static let exportPackage = 1008
        static let importPackage = 1009
        static let refreshPlayback = 1010
        static let updateMenu = 1011
        static let quitApp = 1012
        static let assignToCurrentSpace = 1014
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
        syncLaunchAtLoginState()
        autoUpdateEnabled =
            UserDefaults.standard.object(forKey: "autoUpdateEnabled") as? Bool ?? true
        wallpaperModel.autoUpdateEnabled = autoUpdateEnabled
        NSApp.applicationIconImage = appIconImage()
        LocalizationManager.swizzle()
        LocalizationManager.setLanguage(wallpaperModel.effectiveAppLanguageCode)
        AppLog.appDelegate.debug(
            "Bundle.main.resourceURL=\(String(describing: Bundle.main.resourceURL), privacy: .public)"
        )
        setupStatusBar()
        setupSettingsWindow()
        setupScreenUnlockObserver()
        setupAppearanceObserver()
        verifyUpdatePrerequisites()
        setupSparkleUpdater()
    }

    func localized(_ key: String) -> String {
        wallpaperModel.localizedString(key)
    }

    func applicationWillTerminate(_: Notification) {
        wallpaperModel.restoreLockScreenSyncBeforeExit()
    }

    private func setupScreenUnlockObserver() {
        screenUnlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.wallpaperModel.handleScreenUnlockedForLockScreenSync()
                self?.wallpaperModel.evaluateSchedule(trigger: .unlock)
            }
        }
    }

    /// ダークモード切替検出。非公開の AppleInterfaceThemeChangedNotification ではなく、
    /// NSApp.effectiveAppearance への集中KVOという公式に推奨される方式を使う。
    private func setupAppearanceObserver() {
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.wallpaperModel.evaluateSchedule(trigger: .appearanceChanged)
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let observer = screenUnlockObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        appearanceObserver?.invalidate()
        if let monitor: Any = settingsKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

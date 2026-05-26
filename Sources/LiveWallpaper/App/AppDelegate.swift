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
        static let shuffleToggle = 1005
        static let previousVideo = 1006
        static let nextVideo = 1007
        static let exportPackage = 1008
        static let importPackage = 1009
        static let refreshPlayback = 1010
        static let updateMenu = 1011
        static let quitApp = 1012
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
        launchAtLoginEnabled = currentLaunchAtLoginEnabled()
        autoUpdateEnabled =
            UserDefaults.standard.object(forKey: "autoUpdateEnabled") as? Bool ?? true
        NSApp.applicationIconImage = appIconImage()
        LocalizationManager.swizzle()
        LocalizationManager.setLanguage(wallpaperModel.effectiveAppLanguageCode)
        NSLog(
            "[AppDelegate] Bundle.main.resourceURL=\(String(describing: Bundle.main.resourceURL))"
        )
        setupStatusBar()
        setupSettingsWindow()
        verifyUpdatePrerequisites()
        setupSparkleUpdater()
    }

    func localized(_ key: String) -> String {
        wallpaperModel.localizedString(key)
    }

    deinit {
        if let monitor: Any = settingsKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

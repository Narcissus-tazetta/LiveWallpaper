import OSLog

/// Centralized `Logger` instances, one per debug category (mirroring the old
/// `NSLog("[Tag] ...")` prefixes). `os.Logger` writes to the unified logging
/// system's lock-free buffer instead of NSLog's synchronous stderr/ASL write,
/// which matters here because several of these categories log from hot paths
/// (window occlusion changes, space transitions) that can fire many times per
/// second.
enum AppLog {
    private static let subsystem = "com.sakana.livewallpaper"

    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let windowRefresh = Logger(subsystem: subsystem, category: "windowRefresh")
    static let spaceTransition = Logger(subsystem: subsystem, category: "spaceTransition")
    static let spaces = Logger(subsystem: subsystem, category: "spaces")
    static let localization = Logger(subsystem: subsystem, category: "localization")
    static let desktopIcons = Logger(subsystem: subsystem, category: "desktopIcons")
    static let lockScreenSync = Logger(subsystem: subsystem, category: "lockScreenSync")
    static let suspend = Logger(subsystem: subsystem, category: "suspend")
    static let sparkle = Logger(subsystem: subsystem, category: "sparkle")
    static let appDelegate = Logger(subsystem: subsystem, category: "appDelegate")
    static let thumbnailCache = Logger(subsystem: subsystem, category: "thumbnailCache")
    static let continuity = Logger(subsystem: subsystem, category: "continuity")
    static let focus = Logger(subsystem: subsystem, category: "focus")
    static let store = Logger(subsystem: subsystem, category: "store")
}

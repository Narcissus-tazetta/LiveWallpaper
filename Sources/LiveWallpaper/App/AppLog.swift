import OSLog

/// Centralized loggers, one per debug category (mirroring the old `NSLog("[Tag] ...")`
/// prefixes). Each writes to the unified log, and `.notice` and above also go to
/// `SessionLog`'s file, which is what survives a crash.
///
/// Log state changes at `.info` or above: Export Diagnostics reads this process's log,
/// which keeps `.info` in memory. Interpolated values follow `os.Logger`'s rules: numbers and
/// Booleans show as they are, anything else shows as `<private>` unless marked
/// `privacy: .public`. Messages are formatted when logged, not lazily like `os.Logger`,
/// because the file needs the text.
enum AppLog {
    static let subsystem = "com.sakana.livewallpaper"

    static let persistence = AppLogger(category: "persistence")
    static let windowRefresh = AppLogger(category: "windowRefresh")
    static let spaceTransition = AppLogger(category: "spaceTransition")
    static let spaces = AppLogger(category: "spaces")
    static let localization = AppLogger(category: "localization")
    static let desktopIcons = AppLogger(category: "desktopIcons")
    static let lockScreenSync = AppLogger(category: "lockScreenSync")
    static let suspend = AppLogger(category: "suspend")
    static let sparkle = AppLogger(category: "sparkle")
    static let appDelegate = AppLogger(category: "appDelegate")
    static let thumbnailCache = AppLogger(category: "thumbnailCache")
    static let proxyCache = AppLogger(category: "proxyCache")
    static let continuity = AppLogger(category: "continuity")
    static let schedule = AppLogger(category: "schedule")
    static let focus = AppLogger(category: "focus")
    static let externalWallpapers = AppLogger(category: "externalWallpapers")
    static let store = AppLogger(category: "store")
    static let automation = AppLogger(category: "automation")
    static let sceneScript = AppLogger(category: "sceneScript")
    static let sceneSound = AppLogger(category: "sceneSound")
    /// System and playback events kept to reconstruct what happened before a crash.
    static let events = AppLogger(category: "events")
}

struct AppLogger: Sendable {
    let category: String
    private let logger: Logger

    init(category: String) {
        self.category = category
        logger = Logger(subsystem: AppLog.subsystem, category: category)
    }

    func info(_ message: AppLogMessage) {
        logger.info("\(message.text, privacy: .public)")
    }

    func notice(_ message: AppLogMessage) {
        logger.notice("\(message.text, privacy: .public)")
        SessionLog.append(level: "notice", category: category, message: message.text)
    }

    func warning(_ message: AppLogMessage) {
        logger.warning("\(message.text, privacy: .public)")
        SessionLog.append(level: "warning", category: category, message: message.text)
    }

    func error(_ message: AppLogMessage) {
        logger.error("\(message.text, privacy: .public)")
        SessionLog.append(level: "error", category: category, message: message.text)
    }
}

enum AppLogPrivacy {
    case `public`
    case `private`
}

enum AppLogFloatFormat {
    case fixed(precision: Int)
}

struct AppLogMessage: ExpressibleByStringInterpolation {
    let text: String

    init(stringLiteral value: String) {
        text = value
    }

    init(stringInterpolation: StringInterpolation) {
        text = stringInterpolation.text
    }

    struct StringInterpolation: StringInterpolationProtocol {
        fileprivate var text = ""

        init(literalCapacity: Int, interpolationCount _: Int) {
            text.reserveCapacity(literalCapacity * 2)
        }

        mutating func appendLiteral(_ literal: String) {
            text += literal
        }

        mutating func appendInterpolation(_ value: some BinaryInteger, privacy: AppLogPrivacy = .public) {
            append(String(value), privacy: privacy)
        }

        mutating func appendInterpolation(_ value: Bool, privacy: AppLogPrivacy = .public) {
            append(String(value), privacy: privacy)
        }

        mutating func appendInterpolation(
            _ value: some BinaryFloatingPoint & CVarArg, format: AppLogFloatFormat? = nil,
            privacy: AppLogPrivacy = .public
        ) {
            switch format {
            case .fixed(let precision):
                append(String(format: "%.\(precision)f", value), privacy: privacy)
            case nil:
                append("\(value)", privacy: privacy)
            }
        }

        mutating func appendInterpolation(_ value: some Any, privacy: AppLogPrivacy = .private) {
            append(String(describing: value), privacy: privacy)
        }

        private mutating func append(_ value: String, privacy: AppLogPrivacy) {
            switch privacy {
            case .public: text += value
            case .private: text += "<private>"
            }
        }
    }
}

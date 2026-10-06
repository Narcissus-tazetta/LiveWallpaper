import Foundation

/// What the LiveWallpaper screen saver should play, written by the app and read by
/// the `.saver` bundle. The saver runs inside the sandboxed legacyScreenSaver host,
/// which can read files anywhere ("/" read-only exception) but cannot read the
/// app's UserDefaults, so this file is the only channel between the two.
///
/// This file is compiled into both the app and the screen saver bundle
/// (scripts/build_screensaver.sh); keep it free of app-only dependencies.
struct ScreenSaverConfig: Codable, Equatable {
    struct Display: Codable, Equatable {
        var videoPath: String
        var fitMode: VideoFitMode
        var zoom: Double
        var offsetX: Double
        var offsetY: Double
        /// Known aspect ratio so the first frame is already placed correctly; the
        /// saver still re-reads it from the asset.
        var videoAspectRatio: Double?
        var trimStart: Double
        var trimEnd: Double?
        var loopStart: Double?
    }

    var formatVersion: Int = 1
    /// Keyed by CGDirectDisplayID in decimal, the same key the app uses per screen.
    var displays: [String: Display]
    /// For screens that are not in `displays` (connected after the file was written).
    var fallback: Display?

    static let currentFormatVersion = 1

    /// `home` must be the real user home: inside the screen saver sandbox
    /// NSHomeDirectory() points at the host's container instead.
    static func fileURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/LiveWallpaper/ScreenSaver", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    func display(forDisplayID displayID: String?) -> Display? {
        displayID.flatMap { displays[$0] } ?? fallback
    }
}

import Foundation

enum ScreenSaverInstallState: Equatable {
    /// No saver bundle shipped with this build.
    case unavailable
    case notInstalled
    case installed
    /// Installed copy differs from the one shipped with this build.
    case updateAvailable
}

/// Installs the bundled LiveWallpaper.saver into ~/Library/Screen Savers and writes
/// the ScreenSaverConfig it reads.
struct ScreenSaverInstaller {
    static let bundleName = "LiveWallpaper.saver"
    private static let buildIDKey = "LWBuildID"

    var fileManager: FileManager = .default
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    var bundledSaverURL: URL? = Self.defaultBundledSaverURL()
    var reloadsHost = true

    var installedSaverURL: URL {
        home.appendingPathComponent("Library/Screen Savers", isDirectory: true)
            .appendingPathComponent(Self.bundleName, isDirectory: true)
    }

    var configURL: URL {
        ScreenSaverConfig.fileURL(home: home)
    }

    static func defaultBundledSaverURL() -> URL? {
        if let url = Bundle.main.resourceURL?.appendingPathComponent(bundleName),
           FileManager.default.fileExists(atPath: url.path)
        {
            return url
        }
        #if DEBUG
            // `swift run` has no app bundle; scripts/build_screensaver.sh writes to
            // .build/screensaver, three levels above .build/<triple>/debug/<exe>.
            if let executable = Bundle.main.executableURL {
                let url = executable.deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("screensaver/\(bundleName)")
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
        #endif
        return nil
    }

    func state() -> ScreenSaverInstallState {
        guard let bundled = bundledSaverURL else {
            return .unavailable
        }
        guard fileManager.fileExists(atPath: installedSaverURL.path) else {
            return .notInstalled
        }
        return Self.buildID(of: installedSaverURL) == Self.buildID(of: bundled) ? .installed : .updateAvailable
    }

    func install() throws {
        guard let bundled = bundledSaverURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = installedSaverURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Copy next to the destination first so the swap is a same-volume replace and
        // a failed copy never leaves a half-written bundle in place.
        let staging = directory.appendingPathComponent(".\(Self.bundleName).\(UUID().uuidString)")
        try fileManager.copyItem(at: bundled, to: staging)
        if fileManager.fileExists(atPath: installedSaverURL.path) {
            _ = try fileManager.replaceItemAt(installedSaverURL, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: installedSaverURL)
        }
        reloadScreenSaverHost()
    }

    func uninstall() throws {
        if fileManager.fileExists(atPath: installedSaverURL.path) {
            try fileManager.removeItem(at: installedSaverURL)
        }
        let configDirectory = configURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: configDirectory.path) {
            try fileManager.removeItem(at: configDirectory)
        }
        reloadScreenSaverHost()
    }

    func writeConfig(_ config: ScreenSaverConfig) throws {
        try fileManager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: configURL, options: .atomic)
    }

    /// The host keeps a loaded saver's code in memory; quit it so the next preview or
    /// activation loads the new bundle. It is relaunched on demand by the system.
    private func reloadScreenSaverHost() {
        guard reloadsHost else {
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["legacyScreenSaver"]
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            AppLog.appDelegate.error("screensaver host reload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads Info.plist directly: Bundle(url:) caches per path and would keep
    /// reporting the replaced bundle's ID after an update.
    private static func buildID(of saver: URL) -> String? {
        let plist = saver.appendingPathComponent("Contents/Info.plist")
        return (NSDictionary(contentsOf: plist) as? [String: Any])?[buildIDKey] as? String
    }
}

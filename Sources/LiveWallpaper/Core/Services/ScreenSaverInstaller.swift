import Foundation

enum ScreenSaverInstallState: Equatable {
    /// No saver bundle shipped with this build.
    case unavailable
    case notInstalled
    case installed
    /// Installed copy differs from the one shipped with this build.
    case updateAvailable
}

enum ScreenSaverInstallerError: LocalizedError {
    case noScreenSaverSetting

    var errorDescription: String? {
        switch self {
        case .noScreenSaverSetting:
            return NSLocalizedString(
                "macOS の壁紙設定にスクリーンセーバーの項目が見つかりませんでした。システム設定でスクリーンセーバーを一度選んでから、もう一度お試しください。",
                comment: ""
            )
        }
    }
}

/// Installs the bundled LiveWallpaper.saver into ~/Library/Screen Savers, selects it as
/// the screen saver, and writes the ScreenSaverConfig it reads. Uninstalling puts the
/// previously selected screen saver back.
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

    var wallpaperStoreURL: URL {
        home
            .appendingPathComponent(
                "Library/Application Support/com.apple.wallpaper/Store/Index.plist"
            )
    }

    /// Kept next to the config so uninstall removes it together, after restoring.
    var previousSelectionURL: URL {
        configURL.deletingLastPathComponent().appendingPathComponent("PreviousSelection.plist")
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
        try select()
    }

    func uninstall() throws {
        try restorePreviousSelection()
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

    private func select() throws {
        guard fileManager.fileExists(atPath: wallpaperStoreURL.path) else {
            throw ScreenSaverInstallerError.noScreenSaverSetting
        }
        var store = try readStore()
        let replaced = ScreenSaverSelection.select(saverURL: installedSaverURL, in: &store)
        guard ScreenSaverSelection.selectedCount(saverURL: installedSaverURL, in: store) > 0 else {
            throw ScreenSaverInstallerError.noScreenSaverSetting
        }
        // An existing file means the last run never restored (crash or force quit);
        // its entries are the real originals, so they win over this run's.
        var saved = fileManager.fileExists(atPath: previousSelectionURL.path)
            ? try ScreenSaverSelection.decode(Data(contentsOf: previousSelectionURL))
            : []
        let savedPaths = Set(saved.map(\.path))
        saved += replaced.filter { !savedPaths.contains($0.path) }
        try fileManager.createDirectory(
            at: previousSelectionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Saved before the Store is touched so a crash in between still restores.
        try ScreenSaverSelection.encode(saved).write(to: previousSelectionURL, options: .atomic)
        try writeStore(store)
    }

    private func restorePreviousSelection() throws {
        guard fileManager.fileExists(atPath: wallpaperStoreURL.path) else {
            return
        }
        let saved = fileManager.fileExists(atPath: previousSelectionURL.path)
            ? try ScreenSaverSelection.decode(Data(contentsOf: previousSelectionURL))
            : []
        var store = try readStore()
        if ScreenSaverSelection.restore(saved, saverURL: installedSaverURL, in: &store) {
            try writeStore(store)
        }
    }

    private func readStore() throws -> [String: Any] {
        let data = try Data(contentsOf: wallpaperStoreURL)
        guard let store = try PropertyListSerialization
            .propertyList(from: data, format: nil) as? [String: Any]
        else {
            throw CocoaError(
                .propertyListReadCorrupt,
                userInfo: [NSFilePathErrorKey: wallpaperStoreURL.path]
            )
        }
        return store
    }

    /// WallpaperAgent only reads the Store at launch, so it is restarted to apply the
    /// change; launchd brings it straight back.
    private func writeStore(_ store: [String: Any]) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: store,
            format: .binary,
            options: 0
        )
        try data.write(to: wallpaperStoreURL, options: .atomic)
        if reloadsHost {
            killAll("WallpaperAgent")
        }
    }

    /// The host keeps a loaded saver's code in memory; quit it so the next preview or
    /// activation loads the new bundle. It is relaunched on demand by the system.
    private func reloadScreenSaverHost() {
        guard reloadsHost else {
            return
        }
        killAll("legacyScreenSaver")
    }

    private func killAll(_ processName: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = [processName]
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            AppLog.appDelegate.error(
                "killall \(processName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Reads Info.plist directly: Bundle(url:) caches per path and would keep
    /// reporting the replaced bundle's ID after an update.
    private static func buildID(of saver: URL) -> String? {
        let plist = saver.appendingPathComponent("Contents/Info.plist")
        return (NSDictionary(contentsOf: plist) as? [String: Any])?[buildIDKey] as? String
    }
}

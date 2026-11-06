import AppKit
import AVFoundation
import Foundation
import OSLog

/// Bundles what a bug report needs into one zip: app/macOS/hardware info, the displays,
/// the runtime state, the settings snapshot, this process's log, the session log of earlier
/// runs and this app's recent crash reports. Video files and web wallpaper URLs are left out,
/// the home folder is written as `~` so the user name does not travel with the report, and
/// crash reports lose their device and boot identifiers.
@MainActor
enum DiagnosticsExporter {
    static func export(from model: WallpaperModel, to outputURL: URL) async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveWallpaper-Diagnostics-\(UUID().uuidString)")
        let contentDir = workDir.appendingPathComponent(
            outputURL.deletingPathExtension().lastPathComponent
        )
        try FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)
        defer { BlockingWork.removeInBackground(workDir) }

        let currentVideo = await currentVideoDescription(model.currentVideoPath)
        let logText = try await Task.detached(priority: .userInitiated) {
            try recentLogText()
        }.value
        let crashReports = try await Task.detached(priority: .userInitiated) {
            try recentCrashReports(in: crashReportDirectories)
        }.value

        try write(systemReport(), to: contentDir.appendingPathComponent("system.txt"))
        try write(
            stateReport(model: model, currentVideo: currentVideo),
            to: contentDir.appendingPathComponent("state.txt")
        )
        try write(
            settingsJSON(model: model),
            to: contentDir.appendingPathComponent("settings.json")
        )
        try write(logText, to: contentDir.appendingPathComponent("log.txt"))
        try write(sessionLogText(), to: contentDir.appendingPathComponent("session-log.txt"))
        if !crashReports.isEmpty {
            let crashDir = contentDir.appendingPathComponent("crash-reports")
            try FileManager.default.createDirectory(at: crashDir, withIntermediateDirectories: true)
            for (name, text) in crashReports {
                try write(text, to: crashDir.appendingPathComponent(name))
            }
        }

        try await PackageArchiveWriter().createPackage(from: contentDir, outputURL: outputURL)
    }

    static func defaultFileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "LiveWallpaper-Diagnostics-\(formatter.string(from: now)).zip"
    }

    /// Replaces the home folder path so reports do not carry the account name.
    nonisolated static func redactingHome(_ text: String) -> String {
        text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(redactingHome(text).utf8).write(to: url, options: .atomic)
    }

    // MARK: - Sections

    private static func systemReport() -> String {
        let bundle = Bundle.main
        let info = ProcessInfo.processInfo
        var lines: [String] = []
        lines
            .append(
                "App version: \(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")"
            )
        lines
            .append(
                "App build: \(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")"
            )
        lines
            .append(
                "Bundle ID: \(bundle.bundleIdentifier ?? "none (not running from an app bundle)")"
            )
        lines.append("App path: \(bundle.bundlePath)")
        lines.append("macOS: \(info.operatingSystemVersionString)")
        lines.append("Hardware model: \(sysctlString("hw.model") ?? "unknown")")
        lines.append("CPU: \(sysctlString("machdep.cpu.brand_string") ?? "unknown")")
        #if arch(arm64)
            lines.append("App architecture: arm64")
        #else
            lines.append("App architecture: x86_64")
        #endif
        lines.append("Translated (Rosetta): \(sysctlInt("sysctl.proc_translated") == 1)")
        lines.append("Memory: \(info.physicalMemory / 1_073_741_824) GB")
        lines.append("Processors: \(info.activeProcessorCount)")
        lines.append("Thermal state: \(thermalStateName(info.thermalState))")
        lines.append("Low Power Mode: \(info.isLowPowerModeEnabled)")
        lines.append("Uptime: \(Int(info.systemUptime / 60)) min")
        lines.append("Preferred languages: \(Locale.preferredLanguages.joined(separator: ", "))")
        lines.append("")
        lines.append("Displays:")
        for screen in NSScreen.screens {
            let number = screen
                .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            var line = "- \(screen.localizedName) id=\(number?.stringValue ?? "?")"
            line += " frame=\(describe(screen.frame)) scale=\(screen.backingScaleFactor)"
            line += " edrPotential=\(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)"
            if screen == NSScreen.main {
                line += " (main)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func stateReport(model: WallpaperModel, currentVideo: String) -> String {
        var lines: [String] = []
        lines.append("Wallpaper kind: \(model.wallpaperKind.rawValue)")
        lines.append("Current video: \(model.currentVideoPath ?? "none")")
        lines.append("Current video format: \(currentVideo)")
        lines.append("Library videos: \(model.libraryVideoPaths.count)")
        lines.append("Playlists: \(model.playlists.count)")
        lines
            .append(
                "Web wallpapers: \(model.webWallpaperSources.count) (feature enabled: \(model.webWallpaperFeatureEnabled))"
            )
        lines.append("Web wallpaper load state: \(model.webWallpaperLoadState)")
        lines.append("Manual pause: \(model.manualPauseActive)")
        lines.append("On battery: \(model.isOnBatteryPower)")
        lines
            .append(
                "HDR display: \(model.effectiveHDRDisplay) (setting: \(model.hdrDisplayEnabled))"
            )
        lines.append("System Reduce Motion: \(model.systemReduceMotionEnabled)")
        lines.append("Window bounds readable (coverage): \(model.windowBoundsReadableForCoverage)")
        lines.append("Screen recording trusted: \(CGPreflightScreenCaptureAccess())")
        lines.append("Screen saver: \(model.screenSaverInstallState)")
        lines
            .append(
                "Hot key registration failures: \(model.hotKeyRegistrationFailures.map { "\($0)" }.sorted())"
            )
        lines.append("Persistence failure: \(model.persistenceFailureMessage ?? "none")")
        lines.append("Desktop icons failure: \(model.desktopIconsFailureMessage ?? "none")")
        lines.append("Screen saver error: \(model.screenSaverErrorMessage ?? "none")")
        lines.append("Web wallpaper error: \(model.webWallpaperErrorMessage ?? "none")")
        lines.append("Media import error: \(model.mediaImportErrorMessage ?? "none")")
        lines.append("")
        lines.append("Displays known to the app:")
        for screen in model.displayScreens {
            lines.append("- \(screen.name) id=\(screen.id) frame=\(describe(screen.frame))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func settingsJSON(model: WallpaperModel) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(SettingsTransfer.snapshot(from: model))
        return String(decoding: data, as: UTF8.self)
    }

    private static func currentVideoDescription(_ path: String?) async -> String {
        guard let path else {
            return "none"
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        // A broken or missing video is exactly what a report may be about, so the failure
        // goes into the report instead of aborting the export.
        do {
            let duration = try await asset.load(.duration)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                return "no video track (duration \(String(format: "%.2f", duration.seconds)) s)"
            }
            let (size, fps, formats) = try await track.load(
                .naturalSize, .nominalFrameRate, .formatDescriptions
            )
            let codecs = formats.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) }
            let transfer = formats.first.flatMap {
                CMFormatDescriptionGetExtension(
                    $0,
                    extensionKey: kCMFormatDescriptionExtension_TransferFunction
                )
            } as? String
            return "\(Int(size.width))x\(Int(size.height)) \(String(format: "%.2f", fps)) fps"
                + " codec=\(codecs.joined(separator: ","))"
                + " transfer=\(transfer ?? "unspecified")"
                + " duration=\(String(format: "%.2f", duration.seconds)) s"
        } catch {
            return "failed to read: \(error.localizedDescription)"
        }
    }

    /// This process's entries since launch. Reading the system-wide store needs admin
    /// rights, while the current-process scope works for any user.
    private nonisolated static func recentLogText() throws -> String {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(
            at: store.position(timeIntervalSinceLatestBoot: 0),
            matching: NSPredicate(format: "subsystem == %@", "com.sakana.livewallpaper")
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines: [String] = []
        for case let entry as OSLogEntryLog in entries {
            lines.append(
                "\(formatter.string(from: entry.date)) [\(levelName(entry.level))] [\(entry.category)] \(entry.composedMessage)"
            )
        }
        // Keeps the report small enough to attach to an issue; the newest lines matter most.
        let maxLines = 5000
        if lines.count > maxLines {
            lines = ["… \(lines.count - maxLines) older lines omitted …"] + lines.suffix(maxLines)
        }
        return lines.isEmpty ? "(no log entries)\n" : lines.joined(separator: "\n") + "\n"
    }

    private static func sessionLogText() -> String {
        // A missing or unreadable session log is itself a finding, not a reason to abort.
        do {
            return try SessionLog.recentText()
        } catch {
            return "session log unreadable: \(error.localizedDescription)\n"
        }
    }

    // MARK: - Crash reports

    nonisolated static let crashReportDirectories: [URL] = {
        let reports = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        return [reports, reports.appendingPathComponent("Retired", isDirectory: true)]
    }()

    /// Fields that identify the Mac, the boot or the report itself rather than the crash.
    nonisolated static let crashReportIdentifyingKeys: Set<String> = [
        "crashReporterKey", "bootSessionUUID", "sleepWakeUUID", "incident", "incident_id",
        "deviceIdentifierForVendor", "trialInfo", "logWritingSignature"
    ]

    /// The newest reports of this app from the last 30 days, redacted, keyed by file name.
    /// Files named after other processes are never opened.
    nonisolated static func recentCrashReports(
        in directories: [URL], now: Date = Date(), limit: Int = 5
    ) throws -> [(String, String)] {
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        var candidates: [(url: URL, date: Date)] = []
        for directory in directories where FileManager.default.fileExists(atPath: directory.path) {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
            )
            for url in urls where isOwnCrashReport(fileName: url.lastPathComponent) {
                let date = try url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                if let date, date >= cutoff {
                    candidates.append((url, date))
                }
            }
        }
        return try candidates.sorted { $0.date > $1.date }.prefix(limit).map { candidate in
            let name = candidate.url.lastPathComponent
            let text = try String(contentsOf: candidate.url, encoding: .utf8)
            // A report that does not parse cannot be redacted, so only the failure goes in.
            do {
                return try (name, redactedCrashReport(text))
            } catch {
                return (name + ".txt", "could not redact \(name): \(error.localizedDescription)\n")
            }
        }
    }

    /// `LiveWallpaper-<date>.ips`, plus the `<Kind>_LiveWallpaper-<date>.ips` form macOS uses
    /// for resource and user-fault reports.
    nonisolated static func isOwnCrashReport(fileName: String) -> Bool {
        guard fileName.hasSuffix(".ips") else { return false }
        let processPart = fileName.split(separator: "_", maxSplits: 1).last
            .map(String.init) ?? fileName
        return processPart.hasPrefix("LiveWallpaper-")
    }

    /// An `.ips` file is a one-line JSON header followed by a JSON body. Both are rewritten
    /// without the identifying fields; stacks, images and the exception stay as they are.
    nonisolated static func redactedCrashReport(_ text: String) throws -> String {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let jsonParts = try parts.map { part -> Any in
            try JSONSerialization.jsonObject(with: Data(part.utf8), options: [.fragmentsAllowed])
        }
        let rewritten = try jsonParts.enumerated().map { index, object -> String in
            let options: JSONSerialization.WritingOptions = index == 0
                ? [.withoutEscapingSlashes, .sortedKeys]
                : [.withoutEscapingSlashes, .sortedKeys, .prettyPrinted]
            let data = try JSONSerialization.data(
                withJSONObject: removingIdentifyingKeys(object),
                options: options
            )
            return String(decoding: data, as: UTF8.self)
        }
        return rewritten.joined(separator: "\n") + "\n"
    }

    private nonisolated static func removingIdentifyingKeys(_ object: Any) -> Any {
        if let dictionary = object as? [String: Any] {
            return dictionary.filter { !crashReportIdentifyingKeys.contains($0.key) }
                .mapValues(removingIdentifyingKeys)
        }
        if let array = object as? [Any] {
            return array.map(removingIdentifyingKeys)
        }
        return object
    }

    // MARK: - Helpers

    private static func describe(_ rect: CGRect) -> String {
        "\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height))"
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? String(code)
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private nonisolated static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        default: return "undefined"
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }
        return value
    }
}

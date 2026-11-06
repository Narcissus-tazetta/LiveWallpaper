import AppKit
import Foundation
import OSLog

/// A log on disk that outlives the process, so Export Diagnostics can still show what led up
/// to a crash after the app has been relaunched. The unified log cannot serve this: reading a
/// previous process's entries needs admin rights, and `.info` entries are never persisted.
///
/// `AppLogger` hands over every `.notice` and above, and the line is written before the call
/// returns, since a crash right after it must not lose it. Lines logged before `start()` are
/// not kept.
enum SessionLog {
    static let directoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/LiveWallpaper", isDirectory: true)
    static let fileURL = directoryURL.appendingPathComponent("session.log")
    static let previousFileURL = directoryURL.appendingPathComponent("session.1.log")

    /// Failures of the file itself go only to the unified log; going through `AppLog` would
    /// come back here.
    fileprivate static let failureLogger = Logger(
        subsystem: AppLog.subsystem,
        category: "sessionLog"
    )
    private static let launchMarker = "=== launch"
    private static let quitMarker = "=== quit"
    fileprivate static let maxFileSize = 1_048_576
    private static let sink = Sink()

    /// Starts the file for this run. Call before anything else logs.
    @MainActor
    static func start() {
        sink.open()
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        sink.writeLine(
            "\(launchMarker) version=\(version) build=\(build) pid=\(ProcessInfo.processInfo.processIdentifier)"
                + " macOS=\(ProcessInfo.processInfo.operatingSystemVersionString) ==="
        )
        observeSystemEvents()
    }

    /// Records a clean quit, so the next launch can tell a crash from a quit.
    static func finish() {
        sink.writeLine("\(quitMarker) ===")
    }

    static func append(level: String, category: String, message: String) {
        sink
            .writeLine(
                "[\(level)] [\(category)] \(message.replacingOccurrences(of: "\n", with: " ⏎ "))"
            )
    }

    /// Both files oldest first, as one text. A launch marker that no quit marker follows is a
    /// run that ended in a crash, a force quit or a power loss; the line after it says so.
    static func recentText() throws -> String {
        var lines: [String] = []
        for url in [previousFileURL, fileURL]
            where FileManager.default.fileExists(atPath: url.path)
        {
            lines += try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
        return annotatingUnfinishedRuns(lines).joined(separator: "\n") + "\n"
    }

    static func annotatingUnfinishedRuns(_ lines: [String]) -> [String] {
        var result: [String] = []
        var runOpen = false
        for line in lines {
            if line.contains(launchMarker) {
                if runOpen {
                    result
                        .append(
                            "--- the run above ended without quitting (crash, force quit or power loss) ---"
                        )
                }
                runOpen = true
            } else if line.contains(quitMarker) {
                runOpen = false
            }
            result.append(line)
        }
        return result
    }

    // MARK: - System events

    @MainActor private static var observers: [NSObjectProtocol] = []
    @MainActor private static var memoryPressureSource: DispatchSourceMemoryPressure?

    @MainActor
    private static func observeSystemEvents() {
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        let named: [(NotificationCenter, Notification.Name, String)] = [
            (distributed, Notification.Name("com.apple.screenIsLocked"), "screen locked"),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), "screen unlocked"),
            (
                distributed,
                Notification.Name("com.apple.screensaver.didstart"),
                "screen saver started"
            ),
            (
                distributed,
                Notification.Name("com.apple.screensaver.didstop"),
                "screen saver stopped"
            ),
            (workspace, NSWorkspace.willSleepNotification, "system will sleep"),
            (workspace, NSWorkspace.didWakeNotification, "system woke"),
            (workspace, NSWorkspace.screensDidSleepNotification, "displays slept"),
            (workspace, NSWorkspace.screensDidWakeNotification, "displays woke"),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, "user session inactive"),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, "user session active")
        ]
        observers = named.map { center, name, message in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                AppLog.events.notice("\(message, privacy: .public)")
            }
        }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    AppLog.events.notice("displays changed: \(describeScreens(), privacy: .public)")
                }
            }
        )
        AppLog.events.notice("displays: \(describeScreens(), privacy: .public)")

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global()
        )
        source.setEventHandler { [weak source] in
            guard let source else { return }
            let level = source.data.contains(.critical) ? "critical" : "warning"
            AppLog.events.notice(
                "memory pressure \(level, privacy: .public), footprint=\(footprintMegabytes(), privacy: .public) MB"
            )
        }
        source.resume()
        memoryPressureSource = source
    }

    @MainActor
    private static func describeScreens() -> String {
        let screens = NSScreen.screens.map { screen in
            let number = screen
                .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let frame = screen.frame
            return "\(number?.stringValue ?? "?") \(Int(frame.width))x\(Int(frame.height))@\(screen.backingScaleFactor)x"
        }
        return "\(screens.count) [\(screens.joined(separator: ", "))]"
    }

    private static func footprintMegabytes() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>
            .size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? String(info.phys_footprint / 1_048_576) : "unknown"
    }

    // MARK: - File

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var handle: FileHandle?
        private var fileSize = 0
        private let formatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = .current
            return formatter
        }()

        func open() {
            lock.withLock {
                do {
                    try FileManager.default.createDirectory(
                        at: directoryURL,
                        withIntermediateDirectories: true
                    )
                    try openLocked()
                } catch {
                    // Diagnostics must never stop the app; the export notes the missing file.
                    failureLogger
                        .error(
                            "session log unavailable: \(error.localizedDescription, privacy: .public)"
                        )
                }
            }
        }

        func writeLine(_ message: String) {
            lock.withLock {
                guard let handle else { return }
                let data = Data("\(formatter.string(from: Date())) \(message)\n".utf8)
                do {
                    try handle.write(contentsOf: data)
                    fileSize += data.count
                    if fileSize > maxFileSize {
                        try openLocked()
                    }
                } catch {
                    self.handle = nil
                    failureLogger
                        .error(
                            "session log write failed: \(error.localizedDescription, privacy: .public)"
                        )
                }
            }
        }

        /// Opens the file for appending, first moving it aside when it has grown too large.
        /// O_APPEND keeps whole lines when a development build and the installed app run at once.
        private func openLocked() throws {
            try handle?.close()
            handle = nil
            if FileManager.default.fileExists(atPath: fileURL.path),
               let size = try FileManager.default
               .attributesOfItem(atPath: fileURL.path)[.size] as? Int,
               size > maxFileSize
            {
                if FileManager.default.fileExists(atPath: previousFileURL.path) {
                    try FileManager.default.removeItem(at: previousFileURL)
                }
                try FileManager.default.moveItem(at: fileURL, to: previousFileURL)
            }
            let descriptor = Darwin.open(
                fileURL.path,
                O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC,
                0o644
            )
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            fileSize = try FileManager.default
                .attributesOfItem(atPath: fileURL.path)[.size] as? Int ?? 0
        }
    }
}

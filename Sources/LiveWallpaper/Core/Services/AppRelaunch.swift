import AppKit

enum AppRelaunch {
    /// Starts the new instance from a detached shell after a short wait: `open` would
    /// otherwise hand the launch to the instance that is still running.
    @MainActor
    static func perform() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundleURL.path]
        do {
            try process.run()
        } catch {
            AppLog.appDelegate.error("relaunch failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        NSApp.terminate(nil)
    }
}

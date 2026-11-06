import AppKit

extension NSWindow {
    /// Runs `action` once, after the sheet now attached to this window closes. Sheets are
    /// shown one at a time, so a prompt that finds the window busy waits for this instead of
    /// polling `attachedSheet`.
    @MainActor
    func afterAttachedSheetEnds(_ action: @escaping @MainActor () -> Void) {
        final class Registration: @unchecked Sendable {
            var token: NSObjectProtocol?
        }
        let registration = Registration()
        registration.token = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndSheetNotification, object: self, queue: .main
        ) { _ in
            if let token = registration.token {
                NotificationCenter.default.removeObserver(token)
                registration.token = nil
            }
            MainActor.assumeIsolated { action() }
        }
    }
}

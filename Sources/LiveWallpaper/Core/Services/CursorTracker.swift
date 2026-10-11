import AppKit

/// Reports the cursor position (global screen coordinates) while it moves, at most
/// `maxRate` times per second, and once more when it comes to rest so the last
/// position is never dropped.
///
/// Global mouse monitors need no permission (only key events require Accessibility),
/// but they never see events sent to this app, so a local monitor covers the
/// settings window.
@MainActor
final class CursorTracker {
    private let minInterval: TimeInterval
    private let onMove: (CGPoint) -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastDelivery: TimeInterval = 0
    private var trailingWorkItem: DispatchWorkItem?

    private static let mask: NSEvent.EventTypeMask = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
    ]

    init(maxRate: Double = 60, onMove: @escaping (CGPoint) -> Void) {
        minInterval = 1 / maxRate
        self.onMove = onMove
    }

    var isRunning: Bool {
        globalMonitor != nil
    }

    func start() {
        guard globalMonitor == nil else {
            return
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mask) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleMove()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.mask) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleMove()
            }
            return event
        }
        onMove(NSEvent.mouseLocation)
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        trailingWorkItem?.cancel()
        trailingWorkItem = nil
    }

    private func handleMove() {
        let now = ProcessInfo.processInfo.systemUptime
        trailingWorkItem?.cancel()
        if now - lastDelivery >= minInterval {
            lastDelivery = now
            onMove(NSEvent.mouseLocation)
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                self.lastDelivery = ProcessInfo.processInfo.systemUptime
                self.onMove(NSEvent.mouseLocation)
            }
        }
        trailingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + minInterval, execute: workItem)
    }
}

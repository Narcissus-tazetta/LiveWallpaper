import AppKit
import ApplicationServices
import Foundation

final class ForegroundCoverageAXObserver {
    private final class CallbackToken {
        weak var observer: ForegroundCoverageAXObserver?
        let generation: UInt64
        var handler: (() -> Void)?

        init(
            observer: ForegroundCoverageAXObserver,
            generation: UInt64,
            handler: @escaping () -> Void
        ) {
            self.observer = observer
            self.generation = generation
            self.handler = handler
        }
    }

    private static let notificationNames: [CFString] = [
        kAXFocusedWindowChangedNotification as CFString,
        kAXWindowMovedNotification as CFString,
        kAXWindowResizedNotification as CFString,
        kAXMainWindowChangedNotification as CFString
    ]

    private static let axCallback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else {
            return
        }
        let token = Unmanaged<CallbackToken>.fromOpaque(refcon).takeUnretainedValue()
        guard let observer = token.observer else {
            return
        }
        guard token.generation == observer.generation else {
            return
        }
        token.handler?()
    }

    private var generation: UInt64 = 0
    private var axObserver: AXObserver?
    private var observedAppElement: AXUIElement?
    private var observedAppPID: pid_t?
    private var callbackToken: Unmanaged<CallbackToken>?

    var attachedPID: pid_t? {
        observedAppPID
    }

    var isAttached: Bool {
        axObserver != nil
    }

    @discardableResult
    func attach(to app: NSRunningApplication, handler: @escaping () -> Void) -> Bool {
        let pid = app.processIdentifier
        if observedAppPID == pid, axObserver != nil {
            return true
        }

        detach()

        generation &+= 1
        let attachGeneration = generation

        let token = CallbackToken(observer: self, generation: attachGeneration, handler: handler)
        let retainedToken = Unmanaged.passRetained(token)
        callbackToken = retainedToken
        let refcon = retainedToken.toOpaque()

        var newObserver: AXObserver?
        let createResult = AXObserverCreate(pid, Self.axCallback, &newObserver)
        guard createResult == .success, let observer = newObserver else {
            detach()
            return false
        }

        let appElement = AXUIElementCreateApplication(pid)

        for notification in Self.notificationNames {
            let addResult = AXObserverAddNotification(observer, appElement, notification, refcon)
            if addResult != .success {
                detach()
                return false
            }
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )

        axObserver = observer
        observedAppElement = appElement
        observedAppPID = pid
        return true
    }

    func detach() {
        generation &+= 1

        guard let observer = axObserver else {
            observedAppElement = nil
            observedAppPID = nil
            releaseCallbackToken()
            return
        }

        if let appElement = observedAppElement {
            for notification in Self.notificationNames {
                _ = AXObserverRemoveNotification(observer, appElement, notification)
            }
        }

        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )

        axObserver = nil
        observedAppElement = nil
        observedAppPID = nil
        releaseCallbackToken()
    }

    private func releaseCallbackToken() {
        if let retainedToken = callbackToken {
            retainedToken.release()
            callbackToken = nil
        }
    }
}

import AppKit
import ApplicationServices

/// Lets a web wallpaper's buttons work although its window ignores the mouse.
///
/// Files and folders on the desktop always win: a press only reaches the page when
/// Finder reports empty desktop under the cursor (needs the Accessibility
/// permission) and nothing else is in front of the desktop. Button-less movement and
/// the move/up of a press that started on the page are delivered regardless.
@MainActor
extension WallpaperModel {
    func setWebInteractionEnabled(_ enabled: Bool) {
        guard webInteractionEnabled != enabled else {
            return
        }
        webInteractionEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: PrefsKey.webWallpaperInteraction)
        if enabled {
            // Opens the system prompt the first time; later calls only read the state.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        updateWebInteractionMonitor()
    }

    /// The permission is granted in System Settings, so pick it up when the user comes back.
    func observeAppActivationForWebInteraction() {
        guard webInteractionObserver == nil else {
            return
        }
        webInteractionObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateWebInteractionMonitor()
            }
        }
    }

    func updateWebInteractionMonitor() {
        let active = webInteractionEnabled && clickThrough && hasWebDisplay && AXIsProcessTrusted()
        if active, webInteractionMonitor == nil {
            webInteractionMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel]
            ) { [weak self] event in
                let type = event.type
                // scrollingDelta* raises for any other event type.
                var scroll = CGVector.zero
                if type == .scrollWheel {
                    let unit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                    scroll = CGVector(dx: -event.scrollingDeltaX * unit, dy: -event.scrollingDeltaY * unit)
                }
                MainActor.assumeIsolated {
                    self?.handleWebInteraction(type: type, scroll: scroll)
                }
            }
        } else if !active, let monitor = webInteractionMonitor {
            NSEvent.removeMonitor(monitor)
            webInteractionMonitor = nil
            webInteractionPressTarget = nil
            webInteractionWheelProbe = nil
        }
    }

    private func handleWebInteraction(type: NSEvent.EventType, scroll: CGVector) {
        let location = NSEvent.mouseLocation
        switch type {
        case .mouseMoved:
            // A pointer-move burst is coalesced to ~60 Hz so evaluateJavaScript calls do not pile up.
            let now = ProcessInfo.processInfo.systemUptime
            guard now - webInteractionLastHover >= 1.0 / 60, let (view, point) = webViewUnderCursor(at: location) else {
                return
            }
            webInteractionLastHover = now
            view.forwardPointer(.hover, at: point)
        case .leftMouseDown:
            webInteractionPressTarget = nil
            guard let (view, point) = webViewUnderCursor(at: location), isEmptyDesktop(at: location) else {
                return
            }
            webInteractionPressTarget = view
            view.forwardPointer(.down, at: point) { [weak self, weak view] in
                if self?.webInteractionPressTarget === view {
                    self?.webInteractionPressTarget = nil
                }
            }
        case .leftMouseDragged:
            guard let view = webInteractionPressTarget, let (_, point) = webViewUnderCursor(at: location) else {
                return
            }
            view.forwardPointer(.move, at: point)
        case .leftMouseUp:
            guard let view = webInteractionPressTarget else {
                return
            }
            webInteractionPressTarget = nil
            if let (_, point) = webViewUnderCursor(at: location) {
                view.forwardPointer(.up, at: point)
            } else {
                view.forwardPointer(.up, at: CGPoint(x: -1, y: -1))
            }
        case .scrollWheel:
            guard let (view, point) = webViewUnderCursor(at: location), wheelAccepted(at: location) else {
                return
            }
            view.forwardPointer(.wheel, at: point, scroll: scroll)
        default:
            break
        }
    }

    /// The Finder check costs a window list and an Accessibility call, so a wheel burst
    /// shares one answer while the cursor stays put.
    private func wheelAccepted(at location: CGPoint) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let probe = webInteractionWheelProbe, now - probe.time < 0.3,
           hypot(probe.location.x - location.x, probe.location.y - location.y) < 40
        {
            return probe.accepted
        }
        let accepted = isEmptyDesktop(at: location)
        webInteractionWheelProbe = (location, now, accepted)
        return accepted
    }

    private func webViewUnderCursor(at location: CGPoint) -> (WebPlayerView, CGPoint)? {
        for entry in webDisplayEntries {
            guard let frame = entry.view.window?.frame, frame.contains(location),
                  !coveredDisplayIDs.contains(entry.displayID)
            else {
                continue
            }
            return (entry.view, CGPoint(x: location.x - frame.minX, y: frame.maxY - location.y))
        }
        return nil
    }

    private func isEmptyDesktop(at location: CGPoint) -> Bool {
        guard let primaryHeight = NSScreen.screens.first?.frame.height,
              isDesktopClick(at: location)
        else {
            return false
        }
        return DesktopIconProbe.isEmptyDesktop(at: CGPoint(x: location.x, y: primaryHeight - location.y))
    }
}

enum DesktopIconProbe {
    /// `point` is in global coordinates with the origin at the top-left of the main display.
    /// Anything Finder reports other than the desktop background (icons, stacks, labels)
    /// counts as occupied, and so does a failed lookup.
    static func isEmptyDesktop(at point: CGPoint) -> Bool {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return false
        }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &element) == .success,
              let element
        else {
            return false
        }
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        return (subrole as? String) == "AXDesktop"
    }
}

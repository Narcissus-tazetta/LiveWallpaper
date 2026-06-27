import AppKit
import ApplicationServices
import Foundation

@MainActor
extension WallpaperModel {
    @discardableResult
    func setSuspendWhenOtherAppFullScreen(_ enabled: Bool) -> Bool {
        guard suspendWhenOtherAppFullScreen != enabled else {
            if enabled {
                evaluateForegroundCoverageState()
            } else {
                applyCoveringAppSuspension(false)
            }
            return true
        }

        UserDefaults.standard.set(enabled, forKey: "suspendWhenOtherAppFullScreen")
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            guard self.suspendWhenOtherAppFullScreen != enabled else {
                return
            }
            self.suspendWhenOtherAppFullScreen = enabled
            self.configureForegroundCoverageMonitoring()
            self.evaluateForegroundCoverageState()
        }
        return true
    }

    func setSuspendDetectionMode(_ mode: SuspendDetectionMode) {
        guard suspendDetectionMode != mode else {
            evaluateForegroundCoverageState()
            return
        }

        UserDefaults.standard.set(mode.rawValue, forKey: "suspendDetectionMode")
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            guard self.suspendDetectionMode != mode else {
                return
            }
            self.suspendDetectionMode = mode
            self.refreshAccessibilityTrustForCoverage()
            self.configureForegroundCoverageMonitoring()
            self.evaluateForegroundCoverageState()
        }
    }

    func addSuspendExclusionBundleID(_ bundleID: String) {
        let normalized = normalizeBundleID(bundleID)
        guard !normalized.isEmpty else {
            return
        }
        guard !suspendExclusionBundleIDs.contains(normalized) else {
            return
        }
        suspendExclusionBundleIDs.append(normalized)
        suspendExclusionBundleIDs.sort()
        UserDefaults.standard.set(suspendExclusionBundleIDs, forKey: "suspendExclusionBundleIDs")
        evaluateForegroundCoverageState()
    }

    func removeSuspendExclusionBundleID(_ bundleID: String) {
        let normalized = normalizeBundleID(bundleID)
        guard let index = suspendExclusionBundleIDs.firstIndex(of: normalized) else {
            return
        }
        suspendExclusionBundleIDs.remove(at: index)
        UserDefaults.standard.set(suspendExclusionBundleIDs, forKey: "suspendExclusionBundleIDs")
        evaluateForegroundCoverageState()
    }

    @discardableResult
    func addFrontmostAppToSuspendExclusions() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        guard let bundleID = app.bundleIdentifier else {
            return false
        }
        addSuspendExclusionBundleID(bundleID)
        return true
    }

    @discardableResult
    func addSuspendExclusionFromAppURL(_ appURL: URL) -> Bool {
        let resolvedURL = appURL.resolvingSymlinksInPath()
        guard resolvedURL.pathExtension.lowercased() == "app" else {
            return false
        }
        guard let bundle = Bundle(url: resolvedURL),
            let bundleID = bundle.bundleIdentifier
        else {
            return false
        }
        addSuspendExclusionBundleID(bundleID)
        return true
    }

    func configureForegroundCoverageMonitoring() {
        if let observer = frontmostAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            frontmostAppObserver = nil
        }
        if let observer = activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activeSpaceObserver = nil
        }

        guard suspendWhenOtherAppFullScreen else {
            refreshAccessibilityTrustForCoverage()
            coverageEvaluationWorkItem?.cancel()
            coverageEvaluationWorkItem = nil
            activeSpaceTransitionWorkItem?.cancel()
            activeSpaceTransitionWorkItem = nil
            activeSpaceCoverageWorkItems.forEach { $0.cancel() }
            activeSpaceCoverageWorkItems.removeAll()
            removeAXObserver()
            applyCoveringAppSuspension(false)
            return
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        refreshAccessibilityTrustForCoverage()
        frontmostAppObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.suspendDetectionMode == .preciseWindowCoverage {
                    self?.updateAXObserverForFrontmostApplication()
                }
                self?.scheduleForegroundCoverageEvaluation()
            }
        }

        activeSpaceObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleActiveSpaceDidChange()
            }
        }

        if suspendDetectionMode == .preciseWindowCoverage {
            updateAXObserverForFrontmostApplication()
        } else {
            removeAXObserver()
        }
    }

    private func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func refreshAccessibilityTrustForCoverage() -> Bool {
        let trusted = isAccessibilityTrusted()
        guard accessibilityTrustedForCoverage != trusted else {
            return trusted
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            guard self.accessibilityTrustedForCoverage != trusted else {
                return
            }
            self.accessibilityTrustedForCoverage = trusted
        }
        return trusted
    }

    func requestAccessibilityPermissionForCoverage() {
        let options =
            [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(url)
        }

        pollAccessibilityPermissionAfterRequest()
    }

    private func pollAccessibilityPermissionAfterRequest() {
        for delay in [0.2, 0.8, 1.6, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else {
                    return
                }
                let trusted = self.refreshAccessibilityTrustForCoverage()
                if trusted {
                    self.updateAXObserverForFrontmostApplication()
                }
                self.scheduleForegroundCoverageEvaluation()
            }
        }
    }

    private func ensureAXCoverageObserver() -> ForegroundCoverageAXObserver {
        if let axCoverageObserver {
            return axCoverageObserver
        }
        let observer = ForegroundCoverageAXObserver()
        axCoverageObserver = observer
        return observer
    }

    private func updateAXObserverForFrontmostApplication() {
        guard suspendWhenOtherAppFullScreen else {
            removeAXObserver()
            return
        }

        let trusted = refreshAccessibilityTrustForCoverage()
        guard trusted else {
            removeAXObserver()
            return
        }

        guard let app = NSWorkspace.shared.frontmostApplication else {
            removeAXObserver()
            return
        }

        _ = ensureAXCoverageObserver().attach(to: app) { [weak self] in
            Task { @MainActor in
                self?.scheduleForegroundCoverageEvaluation()
            }
        }
    }

    func removeAXObserver() {
        axCoverageObserver?.detach()
    }

    func scheduleForegroundCoverageEvaluation() {
        guard suspendWhenOtherAppFullScreen else {
            evaluateForegroundCoverageState()
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastCoverageEvaluationAt
        if elapsed >= 0.2 {
            lastCoverageEvaluationAt = now
            evaluateForegroundCoverageState()
            return
        }

        coverageEvaluationGeneration &+= 1
        let generation = coverageEvaluationGeneration
        coverageEvaluationWorkItem?.cancel()
        let delay = max(0.2 - elapsed, 0.05)
        scheduleForegroundCoverageEvaluation(after: delay, generation: generation)
    }

    private func scheduleForegroundCoverageEvaluation(
        after delay: TimeInterval,
        generation: UInt64? = nil
    ) {
        coverageEvaluationGeneration &+= generation == nil ? 1 : 0
        let expectedGeneration = generation ?? coverageEvaluationGeneration
        coverageEvaluationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            guard expectedGeneration == coverageEvaluationGeneration else {
                return
            }
            lastCoverageEvaluationAt = CFAbsoluteTimeGetCurrent()
            evaluateForegroundCoverageState()
            coverageEvaluationWorkItem = nil
        }
        coverageEvaluationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0.05), execute: workItem)
    }

    private func handleActiveSpaceDidChange() {
        guard suspendWhenOtherAppFullScreen, currentVideoPath != nil else {
            scheduleForegroundCoverageEvaluation()
            return
        }

        activeSpaceTransitionWorkItem?.cancel()
        scheduleActiveSpaceWindowRefresh()
        scheduleActiveSpaceCoverageEvaluations()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            activeSpaceTransitionWorkItem = nil
            lastCoverageEvaluationAt = CFAbsoluteTimeGetCurrent()
            scheduleActiveSpaceWindowRefresh()
        }
        activeSpaceTransitionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: workItem)
    }

    private func scheduleActiveSpaceCoverageEvaluations() {
        activeSpaceCoverageWorkItems.forEach { $0.cancel() }
        activeSpaceCoverageWorkItems.removeAll()

        for delay in [0.0, 0.15, 0.45, 0.9] {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else {
                    return
                }
                if suspendDetectionMode == .preciseWindowCoverage {
                    updateAXObserverForFrontmostApplication()
                }
                lastCoverageEvaluationAt = CFAbsoluteTimeGetCurrent()
                evaluateForegroundCoverageState()
            }
            activeSpaceCoverageWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    func evaluateForegroundCoverageState() {
        guard suspendWhenOtherAppFullScreen else {
            applyCoveringAppSuspension(false)
            return
        }
        guard currentVideoPath != nil else {
            applyCoveringAppSuspension(false)
            return
        }

        let snapshot = foregroundCoverageSnapshot()
        if suspendDetectionMode == .frontmostAppPresence {
            removeAXObserver()
        }
        applyCoveringAppSuspension(
            ForegroundCoverageEngine.suspendedDisplayIDs(
                mode: suspendDetectionMode,
                snapshot: snapshot
            )
        )
    }

    private func foregroundCoverageSnapshot() -> ForegroundCoverageSnapshot {
        let app = frontmostAppStateForCoverageEvaluation()
        let targetIDs = Set(targetScreens().map { displayIDString(for: $0) })

        guard suspendDetectionMode == .preciseWindowCoverage, let app else {
            return ForegroundCoverageSnapshot(
                app: app,
                targetDisplayIDs: targetIDs,
                axProbe: .unavailable,
                cgProbe: .unavailable
            )
        }

        return ForegroundCoverageSnapshot(
            app: app,
            targetDisplayIDs: targetIDs,
            axProbe: axCoverageProbe(for: app),
            cgProbe: cgCoverageProbe(for: app)
        )
    }

    private func frontmostAppStateForCoverageEvaluation() -> ForegroundCoverageAppState? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        if let bundleID = frontmostApp.bundleIdentifier,
            suspendExclusionBundleIDs.contains(normalizeBundleID(bundleID))
        {
            return nil
        }

        let frontmostPID = frontmostApp.processIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard frontmostPID != ownPID else {
            return nil
        }

        let bundleID = frontmostApp.bundleIdentifier
        return ForegroundCoverageAppState(
            pid: frontmostPID,
            bundleID: bundleID,
            isFinder: bundleID == "com.apple.finder"
        )
    }

    private func applyCoveringAppSuspension(_ shouldSuspend: Bool) {
        if shouldSuspend {
            applyCoveringAppSuspension(Set(targetScreens().map { displayIDString(for: $0) }))
        } else {
            applyCoveringAppSuspension([])
        }
    }

    private func applyCoveringAppSuspension(_ displayIDs: Set<String>) {
        let targetIDs: Set<String>
        targetIDs = displayIDs
        guard suspendedDisplayIDs != targetIDs else {
            return
        }
        suspendedDisplayIDs = targetIDs
        applySuspensionStateToPlayers()
    }

    private func targetCoverageDisplays() -> [ForegroundCoverageDisplay] {
        targetScreens().map { screen in
            let displayID =
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value ?? 0
            var frames = [screen.frame]
            let quartzFrame = CGDisplayBounds(displayID)
            if !quartzFrame.isNull, !quartzFrame.isEmpty, quartzFrame != screen.frame {
                frames.append(quartzFrame)
            }
            return ForegroundCoverageDisplay(
                id: displayIDString(for: screen),
                frames: frames
            )
        }
    }

    private func cgCoverageProbe(for app: ForegroundCoverageAppState) -> ForegroundCoverageProbe {
        guard
            let windowInfo = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return .uncertain
        }

        let displays = targetCoverageDisplays()
        guard !displays.isEmpty else {
            return .clear
        }

        var windows: [ForegroundCoverageWindow] = []
        var sawRestrictedFrontmostWindow = false

        for info in windowInfo {
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            guard ownerPID == app.pid else {
                continue
            }

            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else {
                sawRestrictedFrontmostWindow = true
                continue
            }

            windows.append(
                ForegroundCoverageWindow(
                    bounds: bounds,
                    alpha: alpha,
                    layer: layer
                )
            )
        }

        guard !sawRestrictedFrontmostWindow else {
            return .uncertain
        }
        guard !windows.isEmpty else {
            return app.isFinder ? .clear : .uncertain
        }

        let covered = ForegroundCoverageGeometry.coveredDisplayIDs(
            by: windows,
            displays: displays,
            coverageThreshold: 0.9
        )
        return covered.isEmpty ? .clear : .covered(covered)
    }

    private func axCoverageProbe(for app: ForegroundCoverageAppState) -> ForegroundCoverageProbe {
        guard isAccessibilityTrusted() else {
            return .uncertain
        }

        guard let windowElement = frontmostAXWindowElement(for: app.pid) else {
            return app.isFinder ? .clear : .uncertain
        }

        guard let bounds = boundsForAXWindow(windowElement) else {
            return .uncertain
        }

        let isMiniaturized =
            boolAXAttribute(
                kAXMinimizedAttribute as CFString,
                in: windowElement
            ) ?? false
        let isFullScreen =
            boolAXAttribute(
                "AXFullScreen" as CFString,
                in: windowElement
            ) ?? false
        let threshold: CGFloat = isFullScreen ? 0.95 : 0.9

        let displays = targetCoverageDisplays()
        guard !displays.isEmpty else {
            return .clear
        }

        let covered = ForegroundCoverageGeometry.coveredDisplayIDs(
            by: [
                ForegroundCoverageWindow(
                    bounds: bounds,
                    isMiniaturized: isMiniaturized
                )
            ],
            displays: displays,
            coverageThreshold: threshold
        )
        if isFullScreen, covered.isEmpty {
            return .uncertain
        }
        return covered.isEmpty ? .clear : .covered(covered)
    }

    private func frontmostAXWindowElement(for pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )
        if focusedResult == .success, let focusedWindow {
            return unsafeBitCast(focusedWindow, to: AXUIElement.self)
        }

        var mainWindow: CFTypeRef?
        let mainResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXMainWindowAttribute as CFString,
            &mainWindow
        )
        if mainResult == .success, let mainWindow {
            return unsafeBitCast(mainWindow, to: AXUIElement.self)
        }

        return nil
    }

    private func boolAXAttribute(_ attribute: CFString, in element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }

    private func boundsForAXWindow(_ windowElement: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        let positionResult = AXUIElementCopyAttributeValue(
            windowElement,
            kAXPositionAttribute as CFString,
            &positionValue
        )

        var sizeValue: CFTypeRef?
        let sizeResult = AXUIElementCopyAttributeValue(
            windowElement,
            kAXSizeAttribute as CFString,
            &sizeValue
        )

        guard positionResult == .success,
            sizeResult == .success,
            let positionValue,
            let sizeValue,
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let axPosition = unsafeBitCast(positionValue, to: AXValue.self)
        let axSize = unsafeBitCast(sizeValue, to: AXValue.self)

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(axPosition) == .cgPoint,
            AXValueGetType(axSize) == .cgSize,
            AXValueGetValue(axPosition, .cgPoint, &point),
            AXValueGetValue(axSize, .cgSize, &size)
        else {
            return nil
        }

        return CGRect(origin: point, size: size)
    }

    func normalizeBundleID(_ bundleID: String) -> String {
        bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

import AppKit
import ApplicationServices
import Foundation

@MainActor
extension WallpaperModel {
    @discardableResult
    func setSuspendWhenOtherAppFullScreen(_ enabled: Bool) -> Bool {
        guard suspendWhenOtherAppFullScreen != enabled else {
            if enabled {
                suspendWhenOtherAppStatusMessage = nil
                evaluateForegroundCoverageState()
            } else {
                suspendWhenOtherAppStatusMessage = nil
                applyCoveringAppSuspension(false)
            }
            return true
        }

        suspendWhenOtherAppStatusMessage = nil
        suspendWhenOtherAppFullScreen = enabled
        UserDefaults.standard.set(enabled, forKey: "suspendWhenOtherAppFullScreen")
        configureForegroundCoverageMonitoring()
        evaluateForegroundCoverageState()
        return true
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
            coverageEvaluationWorkItem?.cancel()
            coverageEvaluationWorkItem = nil
            removeAXObserver()
            applyCoveringAppSuspension(false)
            return
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        frontmostAppObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateAXObserverForFrontmostApplication()
                self?.scheduleForegroundCoverageEvaluation()
            }
        }

        activeSpaceObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleForegroundCoverageEvaluation()
            }
        }

        updateAXObserverForFrontmostApplication()
    }

    private func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    private func ensureAXCoverageObserver() -> ForegroundCoverageAXObserver {
        if let axCoverageObserver {
            return axCoverageObserver
        }
        let observer = ForegroundCoverageAXObserver()
        axCoverageObserver = observer
        return observer
    }

    private func updateAccessibilityCoverageStatusMessage(isTrusted: Bool) {
        if isTrusted {
            suspendWhenOtherAppStatusMessage = nil
            return
        }
        suspendWhenOtherAppStatusMessage = localizedString(
            "アクセシビリティ権限が必要です。システム設定でLiveWallpaperを許可してください。"
        )
    }

    private func updateAXObserverForFrontmostApplication() {
        guard suspendWhenOtherAppFullScreen else {
            removeAXObserver()
            return
        }

        let trusted = isAccessibilityTrusted()
        updateAccessibilityCoverageStatusMessage(isTrusted: trusted)
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
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            guard generation == coverageEvaluationGeneration else {
                return
            }
            lastCoverageEvaluationAt = CFAbsoluteTimeGetCurrent()
            evaluateForegroundCoverageState()
            coverageEvaluationWorkItem = nil
        }
        coverageEvaluationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
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

        let frontmostAppDisplayIDs = displayIDsForFrontmostAppPresence()
        if !frontmostAppDisplayIDs.isEmpty {
            applyCoveringAppSuspension(frontmostAppDisplayIDs)
            return
        }

        updateAXObserverForFrontmostApplication()
        let fullScreenDisplayIDs = fullScreenDisplayIDsByFrontmostApp()
        let coveredDisplayIDs =
            fullScreenDisplayIDs.isEmpty ? coveredDisplayIDsByFrontmostApp() : fullScreenDisplayIDs
        applyCoveringAppSuspension(coveredDisplayIDs)
    }

    private func frontmostAppForCoverageEvaluation() -> NSRunningApplication? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        if let bundleID = frontmostApp.bundleIdentifier,
           suspendExclusionBundleIDs.contains(normalizeBundleID(bundleID))
        {
            return nil
        }

        if frontmostApp.bundleIdentifier == "com.apple.finder" {
            return nil
        }

        let frontmostPID = frontmostApp.processIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard frontmostPID != ownPID else {
            return nil
        }

        return frontmostApp
    }

    private func displayIDsForFrontmostAppPresence() -> Set<String> {
        guard frontmostAppForCoverageEvaluation() != nil else {
            return []
        }

        return Set(targetScreens().map { displayIDString(for: $0) })
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

    private func coveredDisplayIDsByFrontmostApp() -> Set<String> {
        guard let frontmostApp = frontmostAppForCoverageEvaluation() else {
            return []
        }

        guard
            let windowInfo = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return []
        }

        let frontmostPID = frontmostApp.processIdentifier

        let screenInfos = targetScreens().map { screen in
            (
                id: displayIDString(for: screen),
                frame: screen.frame,
                area: max(screen.frame.width * screen.frame.height, 1)
            )
        }
        guard !screenInfos.isEmpty else {
            return []
        }

        var covered: Set<String> = []

        for info in windowInfo {
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            guard ownerPID == frontmostPID else {
                continue
            }

            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            if alpha <= 0.01 {
                continue
            }

            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            if layer < 0 {
                continue
            }

            guard
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else {
                continue
            }

            guard bounds.width >= 120, bounds.height >= 120 else {
                continue
            }

            for screen in screenInfos {
                let intersection = bounds.intersection(screen.frame)
                guard !intersection.isNull, !intersection.isEmpty else {
                    continue
                }
                let intersectionArea = intersection.width * intersection.height
                let coveredRatio = intersectionArea / screen.area
                if coveredRatio >= 0.9 {
                    covered.insert(screen.id)
                }
            }
        }

        return covered
    }

    private func fullScreenDisplayIDsByFrontmostApp() -> Set<String> {
        guard let frontmostApp = frontmostAppForCoverageEvaluation() else {
            return []
        }

        let frontmostPID = frontmostApp.processIdentifier

        let appElement = AXUIElementCreateApplication(frontmostPID)
        var focusedWindow: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )
        if focusedResult != .success {
            var mainWindow: CFTypeRef?
            let mainResult = AXUIElementCopyAttributeValue(
                appElement,
                kAXMainWindowAttribute as CFString,
                &mainWindow
            )
            if mainResult == .success {
                focusedWindow = mainWindow
            }
        }

        guard let windowRef = focusedWindow else {
            return []
        }
        let windowElement = unsafeBitCast(windowRef, to: AXUIElement.self)

        var fullScreenValue: CFTypeRef?
        let fullScreenAttribute: CFString = "AXFullScreen" as CFString
        let fullScreenResult = AXUIElementCopyAttributeValue(
            windowElement,
            fullScreenAttribute,
            &fullScreenValue
        )
        guard fullScreenResult == .success,
              let number = fullScreenValue as? NSNumber,
              number.boolValue
        else {
            return []
        }

        guard let bounds = boundsForAXWindow(windowElement) else {
            return coveredDisplayIDsByFrontmostApp()
        }

        let screenInfos = targetScreens().map { screen in
            (
                id: displayIDString(for: screen),
                frame: screen.frame,
                area: max(screen.frame.width * screen.frame.height, 1)
            )
        }
        guard !screenInfos.isEmpty else {
            return []
        }

        var covered: Set<String> = []
        for screen in screenInfos {
            let intersection = bounds.intersection(screen.frame)
            guard !intersection.isNull, !intersection.isEmpty else {
                continue
            }
            let coveredRatio = (intersection.width * intersection.height) / screen.area
            if coveredRatio >= 0.95 {
                covered.insert(screen.id)
            }
        }

        if !covered.isEmpty {
            return covered
        }

        return coveredDisplayIDsByFrontmostApp()
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

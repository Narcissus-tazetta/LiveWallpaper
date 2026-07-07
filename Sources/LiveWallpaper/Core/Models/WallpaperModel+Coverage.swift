import AppKit
import Foundation

@MainActor
extension WallpaperModel {
    @discardableResult
    func setSuspendWhenOtherAppFullScreen(_ enabled: Bool) -> Bool {
        guard suspendWhenOtherAppFullScreen != enabled else {
            evaluateForegroundCoverageState()
            return true
        }

        UserDefaults.standard.set(enabled, forKey: "suspendWhenOtherAppFullScreen")
        suspendWhenOtherAppFullScreen = enabled
        configureForegroundCoverageMonitoring()
        return true
    }

    @discardableResult
    func setSuspendHighSensitivityEnabled(_ enabled: Bool) -> Bool {
        guard suspendHighSensitivityEnabled != enabled else {
            evaluateForegroundCoverageState()
            return true
        }

        UserDefaults.standard.set(enabled, forKey: "suspendHighSensitivityEnabled")
        suspendHighSensitivityEnabled = enabled
        if enabled {
            refreshScreenRecordingTrustForCoverage()
        }
        evaluateForegroundCoverageState()
        return true
    }

    @discardableResult
    func setSuspendWhenOtherAppFrontmost(_ enabled: Bool) -> Bool {
        guard suspendWhenOtherAppFrontmost != enabled else {
            evaluateForegroundCoverageState()
            return true
        }

        UserDefaults.standard.set(enabled, forKey: "suspendWhenOtherAppFrontmost")
        suspendWhenOtherAppFrontmost = enabled
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

    // Coverage detection is built entirely on our own wallpaper windows'
    // NSWindow.occlusionState instead of inspecting other apps' windows via
    // CGWindowList/Accessibility. This needs no special permission, updates
    // immediately for every cause (app switch, resize-in-place, Space change,
    // Stage Manager, minimize) because the window server itself computes it for
    // us, and is exactly the right question to ask: "can the user currently see
    // this wallpaper window at all?"
    func configureForegroundCoverageMonitoring() {
        if let observer = frontmostAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            frontmostAppObserver = nil
        }
        if let observer = windowOcclusionObserver {
            NotificationCenter.default.removeObserver(observer)
            windowOcclusionObserver = nil
        }
        coverageEvaluationWorkItem?.cancel()
        coverageEvaluationWorkItem = nil

        guard suspendWhenOtherAppFullScreen else {
            applyCoveringAppSuspension([])
            return
        }

        frontmostAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleForegroundCoverageEvaluation()
            }
        }

        windowOcclusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let window = notification.object as? NSWindow,
                    self.displayIDByWindow[ObjectIdentifier(window)] != nil
                else {
                    return
                }
                self.scheduleForegroundCoverageEvaluation()
            }
        }

        evaluateForegroundCoverageState()
    }

    func scheduleForegroundCoverageEvaluation() {
        coverageEvaluationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.evaluateForegroundCoverageState()
        }
        coverageEvaluationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    func evaluateForegroundCoverageState() {
        guard suspendWhenOtherAppFullScreen, hasActiveWallpaperPlayback else {
            pendingSuspendConfirmationWorkItem?.cancel()
            pendingSuspendConfirmationWorkItem = nil
            applyCoveringAppSuspension([])
            return
        }
        guard let app = frontmostAppEligibleForSuspension() else {
            pendingSuspendConfirmationWorkItem?.cancel()
            pendingSuspendConfirmationWorkItem = nil
            applyCoveringAppSuspension([])
            return
        }

        let desired = Self.suspendedDisplayIDs(
            hasEligibleFrontmostApp: true,
            occludedDisplayIDs: occludedWallpaperDisplayIDs(),
            highSensitivityCoveredDisplayIDs: highSensitivityCoveredDisplayIDs(for: app),
            frontmostOnlyDisplayIDs: suspendWhenOtherAppFrontmost ? allWallpaperDisplayIDs() : []
        )

        pendingSuspendConfirmationWorkItem?.cancel()
        pendingSuspendConfirmationWorkItem = nil

        guard Self.addsNewSuspension(current: suspendedDisplayIDs, desired: desired) else {
            // Never delay resuming: uncovering the wallpaper (or a no-op) is
            // always safe to apply immediately.
            applyCoveringAppSuspension(desired)
            return
        }

        // Real activeSpaceDidChangeNotification events (origin unclear — the
        // window server, not our own code, is the source) make our own
        // wallpaper windows briefly (roughly a second) report occlusionState
        // as non-visible even though nothing is actually covering them.
        // A short confirmation delay still catches same-tick duplicate
        // notifications without adding a perceptible lag to real coverage;
        // any occlusion change before it fires cancels this timer and starts
        // over. It does not filter out multi-hundred-ms phantom blips.
        let workItem = DispatchWorkItem { [weak self] in
            self?.confirmPendingCoverageSuspension()
        }
        pendingSuspendConfirmationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    private func confirmPendingCoverageSuspension() {
        pendingSuspendConfirmationWorkItem = nil
        guard suspendWhenOtherAppFullScreen, hasActiveWallpaperPlayback else {
            return
        }
        guard let app = frontmostAppEligibleForSuspension() else {
            return
        }
        applyCoveringAppSuspension(
            Self.suspendedDisplayIDs(
                hasEligibleFrontmostApp: true,
                occludedDisplayIDs: occludedWallpaperDisplayIDs(),
                highSensitivityCoveredDisplayIDs: highSensitivityCoveredDisplayIDs(for: app),
                frontmostOnlyDisplayIDs: suspendWhenOtherAppFrontmost ? allWallpaperDisplayIDs() : []
            )
        )
    }

    /// No app to blame for the coverage (nothing frontmost, it's us, or it's on
    /// the exclusion list) means we don't suspend, regardless of occlusion.
    /// Otherwise: occlusion (always on, no permission needed), high sensitivity's
    /// actual window-coverage percentage when enabled and granted, and — when
    /// "suspend while another app is frontmost" is enabled — every wallpaper
    /// display outright, whether or not that app actually covers it. All three
    /// signals only ever add suspensions, never fight each other.
    static func suspendedDisplayIDs(
        hasEligibleFrontmostApp: Bool,
        occludedDisplayIDs: Set<String>,
        highSensitivityCoveredDisplayIDs: Set<String> = [],
        frontmostOnlyDisplayIDs: Set<String> = []
    ) -> Set<String> {
        guard hasEligibleFrontmostApp else {
            return []
        }
        return occludedDisplayIDs
            .union(highSensitivityCoveredDisplayIDs)
            .union(frontmostOnlyDisplayIDs)
    }

    /// True only when `desired` would newly suspend at least one display that
    /// isn't already suspended — i.e. this transition moves toward covering
    /// the wallpaper, not away from it. Used to apply "uncovered" decisions
    /// immediately while requiring "covered" decisions to stay true for a
    /// confirmation delay before taking effect.
    static func addsNewSuspension(current: Set<String>, desired: Set<String>) -> Bool {
        !desired.isSubset(of: current)
    }

    private var hasActiveWallpaperPlayback: Bool {
        isWebWallpaperActive || currentVideoPath != nil
    }

    /// The current frontmost app, unless it's this app itself, Finder, or on the
    /// exclusion list. Finder becomes frontmost merely by clicking empty desktop
    /// space (no window ever appears), so treating it like any other app made the
    /// wallpaper pause on ordinary desktop clicks; it's excluded unconditionally
    /// rather than via the user-editable list.
    private func frontmostAppEligibleForSuspension() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        if app.bundleIdentifier == "com.apple.finder" {
            return nil
        }
        if let bundleID = app.bundleIdentifier,
            suspendExclusionBundleIDs.contains(normalizeBundleID(bundleID))
        {
            return nil
        }
        return app
    }

    private func occludedWallpaperDisplayIDs() -> Set<String> {
        var occluded: Set<String> = []
        for window in windows {
            guard let displayID = displayIDByWindow[ObjectIdentifier(window)] else {
                continue
            }
            if !window.occlusionState.contains(.visible) {
                occluded.insert(displayID)
            }
        }
        return occluded
    }

    private func allWallpaperDisplayIDs() -> Set<String> {
        Set(displayIDByWindow.values)
    }

    private func applyCoveringAppSuspension(_ displayIDs: Set<String>) {
        guard suspendedDisplayIDs != displayIDs else {
            return
        }
        NSLog(
            "[Suspend] transition from=%@ to=%@ at=%.3f",
            String(describing: suspendedDisplayIDs),
            String(describing: displayIDs),
            CFAbsoluteTimeGetCurrent()
        )
        suspendedDisplayIDs = displayIDs
        applySuspensionStateToPlayers()
    }

    func normalizeBundleID(_ bundleID: String) -> String {
        bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func isScreenRecordingTrusted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func refreshScreenRecordingTrustForCoverage() -> Bool {
        let trusted = isScreenRecordingTrusted()
        guard screenRecordingTrustedForCoverage != trusted else {
            return trusted
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            guard self.screenRecordingTrustedForCoverage != trusted else {
                return
            }
            self.screenRecordingTrustedForCoverage = trusted
        }
        return trusted
    }

    func requestScreenRecordingPermissionForCoverage() {
        _ = CGRequestScreenCaptureAccess()

        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) {
            NSWorkspace.shared.open(url)
        }

        for delay in [0.2, 0.8, 1.6, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else {
                    return
                }
                _ = self.refreshScreenRecordingTrustForCoverage()
                self.scheduleForegroundCoverageEvaluation()
            }
        }
    }

    /// Optional, opt-in second signal on top of occlusion: how much of the
    /// screen the eligible frontmost app's own windows actually cover, using
    /// the same coverage-percentage geometry the old detector used. Requires
    /// Screen Recording permission to read other apps' window bounds; without
    /// it (or when the feature is off) this simply contributes nothing, so
    /// occlusion-based detection alone still works exactly as before.
    private func highSensitivityCoveredDisplayIDs(for app: NSRunningApplication) -> Set<String> {
        guard suspendHighSensitivityEnabled, refreshScreenRecordingTrustForCoverage() else {
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

        let displays = targetCoverageDisplays()
        guard !displays.isEmpty else {
            return []
        }

        let pid = app.processIdentifier
        var coverageWindows: [ForegroundCoverageWindow] = []
        for info in windowInfo {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else {
                continue
            }
            guard
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else {
                continue
            }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            coverageWindows.append(
                ForegroundCoverageWindow(bounds: bounds, alpha: alpha, layer: layer)
            )
        }
        guard !coverageWindows.isEmpty else {
            return []
        }

        return ForegroundCoverageGeometry.coveredDisplayIDs(
            by: coverageWindows,
            displays: displays,
            coverageThreshold: 0.9
        )
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
            // A window "maximized" (not natively fullscreen) only ever fills
            // visibleFrame — the area excluding the menu bar and Dock — never
            // the full physical screen.frame. Comparing coverage against only
            // the full frame means a persistent Dock alone can push a truly
            // maximized window's coverage ratio under the threshold, even
            // though nothing but opaque menu bar/Dock chrome is left showing.
            // Offering visibleFrame as an additional candidate lets such a
            // window still count as "covering" the display.
            if screen.visibleFrame != screen.frame {
                frames.append(screen.visibleFrame)
            }
            return ForegroundCoverageDisplay(
                id: displayIDString(for: screen),
                frames: frames
            )
        }
    }
}

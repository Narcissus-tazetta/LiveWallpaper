import AppKit

/// Why an enabled cursor effect is not running, shown under its setting.
enum CursorEffectBlockReason: Equatable {
    case webWallpaper
    case reduceMotion
    case battery
    case lowPowerMode
    case thermal
}

/// Parallax, spotlight and trail driven by the cursor (CursorTracker).
///
/// Parallax and trail are motion: they stop for Reduce Motion, while the battery
/// policy lowers or freezes playback, and while the wallpaper is paused. The
/// spotlight only follows the cursor, so it keeps working on a paused wallpaper.
/// All of them stop on screens covered by windows, in Low Power Mode, when the Mac
/// is hot, and (by default) while another app is frontmost; the tracker stops when
/// no screen needs it, since waking for mouse events is most of the cost.
@MainActor
extension WallpaperModel {
    func setCursorEffects(_ settings: CursorEffectsSettings) {
        guard cursorEffects != settings else {
            return
        }
        cursorEffects = settings
        do {
            try UserDefaults.standard.set(JSONEncoder().encode(settings), forKey: PrefsKey.cursorEffectsData)
        } catch {
            recordPersistenceFailure(key: PrefsKey.cursorEffectsData, error: error)
        }
        refreshCursorEffects()
    }

    func restoreCursorEffects() {
        cursorEffects = UserDefaults.standard.decodedJSON(
            CursorEffectsSettings.self, forKey: PrefsKey.cursorEffectsData
        ) ?? CursorEffectsSettings()
    }

    /// For parallax and trail. The spotlight is only blocked by web wallpapers.
    var cursorMotionBlockReason: CursorEffectBlockReason? {
        if isWebWallpaperActive {
            return .webWallpaper
        }
        if reduceMotionFreezeActive {
            return .reduceMotion
        }
        return cursorPowerBlockReason ?? ((batteryReduceLoadActive || batteryFreezeActive) ? .battery : nil)
    }

    var cursorSpotlightBlockReason: CursorEffectBlockReason? {
        isWebWallpaperActive ? .webWallpaper : cursorPowerBlockReason
    }

    private var cursorPowerBlockReason: CursorEffectBlockReason? {
        if isLowPowerModeOn {
            return .lowPowerMode
        }
        if isThermallyConstrained {
            return .thermal
        }
        return nil
    }

    private var cursorEffectsPausedForOtherApp: Bool {
        cursorEffects.onlyWhileDesktopActive && !isDesktopAppFrontmost
    }

    private var cursorMotionActive: Bool {
        cursorMotionBlockReason == nil && !manualPauseActive && !cursorEffectsPausedForOtherApp
    }

    private var parallaxActive: Bool {
        cursorEffects.parallaxEnabled && cursorMotionActive
    }

    private var trailActive: Bool {
        cursorEffects.trailEnabled && cursorMotionActive
    }

    /// Not tied to the frontmost app: the click that brings the desktop forward
    /// happens while another app is still frontmost, and clicks are rare enough
    /// that watching them costs nothing.
    private var clickActive: Bool {
        cursorEffects.clickEnabled && cursorMotionBlockReason == nil && !manualPauseActive
    }

    private var spotlightActive: Bool {
        cursorEffects.spotlightEnabled && cursorSpotlightBlockReason == nil && !cursorEffectsPausedForOtherApp
    }

    /// Frontmost app, Low Power Mode and thermal state, watched only while some
    /// effect is enabled.
    private func updateCursorEffectsObservers() {
        guard cursorEffects.anyEnabled else {
            for observer in cursorEffectsObservers {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
                NotificationCenter.default.removeObserver(observer)
            }
            cursorEffectsObservers = []
            return
        }
        readCursorEffectsEnvironment()
        guard cursorEffectsObservers.isEmpty else {
            return
        }
        let handler: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                self.readCursorEffectsEnvironment()
                self.refreshCursorEffects()
            }
        }
        cursorEffectsObservers = [
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: handler
            ),
            NotificationCenter.default.addObserver(
                forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main, using: handler
            ),
            NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main, using: handler
            ),
        ]
    }

    private func readCursorEffectsEnvironment() {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let desktop = frontmost == "com.apple.finder" || frontmost == Bundle.main.bundleIdentifier
        if isDesktopAppFrontmost != desktop {
            isDesktopAppFrontmost = desktop
        }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        if isLowPowerModeOn != lowPower {
            isLowPowerModeOn = lowPower
        }
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        if isThermallyConstrained != hot {
            isThermallyConstrained = hot
        }
    }

    /// Re-applies the settings to every screen and starts or stops the tracker.
    /// Cheap enough to call on every coverage, power or window change.
    func refreshCursorEffects() {
        updateCursorEffectsObservers()
        updateClickMonitor()
        let settings = cursorEffects
        let visible = allWallpaperDisplayIDs().subtracting(coveredDisplayIDs)
        let needsTracking = (parallaxActive || trailActive || spotlightActive) && !visible.isEmpty

        for view in playerViews {
            view.configureTrail(settings.trailAppearance)
            if !parallaxActive {
                view.setParallax(offset: .zero, scale: 1)
            }
            if !spotlightActive {
                view.setSpotlight(radius: nil, opacity: 0, center: nil)
            }
            if !trailActive {
                view.setTrail(position: nil, emitting: false)
            }
        }

        if needsTracking {
            if cursorTracker == nil {
                cursorTracker = CursorTracker { [weak self] location in
                    self?.handleCursorMoved(to: location, moved: true)
                }
            }
            if cursorTracker?.isRunning == false {
                AppLog.windowRefresh.info("cursor tracking started")
                cursorTracker?.start()
            }
            handleCursorMoved(to: NSEvent.mouseLocation, moved: false)
        } else if cursorTracker?.isRunning == true {
            AppLog.windowRefresh.info("cursor tracking stopped")
            cursorTracker?.stop()
            trailIdleWorkItem?.cancel()
            trailIdleWorkItem = nil
        }
    }

    private func handleCursorMoved(to location: CGPoint, moved: Bool) {
        let settings = cursorEffects
        let parallax = parallaxActive
        let spotlight = spotlightActive
        let trail = trailActive && moved
        for view in playerViews {
            guard let window = view.window,
                  let displayID = displayIDByWindow[ObjectIdentifier(window)]
            else {
                continue
            }
            let frame = window.frame
            let covered = coveredDisplayIDs.contains(displayID)
            let local: CGPoint? = frame.contains(location) && !covered
                ? CGPoint(x: location.x - frame.minX, y: location.y - frame.minY)
                : nil

            if parallax {
                // Screens without the cursor ease back to centre but stay scaled up,
                // so the picture does not visibly zoom when the cursor arrives.
                let offset = local.map {
                    CursorEffectGeometry.parallaxOffset(
                        cursor: $0, screenSize: frame.size, amplitude: settings.parallaxAmplitude
                    )
                } ?? .zero
                view.setParallax(
                    offset: offset,
                    scale: CursorEffectGeometry.parallaxScale(amplitude: settings.parallaxAmplitude)
                )
            }
            if spotlight {
                view.setSpotlight(
                    radius: settings.spotlightRadius, opacity: settings.spotlightOpacity, center: local
                )
            }
            if trailActive {
                view.setTrail(position: local, emitting: trail)
            }
        }
        guard trail else {
            return
        }
        trailIdleWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                for view in self?.playerViews ?? [] {
                    view.setTrail(position: nil, emitting: false)
                }
            }
        }
        trailIdleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    // MARK: - Click

    private func updateClickMonitor() {
        if clickActive, clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleClick(at: NSEvent.mouseLocation)
                }
            }
        } else if !clickActive, let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    private func handleClick(at location: CGPoint) {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else {
            return
        }
        let topLeftPoint = CGPoint(x: location.x, y: primaryHeight - location.y)
        let isDesktop = DesktopClickDetector.isDesktopClick(
            at: topLeftPoint,
            windows: Self.onScreenWindows(),
            finderPID: NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
                .first?.processIdentifier,
            dockPID: NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
                .first?.processIdentifier,
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
        guard isDesktop else {
            return
        }
        let settings = cursorEffects
        for view in playerViews {
            guard let frame = view.window?.frame, frame.contains(location) else {
                continue
            }
            view.showClick(
                at: CGPoint(x: location.x - frame.minX, y: location.y - frame.minY),
                style: settings.clickStyle, color: settings.clickColor, customColor: settings.clickCustomColor
            )
        }
    }

    private static func onScreenWindows() -> [OnScreenWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else {
                return nil
            }
            return OnScreenWindow(
                ownerPID: pid,
                isWindowServer: info[kCGWindowOwnerName as String] as? String == "Window Server",
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                bounds: bounds,
                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            )
        }
    }
}

import AppKit

/// Why an enabled cursor effect is not running, shown under its setting.
enum CursorEffectBlockReason: Equatable {
    case webWallpaper
    case reduceMotion
    case battery
}

/// Parallax, spotlight and trail driven by the cursor (CursorTracker).
///
/// Parallax and trail are motion: they stop for Reduce Motion, while the battery
/// policy lowers or freezes playback, and while the wallpaper is paused. The
/// spotlight only follows the cursor, so it keeps working on a paused wallpaper.
/// All of them stop on screens covered by windows, and the tracker stops when no
/// screen needs it.
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
        if batteryReduceLoadActive || batteryFreezeActive {
            return .battery
        }
        return nil
    }

    var cursorSpotlightBlockReason: CursorEffectBlockReason? {
        isWebWallpaperActive ? .webWallpaper : nil
    }

    private var cursorMotionActive: Bool {
        cursorMotionBlockReason == nil && !manualPauseActive
    }

    private var parallaxActive: Bool {
        cursorEffects.parallaxEnabled && cursorMotionActive
    }

    private var trailActive: Bool {
        cursorEffects.trailEnabled && cursorMotionActive
    }

    private var spotlightActive: Bool {
        cursorEffects.spotlightEnabled && cursorSpotlightBlockReason == nil
    }

    /// Re-applies the settings to every screen and starts or stops the tracker.
    /// Cheap enough to call on every coverage, power or window change.
    func refreshCursorEffects() {
        let settings = cursorEffects
        let visible = allWallpaperDisplayIDs().subtracting(coveredDisplayIDs)
        let needsTracking = (parallaxActive || trailActive || spotlightActive) && !visible.isEmpty

        for view in playerViews {
            view.configureTrail(
                color: settings.trailColor,
                customColor: settings.trailCustomColor.nsColor,
                birthRate: settings.trailBirthRate
            )
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
}

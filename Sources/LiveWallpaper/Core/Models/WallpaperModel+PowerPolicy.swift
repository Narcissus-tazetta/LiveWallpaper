import Foundation
import IOKit.ps

/// What the wallpaper does while running on battery.
enum BatteryPlaybackPolicy: String, CaseIterable {
    case normal
    /// Lightweight mode (the downscaled proxy) while on battery. preferredPeakBitRate
    /// has almost no effect on local files, so swapping to the proxy is the only
    /// thing that actually lowers decode load.
    case reduceLoad
    /// Freeze every screen (same path as the user pause).
    case freeze
}

@MainActor
extension WallpaperModel {
    var batteryReduceLoadActive: Bool {
        isOnBatteryPower && batteryPlaybackPolicy == .reduceLoad
    }

    var batteryFreezeActive: Bool {
        isOnBatteryPower && batteryPlaybackPolicy == .freeze
    }

    /// Whether playback is actually lightweight. `lightweightMode` is only the user
    /// setting (UI and persistence); every playback path reads this instead.
    var effectiveLightweightMode: Bool {
        lightweightMode || batteryReduceLoadActive
    }

    /// EDR raises the backlight, so the battery "reduce load" policy shows HDR video as
    /// SDR along with switching to the downscaled proxy.
    var effectiveHDRDisplay: Bool {
        hdrDisplayEnabled && !batteryReduceLoadActive
    }

    func setHDRDisplayEnabled(_ enabled: Bool) {
        guard hdrDisplayEnabled != enabled else {
            return
        }
        hdrDisplayEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: PrefsKey.hdrDisplayEnabled)
        applyDynamicRange()
    }

    func applyDynamicRange() {
        for view in playerViews {
            view.setHighDynamicRange(effectiveHDRDisplay)
        }
    }

    func setBatteryPlaybackPolicy(_ policy: BatteryPlaybackPolicy) {
        guard batteryPlaybackPolicy != policy else {
            return
        }
        applyPowerPlaybackChange {
            batteryPlaybackPolicy = policy
            UserDefaults.standard.set(policy.rawValue, forKey: PrefsKey.batteryPlaybackPolicy)
        }
    }

    func restoreBatteryPlaybackPolicy() {
        batteryPlaybackPolicy = UserDefaults.standard.string(forKey: PrefsKey.batteryPlaybackPolicy)
            .flatMap(BatteryPlaybackPolicy.init(rawValue:)) ?? .normal
    }

    /// Call once at launch. Uses IOKit notifications so unplugging takes effect
    /// immediately; the existing 60 s quality poll would keep playing for up to a minute.
    func configurePowerSourceMonitoring() {
        isOnBatteryPower = Self.isRunningOnBatteryPower()
        guard powerSourceRunLoopSource == nil else {
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else {
                return
            }
            let model = Unmanaged<WallpaperModel>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                model.handlePowerSourceChange()
            }
        }, context)?.takeRetainedValue() else {
            AppLog.suspend.error("power source notification unavailable; battery policy follows launch state only")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSourceRunLoopSource = source
    }

    private func handlePowerSourceChange() {
        let onBattery = Self.isRunningOnBatteryPower()
        guard onBattery != isOnBatteryPower else {
            return
        }
        AppLog.suspend.info(
            "power source onBattery=\(onBattery) policy=\(self.batteryPlaybackPolicy.rawValue, privacy: .public)"
        )
        applyPowerPlaybackChange {
            isOnBatteryPower = onBattery
        }
    }

    /// Applies a policy or power-source change the same way: toggle lightweight
    /// playback if needed, then re-evaluate freezing.
    private func applyPowerPlaybackChange(_ change: () -> Void) {
        let wasLightweight = effectiveLightweightMode
        change()
        if wasLightweight != effectiveLightweightMode {
            applyLightweightSettings()
            requestPlaybackReconfiguration()
        }
        applyDynamicRange()
        evaluateForegroundCoverageState()
    }

    private static func isRunningOnBatteryPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
        else {
            return false
        }
        return (type as String) == kIOPSBatteryPowerValue
    }
}

import Foundation
import IOKit.ps

/// バッテリー駆動中の再生方針。
enum BatteryPlaybackPolicy: String, CaseIterable {
    case normal
    /// 軽量モード(縮小プロキシでの再生)をバッテリー駆動中だけ有効にする。
    /// ローカル動画では preferredPeakBitRate がほぼ効かないため、デコード負荷を
    /// 実際に下げられるのはプロキシ差し替えだけ。
    case reduceLoad
    /// 全画面を静止フレームにする(手動の一時停止と同じ経路)。
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

    /// 実際に軽量再生するか。設定値(lightweightMode)そのものはUIの表示と永続化に使い、
    /// 再生経路はすべてこちらを見る。
    var effectiveLightweightMode: Bool {
        lightweightMode || batteryReduceLoadActive
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

    /// 起動時に一度呼ぶ。電源の切り替えは IOKit の通知で即座に受け取る
    /// (既存の画質自動調整の60秒ポーリングでは、抜いてから最大1分再生し続ける)。
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
        AppLog.suspend.debug(
            "power source onBattery=\(onBattery) policy=\(self.batteryPlaybackPolicy.rawValue, privacy: .public)"
        )
        applyPowerPlaybackChange {
            isOnBatteryPower = onBattery
        }
    }

    /// 方針・電源状態のどちらが変わっても、軽量再生の切り替えと静止の適用を
    /// 同じ手順で行う。
    private func applyPowerPlaybackChange(_ change: () -> Void) {
        let wasLightweight = effectiveLightweightMode
        change()
        if wasLightweight != effectiveLightweightMode {
            applyLightweightSettings()
            requestPlaybackReconfiguration()
        }
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

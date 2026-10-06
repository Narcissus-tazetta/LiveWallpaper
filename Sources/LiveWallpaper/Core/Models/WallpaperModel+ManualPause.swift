import Foundation

/// 利用者による一時停止(メニュー・ホットキー・URLスキーム)。
///
/// Reduce Motion と同じく、カバレッジ判定の結果へ全画面の静止を上乗せする方式で
/// 実現する。こうするとフリーズフレーム・deep suspend・Web壁紙・ディスプレイ別の
/// 専用プレイヤーがすべて既存の経路でそのまま止まる。再起動を跨いで保持しない
/// (起動したら再生に戻る)。
@MainActor
extension WallpaperModel {
    func setManualPauseActive(_ paused: Bool) {
        guard manualPauseActive != paused else {
            return
        }
        manualPauseActive = paused
        AppLog.suspend.debug("manual pause -> \(paused)")
        evaluateForegroundCoverageState()
    }

    func toggleManualPause() {
        setManualPauseActive(!manualPauseActive)
    }

    /// 自動停止の判定とは無関係に、常に全画面を静止させる要因(Reduce Motion・
    /// 手動の一時停止・バッテリー駆動中の静止方針)の和。
    /// 「自動停止しないディスプレイ」の除外より優先する。
    func forcedFreezeDisplayIDs() -> Set<String> {
        forcedFreezeActive ? allWallpaperDisplayIDs() : []
    }

    var forcedFreezeActive: Bool {
        reduceMotionFreezeActive || manualPauseActive || batteryFreezeActive
    }
}

import AppKit

/// システムの「視差効果を減らす(Reduce Motion)」アクセシビリティ設定への対応。
///
/// 有効時は、動画がカバーされたときと同じ「静止フレームへ固定」機構
/// (suspendedDisplayIDs / applySuspensionStateToPlayers)を全画面に対して
/// 流用して壁紙を止める。既存のフリーズ経路をそのまま使うため、Web壁紙・
/// ディスプレイ別の専用プレイヤーも含めて一様に静止する。
@MainActor
extension WallpaperModel {
    /// Reduce Motion によって壁紙を静止フレームに固定すべきか。
    /// ユーザー設定(尊重するか)とシステム状態(実際にONか)の論理積。
    var reduceMotionFreezeActive: Bool {
        respectReduceMotionEnabled && systemReduceMotionEnabled
    }

    /// Reduce Motion 静止の対象となる画面。有効なら全壁紙画面、無効なら空。
    /// カバレッジ判定の結果に union することで、他の停止シグナルと衝突せず
    /// 常に「全画面停止」を上乗せする。
    func reduceMotionFreezeDisplayIDs() -> Set<String> {
        reduceMotionFreezeActive ? allWallpaperDisplayIDs() : []
    }

    /// 起動時に一度呼ぶ。現在のシステム状態を取り込み、以後の変更を監視する。
    func configureReduceMotionMonitoring() {
        systemReduceMotionEnabled = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if let observer = reduceMotionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            reduceMotionObserver = nil
        }
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSystemReduceMotionChange()
            }
        }

        // 起動時点で既に有効なら即座に静止させる。
        if reduceMotionFreezeActive {
            evaluateForegroundCoverageState()
        }
    }

    /// システム側の Reduce Motion 切替を反映する。凍結・解除のどちらも
    /// 通常のカバレッジ再評価に載せる(applyCoveringAppSuspension が
    /// reduceMotionFreezeDisplayIDs を union / 解除時は外す)。
    private func handleSystemReduceMotionChange() {
        let newValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard newValue != systemReduceMotionEnabled else {
            return
        }
        systemReduceMotionEnabled = newValue
        evaluateForegroundCoverageState()
    }

    /// 「Reduce Motion に従う」トグルの反映。無効化した瞬間に再生を再開できる
    /// よう、こちらでもカバレッジを再評価する。
    func setRespectReduceMotionEnabled(_ enabled: Bool) {
        guard respectReduceMotionEnabled != enabled else {
            return
        }
        respectReduceMotionEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: PrefsKey.respectReduceMotionEnabled)
        evaluateForegroundCoverageState()
    }
}

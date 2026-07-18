import Foundation

/// 一定時間ごとに次の壁紙へ自動で切り替える機能。
/// 間隔は分単位で永続化され、0 はオフを表す。
@MainActor
extension WallpaperModel {
    func setAutoSwitchInterval(minutes: Int) {
        guard autoSwitchIntervalMinutes != minutes else {
            return
        }
        autoSwitchIntervalMinutes = minutes
        UserDefaults.standard.set(minutes, forKey: "autoSwitchIntervalMinutes")
        restartAutoSwitchTimer()
    }

    func restoreAutoSwitchInterval() {
        autoSwitchIntervalMinutes =
            UserDefaults.standard.object(forKey: "autoSwitchIntervalMinutes") as? Int ?? 0
        restartAutoSwitchTimer()
    }

    private func restartAutoSwitchTimer() {
        autoSwitchTimer?.invalidate()
        autoSwitchTimer = nil
        guard autoSwitchIntervalMinutes > 0 else {
            return
        }
        let interval = TimeInterval(autoSwitchIntervalMinutes * 60)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.autoSwitchTimerFired()
            }
        }
        // 分単位の機能なので正確さより省電力を優先し、まとめて発火できる余裕を持たせる。
        timer.tolerance = min(interval * 0.1, 30)
        RunLoop.main.add(timer, forMode: .common)
        autoSwitchTimer = timer
    }

    private func autoSwitchTimerFired() {
        guard autoSwitchIntervalMinutes > 0 else {
            return
        }
        guard registeredPlaybackEntries.count > 1 else {
            return
        }
        guard !pinCurrentVideo else {
            return
        }
        // 作業中の自動停止などで「共有プレイヤーの再生」が止まっている間は切り替えない。
        // 停止中に裏で壁紙が変わり、復帰時に不意に別の壁紙になるのを防ぐ。
        // ここで見るのは共有プレイヤーを使う画面だけ: ディスプレイ固定(オーバーライド)
        // した別画面が単独で被覆されているだけなら、共有側の再生には無関係なので
        // 無視してよい(全画面がsuspendedDisplayIDsのグローバル集合を見ると、無関係な
        // 画面の被覆だけで共有プレイリストの自動切替が止まってしまう)。
        guard !isDeepSuspended else {
            return
        }
        // スケジュール機能が共有スコープに今マッチしている間は、ローテーションが
        // その選択と競合しないよう抑制する(ルール自体を無効化はしない)。
        guard Self.matchingScheduleRule(
            in: scheduleRules, scope: .shared, now: scheduleNowProvider(),
            appearance: scheduleAppearanceProvider()
        ) == nil else {
            return
        }
        let sharedIDs = sharedPlayerDisplayIDs(among: allWallpaperDisplayIDs())
        guard !sharedIDs.isEmpty, !sharedIDs.allSatisfy({ suspendedDisplayIDs.contains($0) }) else {
            return
        }
        playNextVideo(advancingPlaylist: true)
    }
}

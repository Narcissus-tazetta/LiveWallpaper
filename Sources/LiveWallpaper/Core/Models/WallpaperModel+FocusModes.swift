import Foundation

/// 集中モード連携(DoNotDisturb DB読み取り方式)。
///
/// 検出(FocusModeMonitor)とモード別の壁紙割り当て(focusModeAssignments)をここで
/// 束ね、適用自体は既存のスケジュールエンジンの focusFilter 合成ルール
/// (applyFocusFilterState, WallpaperModel+Schedule.swift)へ委譲する。これにより
/// 曜日スケジュールとの優先順位・マスタースイッチ(focusFilterIntegrationEnabled)・
/// 手動選択との共存ルールを新たに発明せずに済む。
@MainActor
extension WallpaperModel {
    /// AppDelegate.applicationDidFinishLaunching から一度だけ呼ぶ。
    func startFocusModeMonitoring() {
        guard focusModeMonitor == nil else {
            return
        }
        let monitor = FocusModeMonitor()
        monitor.onChange = { [weak self] in
            self?.syncFocusModeState()
        }
        focusModeMonitor = monitor
        monitor.start()
        syncFocusModeState()
    }

    /// モニターの最新状態をpublishedへ反映し、有効モードの割り当て壁紙を適用する。
    func syncFocusModeState() {
        guard let monitor = focusModeMonitor else {
            return
        }
        focusModeAccessDenied = monitor.accessState == .denied
        // パーサはDB上の生の名前で並べるが、システム固定モードは表示時に訳すため
        // (focusModeDisplayName)、UIに出す並びは訳後の名前で決め直す。
        focusModes = monitor.modes.sorted { lhs, rhs in
            if lhs.id == FocusMode.doNotDisturbIdentifier { return true }
            if rhs.id == FocusMode.doNotDisturbIdentifier { return false }
            return focusModeDisplayName(lhs)
                .localizedCompare(focusModeDisplayName(rhs)) == .orderedAscending
        }
        activeFocusModeID = monitor.activeModeID
        let target = monitor.activeModeID.flatMap { focusModeAssignments[$0] }
        // applyFocusFilterState は毎回 handleScheduleRulesChanged(永続化フラッシュ含む)
        // を呼ぶため、解決結果が今の合成ルールと同じなら触らない。
        let current = focusFilterRule
        let currentTarget: ScheduleTarget? = (current?.isEnabled == true) ? current?.target : nil
        guard target != currentTarget else {
            return
        }
        applyFocusFilterState(target: target)
    }

    /// モードへの壁紙割り当て。target が nil なら「変更しない」に戻す。
    func setFocusModeAssignment(_ target: ScheduleTarget?, forModeID modeID: String) {
        if let target {
            focusModeAssignments[modeID] = target
        } else {
            focusModeAssignments.removeValue(forKey: modeID)
        }
        schedulePersistedStateFlush()
        // 割り当てを変えたモードが今まさに有効なら、その場で表示へ反映する。
        syncFocusModeState()
    }

    /// UI表示用のモード名。ユーザーが作成/有効化したモードは有効化時の言語の名前が
    /// DBに保存されるのに対し、名前変更できないシステム固定モード(おやすみモード・
    /// さまたげ低減)は常に英語の正式名(または空)で保存されるため、こちらで訳す。
    func focusModeDisplayName(_ mode: FocusMode) -> String {
        if mode.id == FocusMode.doNotDisturbIdentifier || mode.name == "Do Not Disturb" {
            return localizedString("おやすみモード")
        }
        if mode.name == "Reduce Interruptions" {
            return localizedString("さまたげ低減")
        }
        if mode.name.isEmpty {
            return localizedString("集中モード")
        }
        return mode.name
    }

    /// ライブラリから動画/Web壁紙が消えたときに、宙に浮いた割り当てを除去する。
    func pruneFocusModeAssignments(referencingVideoPath path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = focusModeAssignments.count
        focusModeAssignments = focusModeAssignments.filter { !(
            $0.value.kind == .video && $0.value.videoPath == trimmed
        ) }
        if focusModeAssignments.count != before {
            schedulePersistedStateFlush()
            syncFocusModeState()
        }
    }

    func pruneFocusModeAssignments(referencingWebWallpaperID id: UUID) {
        let before = focusModeAssignments.count
        focusModeAssignments = focusModeAssignments.filter { !(
            $0.value.kind == .web && $0.value.webWallpaperID == id
        ) }
        if focusModeAssignments.count != before {
            schedulePersistedStateFlush()
            syncFocusModeState()
        }
    }

    func restoreFocusModeAssignments() {
        guard let data = UserDefaults.standard.data(forKey: "focusModeAssignmentsData"),
              let decoded = try? JSONDecoder().decode([String: ScheduleTarget].self, from: data)
        else {
            return
        }
        focusModeAssignments = decoded
    }
}

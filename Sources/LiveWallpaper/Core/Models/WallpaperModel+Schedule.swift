import AppKit
import Foundation

/// スケジュール評価の再評価トリガー。全トリガーが同じ evaluateSchedule(trigger:) に
/// 集約され、トリガーごとの部分最適化はしない(ルール数は小さいため全件評価で十分軽い)。
enum ScheduleEvaluationTrigger {
    case timerTick
    case appearanceChanged
    case wake
    case unlock
    case ruleListChanged
    case launch
    case spaceChanged
    case displayConfigurationChanged
    /// pin解除など再生制約が変化した(共有スコープのガードが外れた)。
    case playbackConstraintChanged
    /// ディープサスペンドからの復帰。
    case deepSuspendResumed
}

enum ScheduleRuleMoveDirection {
    case up
    case down
}

/// ダークモード連動切替(簡易UI)+曜日スケジュール(統合ルールビルダー)の
/// 共有エンジン。両機能は同じ [ScheduleRule] を評価対象にし、origin で区別される
/// (詳細は ScheduleModels.swift のコメント参照)。
///
/// 設計の要点:
/// - Space > ディスプレイ別 > 共有、という既存の優先順位カスケード
///   (resolvedOverridePath, WallpaperModel+Spaces.swift)を再実装せず、各スコープに
///   対応する既存の書き込み口(selectRegisteredVideo/selectWebWallpaper/
///   setVideoOverride/setSpaceVideo)を呼ぶだけに留める。
/// - 手動選択との競合は「毎tickの再適用」ではなく「ルール境界を跨いだ瞬間だけ適用する」
///   状態遷移方式で解決する。ルールが有効な時間枠中にユーザーが手動で選び直しても、
///   次の境界(曜日変更・時刻境界・外観切替)までは上書きしない。
@MainActor
extension WallpaperModel {
    /// 簡易UIが作るシステム管理ルールの固定ID。ScheduleSection.swift 側もこのIDを
    /// 直接使ってルールを特定する(ヒューリスティックな絞り込みはしない)。
    static let simpleAppearanceLightRuleID =
        UUID(uuidString: "3B1D9C9E-0001-4A9E-8B1D-000000000001")!
    static let simpleAppearanceDarkRuleID =
        UUID(uuidString: "3B1D9C9E-0001-4A9E-8B1D-000000000002")!

    // MARK: - 純粋なマッチングロジック(テスト容易・UI/永続化から独立)

    /// 指定スコープについて、与えられた日時・外観条件に今マッチするルールを
    /// 配列順で先勝ち(first-match-wins)で返す。
    static func matchingScheduleRule(
        in rules: [ScheduleRule],
        scope: ScheduleScope,
        now: Date,
        appearance: ScheduleAppearanceCondition,
        calendar: Calendar = .current
    ) -> ScheduleRule? {
        let weekday = calendar.component(.weekday, from: now)
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let time = ScheduleTimeOfDay(hour: components.hour ?? 0, minute: components.minute ?? 0)
        return rules.first { rule in
            guard rule.isEnabled, rule.scope == scope else {
                return false
            }
            guard rule.weekdays.isEmpty || rule.weekdays.contains(weekday) else {
                return false
            }
            if let range = rule.timeRange, !range.contains(time) {
                return false
            }
            guard rule.appearance == .any || rule.appearance == appearance else {
                return false
            }
            return true
        }
    }

    // MARK: - 評価エンジン

    func evaluateSchedule(trigger _: ScheduleEvaluationTrigger) {
        // 適用処理(selectRegisteredVideo/setSpaceVideo 等)は refreshPlaybackState や
        // removeRegisteredVideo を通じて間接的に evaluateSchedule を呼び戻しうる。
        // 再入すると同一パスの二重適用や状態辞書の破損につながるため、多重評価を弾く。
        guard !isEvaluatingSchedule else {
            return
        }
        isEvaluatingSchedule = true
        defer { isEvaluatingSchedule = false }
        let now = scheduleNowProvider()
        let appearance = scheduleAppearanceProvider()
        // ルールに実際に登場するスコープに加えて、過去に適用実績のあるスコープも
        // 評価する。後者を含めないと、あるスコープを使うルールを全て削除/無効化
        // した際にそのスコープの解放処理(releaseScheduleAuthority)が二度と
        // 呼ばれず、オーバーライドが張り付いたままになる。
        let scopes = Set(scheduleRules.map(\.scope)).union(lastScheduleApplicationState.keys)
        for scope in scopes {
            evaluateScope(scope, now: now, appearance: appearance)
        }
    }

    private func evaluateScope(
        _ scope: ScheduleScope, now: Date, appearance: ScheduleAppearanceCondition
    ) {
        let matched = Self.matchingScheduleRule(
            in: scheduleRules, scope: scope, now: now, appearance: appearance
        )
        let newState: ScheduleApplicationState = matched.map { .rule($0.id) } ?? .none
        // ルール境界を跨いでいなくても、適用中ルールのターゲット自体が編集された
        // 場合は再適用する(そうしないとピッカーで選び直した壁紙が次の境界まで
        // 反映されない)。手動でのタブ操作等ではルールのtargetは変わらないため、
        // この比較が手動選択の維持と衝突することはない。
        let targetChanged = matched.map { $0.target != lastScheduleAppliedTarget[scope] } ?? false
        guard newState != (lastScheduleApplicationState[scope] ?? .none) || targetChanged else {
            return
        }
        if let rule = matched {
            // 共有スコープのみ、既存のシェアプレイヤー系ガードを踏襲する
            // (autoSwitchTimerFired と同じ pin/deep-suspend 判定)。ディスプレイ別/
            // Space別は既存の setVideoOverride/setSpaceVideo 自体がこれらと無関係に
            // 安全に呼べる設計のため、ガードなしで適用する。
            if scope.kind == .shared, pinCurrentVideo || isDeepSuspended {
                // 状態を更新せずに戻ることで、ガードが外れた次回の評価で再判定される。
                // ガードが外れる各所(setPinCurrentVideo/normalizePlaybackConstraints/
                // resumeFromDeepSuspend)から evaluateSchedule を呼び直して即時反映する。
                return
            }
            // ターゲットが解決できない(動画ファイル欠落・Web元削除)場合は「適用済み」
            // として記録しない。状態を据え置くことで次回評価で再試行し、UIの「適用中」
            // 表示と実際の表示が食い違ったまま固定されるのを防ぐ。
            guard applyScheduleTarget(rule.target, scope: scope) else {
                return
            }
            lastScheduleAppliedTarget[scope] = rule.target
        } else {
            releaseScheduleAuthority(scope: scope)
            lastScheduleAppliedTarget.removeValue(forKey: scope)
        }
        lastScheduleApplicationState[scope] = newState
    }

    /// ターゲットを実際に適用する。適用対象が解決できた(=表示に反映される)場合のみ
    /// true を返す。呼び出し側はこの成否で「適用済み」状態の記録可否を判断する。
    @discardableResult
    private func applyScheduleTarget(_ target: ScheduleTarget, scope: ScheduleScope) -> Bool {
        switch scope.kind {
        case .shared:
            switch target.kind {
            case .video:
                guard let path = target.videoPath, !path.isEmpty,
                      FileManager.default.fileExists(atPath: path)
                else {
                    return false
                }
                selectRegisteredVideo(path: path, clearsPin: false)
                return true
            case .web:
                guard let id = target.webWallpaperID,
                      webWallpaperSources.contains(where: { $0.id == id })
                else {
                    return false
                }
                selectWebWallpaper(id: id)
                return true
            }
        case .display:
            // Web壁紙にはディスプレイ別/Space別の割り当て機構自体が存在しないため、
            // ここに到達するのは常に video ターゲット(UI側でも制限済み)。
            guard target.kind == .video, let path = target.videoPath, !path.isEmpty,
                  FileManager.default.fileExists(atPath: path),
                  let screenID = scope.identifier
            else {
                return false
            }
            setVideoOverride(path: path, forScreenID: screenID)
            return true
        case .space:
            guard target.kind == .video, let path = target.videoPath, !path.isEmpty,
                  FileManager.default.fileExists(atPath: path),
                  let spaceUUID = scope.identifier
            else {
                return false
            }
            setSpaceVideo(path: path, forSpaceUUID: spaceUUID)
            return true
        }
    }

    /// マッチするルールが無くなった(時間枠が終わった)ときに、そのスコープへの
    /// スケジュールの関与を手放す。共有スコープには「解除」の概念がない
    /// (常に何らかの壁紙が表示され続けるため何もしない)。
    private func releaseScheduleAuthority(scope: ScheduleScope) {
        switch scope.kind {
        case .shared:
            break
        case .display:
            guard let screenID = scope.identifier else {
                return
            }
            setVideoOverride(path: nil, forScreenID: screenID)
        case .space:
            guard let spaceUUID = scope.identifier else {
                return
            }
            setSpaceVideo(path: nil, forSpaceUUID: spaceUUID)
        }
    }

    // MARK: - タイマー

    func restartScheduleEvaluationTimer() {
        scheduleEvaluationTimer?.invalidate()
        scheduleEvaluationTimer = nil
        guard !scheduleRules.isEmpty else {
            return
        }
        let interval: TimeInterval = 60
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluateSchedule(trigger: .timerTick)
            }
        }
        // HH:mm単位の機能なので正確さより省電力を優先する(autoSwitchTimerと同じ考え方)。
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        scheduleEvaluationTimer = timer
    }

    /// 簡易UIのトグルをONにした瞬間に壁紙が切り替わって驚かせないよう、
    /// 新規ルールの初期ターゲットは「今表示中の共有壁紙」にする。
    private var currentSharedScheduleTarget: ScheduleTarget {
        if wallpaperKind == .web, let id = currentWebWallpaperID {
            return .web(id)
        }
        return .video(currentVideoPath ?? libraryVideoPaths.first ?? "")
    }

    /// ルールが自分のスコープで first-match に選ばれている状態かどうか(UIの「適用中」表示用)。
    func isScheduleRuleCurrentlyActive(_ id: UUID) -> Bool {
        guard let rule = scheduleRules.first(where: { $0.id == id }) else {
            return false
        }
        return Self.matchingScheduleRule(
            in: scheduleRules, scope: rule.scope,
            now: scheduleNowProvider(), appearance: scheduleAppearanceProvider()
        )?.id == id
    }

    // MARK: - CRUD(高度ルールビルダー)

    /// ルール名の表示用文字列。空なら現在言語の「新しいルール」を補い、旧
    /// 「時間帯で切り替える」簡易UIが保存時に焼き込んだ既定名(l10nキー=日本語
    /// そのもの)は表示のたびに現在言語へ訳し直す。ユーザーが自分で付けた名前は
    /// そのまま返す(キーと偶然一致した場合も訳されるが、意味は保たれる)。
    func scheduleRuleDisplayName(_ name: String) -> String {
        if name.isEmpty {
            return localizedString("新しいルール")
        }
        if name == "昼の壁紙" || name == "夜の壁紙" {
            return localizedString(name)
        }
        return name
    }

    @discardableResult
    func addScheduleRule() -> UUID {
        // 追加直後にターゲットを見直す前に共有壁紙が切り替わってしまわないよう、
        // 新規ルールは無効な状態で作る。ユーザーが内容を確認してトグルをONにする。
        // 名前は空で保存し、表示側が現在の言語で「新しいルール」を補う
        // (訳語を保存データへ焼き込むと後から言語を切り替えても追従しないため)。
        let rule = ScheduleRule(
            id: UUID(),
            name: "",
            isEnabled: false,
            origin: .advanced,
            target: currentSharedScheduleTarget
        )
        let insertionIndex = scheduleRules.firstIndex { $0.origin != .advanced } ?? scheduleRules
            .count
        scheduleRules.insert(rule, at: insertionIndex)
        handleScheduleRulesChanged()
        return rule.id
    }

    /// 似たルールを量産しやすくするための複製。編集を促すため無効状態で直後に挿入する。
    @discardableResult
    func duplicateScheduleRule(id: UUID) -> UUID? {
        guard let index = scheduleRules.firstIndex(where: { $0.id == id }),
              scheduleRules[index].origin == .advanced
        else {
            return nil
        }
        var copy = scheduleRules[index]
        copy.id = UUID()
        copy.isEnabled = false
        copy.name = String(
            format: localizedString("%@ のコピー"),
            scheduleRuleDisplayName(copy.name)
        )
        scheduleRules.insert(copy, at: index + 1)
        handleScheduleRulesChanged()
        return copy.id
    }

    func updateScheduleRule(_ rule: ScheduleRule) {
        guard let index = scheduleRules.firstIndex(where: { $0.id == rule.id }) else {
            return
        }
        scheduleRules[index] = rule
        handleScheduleRulesChanged()
    }

    func removeScheduleRule(id: UUID) {
        guard let index = scheduleRules.firstIndex(where: { $0.id == id }) else {
            return
        }
        scheduleRules.remove(at: index)
        handleScheduleRulesChanged()
    }

    /// 指定した動画パスを参照するルールを取り除く。ライブラリからの動画削除時
    /// (removeRegisteredVideo)に呼ぶ。宙に浮いたルールが無言で何もしなくなったり、
    /// 削除済み動画を再登録・復活させたりするのを防ぐ。
    func pruneScheduleRules(referencingVideoPath path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = scheduleRules.count
        scheduleRules.removeAll { $0.target.kind == .video && $0.target.videoPath == trimmed }
        guard scheduleRules.count != before else {
            return
        }
        handleScheduleRulesChanged()
    }

    /// 指定したWeb壁紙を参照するルールを取り除く。Web壁紙削除時(removeWebWallpaper)に呼ぶ。
    func pruneScheduleRules(referencingWebWallpaperID id: UUID) {
        let before = scheduleRules.count
        scheduleRules.removeAll { $0.target.kind == .web && $0.target.webWallpaperID == id }
        guard scheduleRules.count != before else {
            return
        }
        handleScheduleRulesChanged()
    }

    /// 設定リセット用。全ルールを消してタイマー停止と各スコープの権限解放
    /// (オーバーライド解除)まで一括で行う。
    func resetScheduleState() {
        guard !scheduleRules.isEmpty || !lastScheduleApplicationState.isEmpty else {
            return
        }
        scheduleRules = []
        handleScheduleRulesChanged()
    }

    func setScheduleRuleEnabled(_ enabled: Bool, id: UUID) {
        guard let index = scheduleRules.firstIndex(where: { $0.id == id }),
              scheduleRules[index].isEnabled != enabled
        else {
            return
        }
        scheduleRules[index].isEnabled = enabled
        handleScheduleRulesChanged()
    }

    /// advanced区間内でのみ並べ替え可能(システム管理ルールは常に末尾に留まる)。
    func moveScheduleRule(id: UUID, direction: ScheduleRuleMoveDirection) {
        let advancedIndices = scheduleRules.indices.filter { scheduleRules[$0].origin == .advanced }
        guard let position = advancedIndices.firstIndex(where: { scheduleRules[$0].id == id })
        else {
            return
        }
        let targetPosition = direction == .up ? position - 1 : position + 1
        guard advancedIndices.indices.contains(targetPosition) else {
            return
        }
        scheduleRules.swapAt(advancedIndices[position], advancedIndices[targetPosition])
        handleScheduleRulesChanged()
    }

    // MARK: - 簡易UI: システムの外観設定に従う

    /// 有効なルールが1件でもあるかで判定する。OFF時はルールを削除せず無効化して
    /// 残すため(下記コメント参照)、isEnabled を条件に含める必要がある。
    var followSystemAppearanceEnabled: Bool {
        scheduleRules.contains { $0.origin == .simpleAppearance && $0.isEnabled }
    }

    func setFollowSystemAppearanceEnabled(_ enabled: Bool) {
        guard followSystemAppearanceEnabled != enabled else {
            return
        }
        if enabled {
            if scheduleRules.contains(where: { $0.origin == .simpleAppearance }) {
                // OFF時に無効化して保持しておいたルールを、ライト/ダークの
                // ターゲット指定ごとそのまま復元する。
                setSimpleAppearanceRulesEnabled(true)
            } else {
                let lightTarget = simpleAppearanceTarget(for: .light) ?? currentSharedScheduleTarget
                let darkTarget = simpleAppearanceTarget(for: .dark) ?? currentSharedScheduleTarget
                upsertSystemRule(ScheduleRule(
                    id: Self.simpleAppearanceLightRuleID,
                    name: localizedString("ライトモード用の壁紙"),
                    origin: .simpleAppearance,
                    appearance: .light,
                    target: lightTarget
                ))
                upsertSystemRule(ScheduleRule(
                    id: Self.simpleAppearanceDarkRuleID,
                    name: localizedString("ダークモード用の壁紙"),
                    origin: .simpleAppearance,
                    appearance: .dark,
                    target: darkTarget
                ))
            }
        } else {
            // 削除するとユーザーのライト/ダーク指定が失われる(再ON時に現在の共有壁紙へ
            // 潰れる)。無効化して残すことで、再ONで元の指定を復元できるようにする。
            setSimpleAppearanceRulesEnabled(false)
        }
        handleScheduleRulesChanged()
    }

    func simpleAppearanceTarget(for appearance: ScheduleAppearanceCondition) -> ScheduleTarget? {
        let id = appearance == .dark ? Self.simpleAppearanceDarkRuleID : Self
            .simpleAppearanceLightRuleID
        return scheduleRules.first(where: { $0.id == id })?.target
    }

    /// ライト/ダーク両ルールをまとめて有効/無効にする。トグルOFFでルールを削除せず
    /// 無効化して残す(ユーザー設定を保持する)ために使う。
    private func setSimpleAppearanceRulesEnabled(_ enabled: Bool) {
        for index in scheduleRules.indices where scheduleRules[index].origin == .simpleAppearance {
            scheduleRules[index].isEnabled = enabled
        }
    }

    /// システム管理ルール(simpleAppearance)を、存在すれば更新・無ければ末尾に挿入する。
    /// simpleAppearance は常に advanced ルールより優先度が低い(間接的に導出される
    /// 外観状態より、ユーザーが明示指定したルールの方が具体的、という原則)ため、
    /// 挿入位置は常に配列末尾でよい。
    private func upsertSystemRule(_ rule: ScheduleRule) {
        if let index = scheduleRules.firstIndex(where: { $0.id == rule.id }) {
            scheduleRules[index] = rule
            return
        }
        scheduleRules.append(rule)
    }

    private func handleScheduleRulesChanged() {
        schedulePersistedStateFlush()
        restartScheduleEvaluationTimer()
        evaluateSchedule(trigger: .ruleListChanged)
    }

    // MARK: - 永続化

    func restoreScheduleState() {
        if let data = UserDefaults.standard.data(forKey: "scheduleRulesData"),
           var decoded = try? JSONDecoder().decode([ScheduleRule].self, from: data)
        {
            // 「時間帯で切り替える」簡易UIは曜日スケジュールへ統合され廃止したため、
            // 旧バージョンが作った simpleTimeRange ルールは advanced として扱う。
            // id・時間帯・有効状態はそのまま引き継がれるので、統合後のリストにも
            // 従来どおりの優先順位(配列の並び)で現れる。
            for index in decoded.indices where decoded[index].origin == .simpleTimeRange {
                decoded[index].origin = .advanced
            }
            scheduleRules = decoded
        }
    }
}

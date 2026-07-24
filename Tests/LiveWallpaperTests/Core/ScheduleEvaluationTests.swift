import XCTest
@testable import LiveWallpaper

@MainActor
final class ScheduleEvaluationTests: XCTestCase {
    // WallpaperModel はスケジュールルールだけでなく videoOverrideByScreenID 等も
    // UserDefaults.standard(swift test では xctest プロセスのドメイン)へ同期的に
    // 永続化する。キー単位の掃除では追随漏れが出る(実際に videoOverrideByScreenID の
    // 残骸が次回実行の WallpaperModel() 復元へ漏れ、testUnresolvableTargetIsNotRecorded-
    // AndRetries が落ちた)ため、テストプロセスの永続ドメインごと前後で消す。
    override func setUp() {
        super.setUp()
        Self.wipePersistentDefaults()
    }

    override func tearDown() {
        Self.wipePersistentDefaults()
        super.tearDown()
    }

    private static func wipePersistentDefaults() {
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        UserDefaults.standard.removePersistentDomain(forName: domain)
    }

    // 決定的なテストのため、UTC固定のグレゴリオ暦を使う。
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// 2026-07-13 は月曜日(weekday: 日=1..土=7 では 2)、7-14 は火曜。
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute
        return calendar.date(from: c)!
    }

    private func videoRule(
        id: UUID = UUID(),
        weekdays: Set<Int> = Set(1 ... 7),
        timeRange: ScheduleTimeRange? = nil,
        appearance: ScheduleAppearanceCondition = .any,
        scope: ScheduleScope = .shared,
        isEnabled: Bool = true,
        path: String = "/tmp/a.mov"
    ) -> ScheduleRule {
        ScheduleRule(
            id: id, name: "r", isEnabled: isEnabled, origin: .advanced,
            weekdays: weekdays, timeRange: timeRange, appearance: appearance,
            scope: scope, target: .video(path)
        )
    }

    private func focusFilterRule(
        isEnabled: Bool = true,
        scope: ScheduleScope = .shared,
        path: String = "/tmp/focus.mov"
    ) -> ScheduleRule {
        ScheduleRule(
            id: WallpaperModel.focusFilterRuleID, name: "集中モード", isEnabled: isEnabled,
            origin: .focusFilter, scope: scope, target: .video(path)
        )
    }

    private func range(_ sh: Int, _ sm: Int, _ eh: Int, _ em: Int) -> ScheduleTimeRange {
        ScheduleTimeRange(
            start: ScheduleTimeOfDay(hour: sh, minute: sm),
            end: ScheduleTimeOfDay(hour: eh, minute: em)
        )
    }

    // MARK: - 時間帯マッチング(半開区間・日またぎ・終日)

    func testTimeRangeContainsNormal() {
        let r = range(9, 0, 18, 0)
        XCTAssertTrue(r.contains(ScheduleTimeOfDay(hour: 9, minute: 0)))    // 開始は含む
        XCTAssertTrue(r.contains(ScheduleTimeOfDay(hour: 12, minute: 30)))
        XCTAssertFalse(r.contains(ScheduleTimeOfDay(hour: 18, minute: 0)))  // 終了は含まない
        XCTAssertFalse(r.contains(ScheduleTimeOfDay(hour: 8, minute: 59)))
    }

    func testTimeRangeContainsOvernight() {
        let r = range(22, 0, 6, 0)
        XCTAssertTrue(r.contains(ScheduleTimeOfDay(hour: 22, minute: 0)))
        XCTAssertTrue(r.contains(ScheduleTimeOfDay(hour: 23, minute: 30)))
        XCTAssertTrue(r.contains(ScheduleTimeOfDay(hour: 0, minute: 0)))    // 深夜0時
        XCTAssertTrue(r.contains(ScheduleTimeOfDay(hour: 5, minute: 59)))
        XCTAssertFalse(r.contains(ScheduleTimeOfDay(hour: 6, minute: 0)))   // 終了は含まない
        XCTAssertFalse(r.contains(ScheduleTimeOfDay(hour: 12, minute: 0)))
    }

    func testTimeRangeAllDayWhenStartEqualsEnd() {
        let r = range(0, 0, 0, 0)
        XCTAssertTrue(r.contains(ScheduleTimeOfDay(hour: 0, minute: 0)))
        XCTAssertTrue(r.contains(ScheduleTimeOfDay(hour: 13, minute: 45)))
        XCTAssertTrue(r.contains(ScheduleTimeOfDay(hour: 23, minute: 59)))
    }

    // MARK: - matchingScheduleRule

    func testNilTimeRangeMeansAllDay() {
        let rule = videoRule(timeRange: nil)
        let match = WallpaperModel.matchingScheduleRule(
            in: [rule], scope: .shared, now: date(2026, 7, 13, 3, 0),
            appearance: .light, calendar: calendar
        )
        XCTAssertEqual(match?.id, rule.id)
    }

    func testWeekdayFiltering() {
        let rule = videoRule(weekdays: [2], timeRange: nil) // 月曜のみ
        let monday = WallpaperModel.matchingScheduleRule(
            in: [rule], scope: .shared, now: date(2026, 7, 13, 12, 0),
            appearance: .light, calendar: calendar
        )
        XCTAssertEqual(monday?.id, rule.id)
        let tuesday = WallpaperModel.matchingScheduleRule(
            in: [rule], scope: .shared, now: date(2026, 7, 14, 12, 0),
            appearance: .light, calendar: calendar
        )
        XCTAssertNil(tuesday)
    }

    func testEmptyWeekdaysMeansEveryDay() {
        let rule = videoRule(weekdays: [], timeRange: nil)
        for day in 13 ... 19 {
            let m = WallpaperModel.matchingScheduleRule(
                in: [rule], scope: .shared, now: date(2026, 7, day, 12, 0),
                appearance: .light, calendar: calendar
            )
            XCTAssertEqual(m?.id, rule.id, "day \(day) should match")
        }
    }

    func testAppearanceCondition() {
        let darkRule = videoRule(appearance: .dark)
        XCTAssertNil(WallpaperModel.matchingScheduleRule(
            in: [darkRule], scope: .shared, now: date(2026, 7, 13, 12, 0),
            appearance: .light, calendar: calendar
        ))
        XCTAssertEqual(WallpaperModel.matchingScheduleRule(
            in: [darkRule], scope: .shared, now: date(2026, 7, 13, 12, 0),
            appearance: .dark, calendar: calendar
        )?.id, darkRule.id)
    }

    func testFirstMatchWins() {
        let first = videoRule(timeRange: nil, path: "/tmp/first.mov")
        let second = videoRule(timeRange: nil, path: "/tmp/second.mov")
        let match = WallpaperModel.matchingScheduleRule(
            in: [first, second], scope: .shared, now: date(2026, 7, 13, 12, 0),
            appearance: .light, calendar: calendar
        )
        XCTAssertEqual(match?.id, first.id)
    }

    func testDisabledRuleIsSkipped() {
        let disabled = videoRule(timeRange: nil, isEnabled: false, path: "/tmp/x.mov")
        let enabled = videoRule(timeRange: nil, path: "/tmp/y.mov")
        let match = WallpaperModel.matchingScheduleRule(
            in: [disabled, enabled], scope: .shared, now: date(2026, 7, 13, 12, 0),
            appearance: .light, calendar: calendar
        )
        XCTAssertEqual(match?.id, enabled.id)
    }

    func testScopeIsolation() {
        let sharedRule = videoRule(timeRange: nil, scope: .shared)
        let displayRule = videoRule(timeRange: nil, scope: .display("42"))
        XCTAssertEqual(WallpaperModel.matchingScheduleRule(
            in: [displayRule, sharedRule], scope: .shared, now: date(2026, 7, 13, 12, 0),
            appearance: .light, calendar: calendar
        )?.id, sharedRule.id)
        XCTAssertEqual(WallpaperModel.matchingScheduleRule(
            in: [sharedRule, displayRule], scope: .display("42"), now: date(2026, 7, 13, 12, 0),
            appearance: .light, calendar: calendar
        )?.id, displayRule.id)
    }

    func testOvernightRuleMatchesAcrossMidnight() {
        let rule = videoRule(timeRange: range(22, 0, 6, 0))
        // 23:30(月曜)は一致
        XCTAssertEqual(WallpaperModel.matchingScheduleRule(
            in: [rule], scope: .shared, now: date(2026, 7, 13, 23, 30),
            appearance: .light, calendar: calendar
        )?.id, rule.id)
        // 02:00(火曜)も一致
        XCTAssertEqual(WallpaperModel.matchingScheduleRule(
            in: [rule], scope: .shared, now: date(2026, 7, 14, 2, 0),
            appearance: .light, calendar: calendar
        )?.id, rule.id)
        // 12:00(昼)は不一致
        XCTAssertNil(WallpaperModel.matchingScheduleRule(
            in: [rule], scope: .shared, now: date(2026, 7, 13, 12, 0),
            appearance: .light, calendar: calendar
        ))
    }

    // MARK: - 集中モード(Focus Filter)の優先順位

    /// origin == .focusFilter のルールは、配列内の位置に関わらず曜日/外観ルールより
    /// 常に優先されること。
    func testFocusFilterRuleTakesPriorityOverAdvancedRule() {
        let advanced = videoRule(timeRange: nil, path: "/tmp/advanced.mov")
        let focus = focusFilterRule(path: "/tmp/focus.mov")
        let match = WallpaperModel.matchingScheduleRule(
            in: [advanced, focus], scope: .shared, now: date(2026, 7, 13, 12, 0),
            appearance: .light, calendar: calendar
        )
        XCTAssertEqual(match?.id, focus.id)
    }

    /// Focus Filterが解除された(isEnabled == false)場合は、曜日/外観ルールへ
    /// フォールバックすること。
    func testDisabledFocusFilterRuleFallsBackToAdvancedRule() {
        let advanced = videoRule(timeRange: nil, path: "/tmp/advanced.mov")
        let focus = focusFilterRule(isEnabled: false, path: "/tmp/focus.mov")
        let match = WallpaperModel.matchingScheduleRule(
            in: [advanced, focus], scope: .shared, now: date(2026, 7, 13, 12, 0),
            appearance: .light, calendar: calendar
        )
        XCTAssertEqual(match?.id, advanced.id)
    }

    /// アプリ内トグル(focusFilterEnabled: false)の間は、有効なFocus Filterルールが
    /// 存在しても評価から除外され、曜日/外観ルールへフォールバックすること。
    func testFocusFilterIntegrationDisabledSkipsFocusRule() {
        let advanced = videoRule(timeRange: nil, path: "/tmp/advanced.mov")
        let focus = focusFilterRule(path: "/tmp/focus.mov")
        let match = WallpaperModel.matchingScheduleRule(
            in: [advanced, focus], scope: .shared, now: date(2026, 7, 13, 12, 0),
            appearance: .light, calendar: calendar, focusFilterEnabled: false
        )
        XCTAssertEqual(match?.id, advanced.id)
    }

    /// Focus Filterルールが1件も存在しない既存挙動に変化がないこと(回帰防止)。
    func testNoFocusFilterRuleMeansAdvancedRuleWins() {
        let advanced = videoRule(timeRange: nil, path: "/tmp/advanced.mov")
        let match = WallpaperModel.matchingScheduleRule(
            in: [advanced], scope: .shared, now: date(2026, 7, 13, 12, 0),
            appearance: .light, calendar: calendar
        )
        XCTAssertEqual(match?.id, advanced.id)
    }

    /// applyFocusFilterState(target:) の統合テスト: 有効化で曜日スケジュールを上書きし、
    /// 解除(target: nil)で曜日スケジュールへフォールバックすること。
    func testApplyFocusFilterStateOverridesThenFallsBackToSchedule() throws {
        let scheduledVideo = try makeVideoFile()
        let focusVideo = try makeVideoFile()
        defer {
            try? FileManager.default.removeItem(at: scheduledVideo)
            try? FileManager.default.removeItem(at: focusVideo)
        }

        let model = WallpaperModel()
        model.scheduleNowProvider = { self.date(2026, 7, 13, 12, 0) }
        model.scheduleAppearanceProvider = { .light }
        model.scheduleRules = [videoRule(timeRange: nil, path: scheduledVideo.path)]
        model.evaluateSchedule(trigger: .ruleListChanged)
        XCTAssertEqual(model.currentVideoPath, scheduledVideo.path)

        model.applyFocusFilterState(target: .video(focusVideo.path))
        XCTAssertEqual(model.currentVideoPath, focusVideo.path)
        XCTAssertEqual(model.focusFilterRule?.isEnabled, true)

        model.applyFocusFilterState(target: nil)
        XCTAssertEqual(model.currentVideoPath, scheduledVideo.path)
        XCTAssertEqual(model.focusFilterRule?.isEnabled, false)
    }

    /// 連携トグルOFFで即座に曜日スケジュールへフォールバックし、OFFの間もIntentからの
    /// 状態記録は継続するため、再ONで「今有効な集中モード」の壁紙へ追い付くこと。
    func testFocusFilterIntegrationToggleFallsBackAndCatchesUp() throws {
        let scheduledVideo = try makeVideoFile()
        let focusVideo = try makeVideoFile()
        defer {
            try? FileManager.default.removeItem(at: scheduledVideo)
            try? FileManager.default.removeItem(at: focusVideo)
        }

        let model = WallpaperModel()
        model.scheduleNowProvider = { self.date(2026, 7, 13, 12, 0) }
        model.scheduleAppearanceProvider = { .light }
        model.scheduleRules = [videoRule(timeRange: nil, path: scheduledVideo.path)]
        model.applyFocusFilterState(target: .video(focusVideo.path))
        XCTAssertEqual(model.currentVideoPath, focusVideo.path)

        model.setFocusFilterIntegrationEnabled(false)
        XCTAssertEqual(model.currentVideoPath, scheduledVideo.path)

        // OFF中もIntentからの記録は受け続ける(適用はしない)。
        model.applyFocusFilterState(target: .video(focusVideo.path))
        XCTAssertEqual(model.currentVideoPath, scheduledVideo.path)
        XCTAssertEqual(model.focusFilterRule?.isEnabled, true)

        model.setFocusFilterIntegrationEnabled(true)
        XCTAssertEqual(model.currentVideoPath, focusVideo.path)
    }

    // MARK: - 状態遷移

    func testApplicationStateEquality() {
        let id = UUID()
        XCTAssertEqual(ScheduleApplicationState.rule(id), .rule(id))
        XCTAssertNotEqual(ScheduleApplicationState.rule(id), .rule(UUID()))
        XCTAssertNotEqual(ScheduleApplicationState.rule(id), .none)
        XCTAssertEqual(ScheduleApplicationState.none, .none)
    }

    // MARK: - Codable フォワード互換

    func testDecodingRuleMissingNewFieldsUsesDefaults() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"legacy","target":{"kind":"video","videoPath":"/tmp/a.mov"}}
        """
        let rule = try JSONDecoder().decode(ScheduleRule.self, from: Data(json.utf8))
        XCTAssertTrue(rule.isEnabled)
        XCTAssertEqual(rule.origin, .advanced)
        XCTAssertEqual(rule.weekdays, Set(1 ... 7))
        XCTAssertEqual(rule.appearance, .any)
        XCTAssertEqual(rule.scope, .shared)
        XCTAssertEqual(rule.target.videoPath, "/tmp/a.mov")
    }

    func testRoundTripEncodingPreservesFields() throws {
        let original = videoRule(
            weekdays: [2, 4, 6], timeRange: range(8, 30, 17, 45),
            appearance: .dark, scope: .space("space-uuid")
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScheduleRule.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - evaluateScope: 適用・解放・ターゲット変更の再適用

    private func makeVideoFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("schedule-eval-\(UUID().uuidString).mov")
        try Data("test".utf8).write(to: url)
        return url
    }

    /// ディスプレイ別スコープを使うルールを全て削除すると、そのスコープに張られた
    /// setVideoOverride が解放されること(バグ修正: 未使用スコープを評価対象から
    /// 落としていたため、以前は永久にオーバーライドが残っていた)。
    func testRemovingLastRuleForScopeReleasesOverride() throws {
        let videoURL = try makeVideoFile()
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let screenID = "screen-1"

        let model = WallpaperModel()
        model.scheduleNowProvider = { self.date(2026, 7, 13, 12, 0) }
        model.scheduleAppearanceProvider = { .light }

        let rule = videoRule(timeRange: nil, scope: .display(screenID), path: videoURL.path)
        model.scheduleRules = [rule]
        model.evaluateSchedule(trigger: .ruleListChanged)
        XCTAssertEqual(model.videoOverrideByScreenID[screenID], videoURL.path)

        model.scheduleRules = []
        model.evaluateSchedule(trigger: .ruleListChanged)
        XCTAssertNil(model.videoOverrideByScreenID[screenID])
    }

    /// ルール境界を跨いでいなくても、適用中ルールのターゲット自体を編集したら
    /// 直ちに反映されること(バグ修正: 以前はルールIDの状態遷移だけを見ていたため、
    /// 次の境界が来るまでピッカーでの選び直しが無視されていた)。
    func testEditingActiveRuleTargetReappliesImmediately() throws {
        let firstVideo = try makeVideoFile()
        let secondVideo = try makeVideoFile()
        defer {
            try? FileManager.default.removeItem(at: firstVideo)
            try? FileManager.default.removeItem(at: secondVideo)
        }
        let screenID = "screen-1"

        let model = WallpaperModel()
        model.scheduleNowProvider = { self.date(2026, 7, 13, 12, 0) }
        model.scheduleAppearanceProvider = { .light }

        var rule = videoRule(timeRange: nil, scope: .display(screenID), path: firstVideo.path)
        model.scheduleRules = [rule]
        model.evaluateSchedule(trigger: .ruleListChanged)
        XCTAssertEqual(model.videoOverrideByScreenID[screenID], firstVideo.path)

        rule.target = .video(secondVideo.path)
        model.updateScheduleRule(rule)
        XCTAssertEqual(model.videoOverrideByScreenID[screenID], secondVideo.path)
    }

    // MARK: - 簡易UIトグルの非破壊性(OFF/ONで設定を失わない)

    /// 「時間帯で切り替える」簡易UIは廃止し、曜日スケジュール(advanced)へ統合した。
    /// 旧バージョンが永続化した simpleTimeRange ルールは、読み込み時に advanced へ
    /// 移行され、id・時間帯・有効状態を保ったまま統合後の一覧に現れること。
    func testLegacySimpleTimeRangeRulesMigrateToAdvancedOnRestore() throws {
        let legacyID = UUID()
        let legacyRule = ScheduleRule(
            id: legacyID,
            name: "昼の壁紙",
            isEnabled: false,
            origin: .simpleTimeRange,
            timeRange: ScheduleTimeRange(
                start: ScheduleTimeOfDay(hour: 6, minute: 0),
                end: ScheduleTimeOfDay(hour: 18, minute: 0)
            ),
            target: .video("/tmp/day.mov")
        )
        let data = try JSONEncoder().encode([legacyRule])
        UserDefaults.standard.set(data, forKey: "scheduleRulesData")

        let model = WallpaperModel()
        guard let migrated = model.scheduleRules.first(where: { $0.id == legacyID }) else {
            return XCTFail("legacy rule should still be present after migration")
        }
        XCTAssertEqual(migrated.origin, .advanced)
        XCTAssertEqual(migrated.isEnabled, false)
        XCTAssertEqual(migrated.timeRange, legacyRule.timeRange)
        XCTAssertEqual(migrated.target, legacyRule.target)
    }

    /// 「システムの外観設定に従う」をOFF→ONしても、ライト/ダークの別々の指定が
    /// 保持されること(以前は削除→現在の共有壁紙へ両方潰れていた)。
    func testTogglingFollowAppearanceOffThenOnPreservesDistinctTargets() {
        let model = WallpaperModel()
        model.scheduleNowProvider = { self.date(2026, 7, 13, 12, 0) }
        model.scheduleAppearanceProvider = { .light }

        model.setFollowSystemAppearanceEnabled(true)
        guard var light = model.scheduleRules
            .first(where: { $0.id == WallpaperModel.simpleAppearanceLightRuleID }),
            var dark = model.scheduleRules
            .first(where: { $0.id == WallpaperModel.simpleAppearanceDarkRuleID })
        else {
            return XCTFail("light/dark rules should exist after enabling")
        }
        light.target = .video("/tmp/light.mov")
        dark.target = .video("/tmp/dark.mov")
        model.updateScheduleRule(light)
        model.updateScheduleRule(dark)

        model.setFollowSystemAppearanceEnabled(false)
        XCTAssertFalse(model.followSystemAppearanceEnabled)

        model.setFollowSystemAppearanceEnabled(true)
        XCTAssertTrue(model.followSystemAppearanceEnabled)
        XCTAssertEqual(model.simpleAppearanceTarget(for: .light), .video("/tmp/light.mov"))
        XCTAssertEqual(model.simpleAppearanceTarget(for: .dark), .video("/tmp/dark.mov"))
    }

    // MARK: - 参照先削除時のルール掃除

    /// ライブラリから動画を削除したら、その動画を指すスケジュールルールも
    /// 取り除かれること(宙に浮いたルールの無言no-op/削除済み動画の復活を防ぐ)。
    func testRemovingRegisteredVideoPrunesReferencingScheduleRules() throws {
        let videoURL = try makeVideoFile()
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let model = WallpaperModel()
        XCTAssertTrue(model.addVideoPathToLibrary(videoURL.path))

        let ruleID = UUID()
        model.scheduleRules = [videoRule(id: ruleID, timeRange: nil, path: videoURL.path)]

        model.removeRegisteredVideo(path: videoURL.path)
        XCTAssertFalse(
            model.scheduleRules.contains(where: { $0.id == ruleID }),
            "削除された動画を指すルールは取り除かれるべき"
        )
    }

    // MARK: - 設定リセット

    /// resetScheduleState で全ルールが消え、張られていたオーバーライドも解放されること。
    func testResetScheduleStateClearsRulesAndReleasesOverride() throws {
        let videoURL = try makeVideoFile()
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let screenID = "screen-reset"

        let model = WallpaperModel()
        model.scheduleNowProvider = { self.date(2026, 7, 13, 12, 0) }
        model.scheduleAppearanceProvider = { .light }
        model.scheduleRules = [
            videoRule(timeRange: nil, scope: .display(screenID), path: videoURL.path)
        ]
        model.evaluateSchedule(trigger: .ruleListChanged)
        XCTAssertEqual(model.videoOverrideByScreenID[screenID], videoURL.path)

        model.resetScheduleState()
        XCTAssertTrue(model.scheduleRules.isEmpty)
        XCTAssertNil(model.videoOverrideByScreenID[screenID])
    }

    /// ターゲット動画のファイルが存在しない場合、そのスコープは「適用済み」として
    /// 記録されず、ファイルが復活すれば次の評価で適用されること。
    func testUnresolvableTargetIsNotRecordedAndRetries() throws {
        let videoURL = try makeVideoFile()
        let screenID = "screen-retry"

        let model = WallpaperModel()
        model.scheduleNowProvider = { self.date(2026, 7, 13, 12, 0) }
        model.scheduleAppearanceProvider = { .light }
        model.scheduleRules = [
            videoRule(timeRange: nil, scope: .display(screenID), path: videoURL.path)
        ]

        // ファイルを消してから評価 → 解決できず、オーバーライドは張られない。
        try FileManager.default.removeItem(at: videoURL)
        model.evaluateSchedule(trigger: .ruleListChanged)
        XCTAssertNil(model.videoOverrideByScreenID[screenID])

        // ファイルを復活させて再評価 → 今度は適用される(状態を記録していないので再試行される)。
        try Data("test".utf8).write(to: videoURL)
        defer { try? FileManager.default.removeItem(at: videoURL) }
        model.evaluateSchedule(trigger: .timerTick)
        XCTAssertEqual(model.videoOverrideByScreenID[screenID], videoURL.path)
    }
}

import Foundation

/// macOSの集中モード1件。ModeConfigurations.json の mode オブジェクトから抽出する。
struct FocusMode: Identifiable, Equatable {
    /// modeIdentifier(例: com.apple.donotdisturb.mode.default, com.apple.focus.work)
    let id: String
    /// ユーザーが付けた表示名。標準の「おやすみモード」は空のことがあるため、
    /// 表示側で localizedString へフォールバックする。
    let name: String
    let symbolName: String?

    static let doNotDisturbIdentifier = "com.apple.donotdisturb.mode.default"
}

/// ~/Library/DoNotDisturb/DB のJSONを解釈する純粋パーサ(テスト対象)。
///
/// macOSは集中モードの一覧・現在状態をアプリへ公開するAPIを持たず、以前試した
/// Focus Filter(SetFocusFilterIntent)はTeam ID付き署名がないと実行接続を
/// linkdに拒否されるためad-hoc配布では使えない。そこで getfocus / focus-cli 等の
/// コミュニティツールと同じく、通知センターの非公開DBを直接読む(要フルディスク
/// アクセス)。スキーマは Monterey 以降で安定しているが非公開のため、パースは
/// 全キーを optional 扱いにして壊れても静かに空を返す。
enum FocusModeDBParser {
    /// ModeConfigurations.json からモード一覧を取り出す。
    /// 並びは「おやすみモード」先頭・以降は名前順で安定させる。
    static func parseModes(configurationsJSON: Data) -> [FocusMode] {
        guard let root = try? JSONSerialization.jsonObject(with: configurationsJSON)
            as? [String: Any],
            let configurations = firstDataEntry(root)?["modeConfigurations"]
            as? [String: [String: Any]]
        else {
            return []
        }
        let modes = configurations.compactMap { key, config -> FocusMode? in
            guard let mode = config["mode"] as? [String: Any] else {
                return nil
            }
            return FocusMode(
                id: (mode["modeIdentifier"] as? String) ?? key,
                name: (mode["name"] as? String) ?? "",
                symbolName: mode["symbolImageName"] as? String
            )
        }
        return modes.sorted { lhs, rhs in
            if lhs.id == FocusMode.doNotDisturbIdentifier { return true }
            if rhs.id == FocusMode.doNotDisturbIdentifier { return false }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    /// 今有効なモードの identifier。手動オン(Assertions.json)を優先し、無ければ
    /// 時刻スケジュール起動(ModeConfigurations.json のトリガー)を判定する。
    /// 位置・アプリ起動などのスマート起動トリガーはDB上で判定できないため対象外
    /// (その場合も手動オン相当で Assertions.json に記録されることが多い)。
    static func parseActiveModeID(
        assertionsJSON: Data?,
        configurationsJSON: Data,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        if let assertionsJSON, let manual = parseManualActiveModeID(assertionsJSON) {
            return manual
        }
        return parseScheduledActiveModeID(
            configurationsJSON: configurationsJSON, now: now, calendar: calendar
        )
    }

    private static func parseManualActiveModeID(_ assertionsJSON: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: assertionsJSON)
            as? [String: Any],
            let records = firstDataEntry(root)?["storeAssertionRecords"] as? [[String: Any]]
        else {
            return nil
        }
        for record in records {
            if let details = record["assertionDetails"] as? [String: Any],
               let identifier = details["assertionDetailsModeIdentifier"] as? String
            {
                return identifier
            }
        }
        return nil
    }

    private static func parseScheduledActiveModeID(
        configurationsJSON: Data, now: Date, calendar: Calendar
    ) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: configurationsJSON)
            as? [String: Any],
            let configurations = firstDataEntry(root)?["modeConfigurations"]
            as? [String: [String: Any]]
        else {
            return nil
        }
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let nowMinutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        // Dictionaryの走査順はプロセスごとに変わるため、複数モードの時刻トリガーが
        // 同時にアクティブな場合でも判定が起動のたびにブレないよう、キー順で固定する。
        for (key, config) in configurations.sorted(by: { $0.key < $1.key }) {
            guard let triggerList = (config["triggers"] as? [String: Any])?["triggers"]
                as? [[String: Any]]
            else {
                continue
            }
            for trigger in triggerList {
                // enabledSetting: 2 = 有効、1 = 無効(コミュニティ実装で共通の解釈)。
                guard (trigger["enabledSetting"] as? Int) == 2,
                      let startHour = trigger["timePeriodStartTimeHour"] as? Int,
                      let endHour = trigger["timePeriodEndTimeHour"] as? Int
                else {
                    continue
                }
                let start = startHour * 60 + ((trigger["timePeriodStartTimeMinute"] as? Int) ?? 0)
                let end = endHour * 60 + ((trigger["timePeriodEndTimeMinute"] as? Int) ?? 0)
                // 深夜跨ぎ(例 22:00〜7:00)は区間が反転する。
                let isActive = start <= end
                    ? (nowMinutes >= start && nowMinutes < end)
                    : (nowMinutes >= start || nowMinutes < end)
                if isActive {
                    let mode = config["mode"] as? [String: Any]
                    return (mode?["modeIdentifier"] as? String) ?? key
                }
            }
        }
        return nil
    }

    /// DBのJSONはトップに {"data": [ {...} ]} の入れ物がある。最初の要素だけ使う。
    private static func firstDataEntry(_ root: [String: Any]) -> [String: Any]? {
        (root["data"] as? [[String: Any]])?.first
    }
}

/// DoNotDisturb DBを監視して、モード一覧と現在有効なモードを追跡する。
/// DBディレクトリへの書き込みイベント(ファイルはアトミック置換される)で即時反映し、
/// 時刻トリガーの境界越えは1分タイマーで拾う。
@MainActor
final class FocusModeMonitor {
    enum AccessState: Equatable {
        /// まだ一度も読めていない(初回起動直後など)。
        case unknown
        /// フルディスクアクセス未許可で読めない。
        case denied
        case granted
    }

    private(set) var accessState: AccessState = .unknown
    private(set) var modes: [FocusMode] = []
    private(set) var activeModeID: String?
    /// accessState / modes / activeModeID のいずれかが変化したときに呼ばれる。
    var onChange: (() -> Void)?

    private let dbDirectoryURL: URL
    private var directorySource: DispatchSourceFileSystemObject?
    private var timer: Timer?
    var nowProvider: () -> Date = { Date() }

    init(dbDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true))
    {
        self.dbDirectoryURL = dbDirectoryURL
    }

    deinit {
        directorySource?.cancel()
    }

    func start() {
        refresh()
        startDirectoryWatcherIfPossible()
        guard timer == nil else {
            return
        }
        // 時刻トリガーの境界と、FDAを後から許可した場合の自動復帰の両方を担う。
        // 分単位の機能なので正確さより省電力を優先(scheduleEvaluationTimerと同じ方針)。
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.startDirectoryWatcherIfPossible()
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        let configURL = dbDirectoryURL.appendingPathComponent("ModeConfigurations.json")
        let assertionsURL = dbDirectoryURL.appendingPathComponent("Assertions.json")
        let newState: AccessState
        var newModes: [FocusMode] = []
        var newActiveID: String?
        do {
            let configData = try Data(contentsOf: configURL)
            // Assertions.json はどのモードも手動オンでないときに存在しないことがあるため、
            // 読めなくてもアクセス拒否とは扱わない。
            let assertionsData = try? Data(contentsOf: assertionsURL)
            newState = .granted
            newModes = FocusModeDBParser.parseModes(configurationsJSON: configData)
            newActiveID = FocusModeDBParser.parseActiveModeID(
                assertionsJSON: assertionsData,
                configurationsJSON: configData,
                now: nowProvider()
            )
        } catch {
            let nsError = error as NSError
            let isPermission = nsError.domain == NSCocoaErrorDomain
                && (nsError.code == NSFileReadNoPermissionError
                    || nsError.code == NSFileReadUnknownError)
            newState = isPermission ? .denied : .unknown
            AppLog.focus.debug(
                "focus DB read failed: \(nsError.domain, privacy: .public)#\(nsError.code, privacy: .public)"
            )
        }
        let changed = newState != accessState || newModes != modes || newActiveID != activeModeID
        accessState = newState
        modes = newModes
        activeModeID = newActiveID
        if changed {
            onChange?()
        }
    }

    /// FDA許可前は open が失敗するため、許可後のrefresh契機(タイマー)で再試行する。
    private func startDirectoryWatcherIfPossible() {
        guard directorySource == nil else {
            return
        }
        let descriptor = open(dbDirectoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        directorySource = source
    }
}

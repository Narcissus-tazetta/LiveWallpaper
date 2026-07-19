import Foundation

/// スケジュールルールが指す先(動画 or Web壁紙)。
struct ScheduleTarget: Codable, Equatable {
    enum Kind: String, Codable {
        case video
        case web
    }

    var kind: Kind
    var videoPath: String?
    var webWallpaperID: UUID?

    static func video(_ path: String) -> ScheduleTarget {
        ScheduleTarget(kind: .video, videoPath: path, webWallpaperID: nil)
    }

    static func web(_ id: UUID) -> ScheduleTarget {
        ScheduleTarget(kind: .web, videoPath: nil, webWallpaperID: id)
    }
}

/// 時刻(時・分のみ、タイムゾーンなし・端末ローカル)。
struct ScheduleTimeOfDay: Codable, Equatable, Comparable {
    var hour: Int
    var minute: Int

    var minutesFromMidnight: Int { hour * 60 + minute }

    static func < (lhs: ScheduleTimeOfDay, rhs: ScheduleTimeOfDay) -> Bool {
        lhs.minutesFromMidnight < rhs.minutesFromMidnight
    }
}

/// 時間帯([start, end) の半開区間)。start == end は終日、start > end は日またぎ
/// (例: 22:00-06:00)として扱う。
struct ScheduleTimeRange: Codable, Equatable {
    var start: ScheduleTimeOfDay
    var end: ScheduleTimeOfDay

    func contains(_ time: ScheduleTimeOfDay) -> Bool {
        let s = start.minutesFromMidnight
        let e = end.minutesFromMidnight
        let t = time.minutesFromMidnight
        if s == e {
            return true
        }
        if s < e {
            return t >= s && t < e
        }
        // 日またぎ: [s, 1440) ∪ [0, e)
        return t >= s || t < e
    }
}

/// システムの外観(ダークモード)に対する条件。
enum ScheduleAppearanceCondition: String, Codable {
    case any
    case light
    case dark
}

/// SettingsView.WallpaperScope の永続化可能な鏡像。UI側のenumは非Codableのため
/// 別途こちらを用意し、スケジュールルールの永続化スキーマとして使う。
struct ScheduleScope: Codable, Equatable, Hashable {
    enum Kind: String, Codable, Hashable {
        case shared
        case display
        case space
    }

    var kind: Kind
    /// screenID(ディスプレイ)または SpaceのUUID文字列。kind == .shared のときは nil。
    var identifier: String?

    static let shared = ScheduleScope(kind: .shared, identifier: nil)

    static func display(_ screenID: String) -> ScheduleScope {
        ScheduleScope(kind: .display, identifier: screenID)
    }

    static func space(_ spaceUUID: String) -> ScheduleScope {
        ScheduleScope(kind: .space, identifier: spaceUUID)
    }
}

/// ルールの由来。「システムの外観設定に従う」簡易UIが自動生成・更新するシステム
/// 管理ルール(simpleAppearance)と、「曜日スケジュール」の統合ルールビルダーで
/// ユーザーが直接作成・編集するルール(advanced)を区別する唯一の判別子。高度ルール
/// 一覧UIは origin == .advanced のもののみを表示・編集対象にする。
///
/// simpleTimeRange は「時間帯で切り替える」という別UIが自動生成していた旧originで、
/// 現在はUIを曜日スケジュールへ統合したため新規には作られない。旧バージョンで
/// 永続化された JSON をデコードするためだけに残しており、
/// WallpaperModel.restoreScheduleState が読み込み時に advanced へ移行する。
///
/// focusFilter は macOS の集中モードが現在有効かどうかを表す、simpleAppearance と
/// 同様の自動管理される単一の合成ルール。ユーザーが一覧編集するものではなく、
/// 集中モード監視(WallpaperModel+FocusModes.swift の syncFocusModeState →
/// applyFocusFilterState)が isEnabled/target を書き換える。
enum ScheduleRuleOrigin: String, Codable {
    case simpleAppearance
    case simpleTimeRange
    case advanced
    case focusFilter
}

struct ScheduleRule: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var isEnabled: Bool
    var origin: ScheduleRuleOrigin
    /// Calendar.weekday 準拠(1=日 ... 7=土)。空集合は「毎日」として扱う。
    var weekdays: Set<Int>
    /// nil は「終日(時間帯条件なし)」。
    var timeRange: ScheduleTimeRange?
    var appearance: ScheduleAppearanceCondition
    var scope: ScheduleScope
    var target: ScheduleTarget

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, origin, weekdays, timeRange, appearance, scope, target
    }

    init(
        id: UUID,
        name: String,
        isEnabled: Bool = true,
        origin: ScheduleRuleOrigin = .advanced,
        weekdays: Set<Int> = Set(1 ... 7),
        timeRange: ScheduleTimeRange? = nil,
        appearance: ScheduleAppearanceCondition = .any,
        scope: ScheduleScope = .shared,
        target: ScheduleTarget
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.origin = origin
        self.weekdays = weekdays
        self.timeRange = timeRange
        self.appearance = appearance
        self.scope = scope
        self.target = target
    }

    // 将来のフィールド追加でも既存JSONを壊さないよう、id/name/target 以外は
    // decodeIfPresent でデフォルト値にフォールバックする(WallpaperPlaylist と同じ手法)。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        target = try container.decode(ScheduleTarget.self, forKey: .target)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        origin = try container.decodeIfPresent(ScheduleRuleOrigin.self, forKey: .origin) ?? .advanced
        weekdays = try container.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? Set(1 ... 7)
        timeRange = try container.decodeIfPresent(ScheduleTimeRange.self, forKey: .timeRange)
        appearance = try container.decodeIfPresent(ScheduleAppearanceCondition.self, forKey: .appearance) ?? .any
        scope = try container.decodeIfPresent(ScheduleScope.self, forKey: .scope) ?? .shared
    }
}

/// あるスコープについて「今どのルールが適用されている状態か」。ルール境界(時刻/曜日/
/// 外観の切り替わり)を跨いだ瞬間だけを検出するために使う。
enum ScheduleApplicationState: Equatable {
    case none
    case rule(UUID)
}

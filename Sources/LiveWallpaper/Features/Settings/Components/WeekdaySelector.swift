import SwiftUI

/// 曜日集合(Calendar.weekday準拠、1=日...7=土)を選ぶ7つのカプセル型トグル。
/// 空集合は「毎日」を意味する運用のため、UI上は空集合を「全曜日選択中」として表示する。
/// 記号はシステムロケールではなくアプリ内の言語設定(locale)に従わせる。
struct WeekdaySelector: View {
    @Binding var selection: Set<Int>
    let locale: Locale

    private var symbols: [(weekday: Int, label: String)] {
        // veryShortWeekdaySymbols は 1=日 始まりの固定順(Calendar.firstWeekday非依存)。
        Self.symbols(for: locale).enumerated().map { index, label in
            (weekday: index + 1, label: label)
        }
    }

    private var effectiveSelection: Set<Int> {
        selection.isEmpty ? Set(1 ... 7) : selection
    }

    private var fullSymbols: [String] {
        Self.fullSymbols(for: locale)
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(symbols, id: \.weekday) { entry in
                let isOn = effectiveSelection.contains(entry.weekday)
                let fullName = fullSymbols[entry.weekday - 1]
                Button {
                    toggle(entry.weekday)
                } label: {
                    Text(entry.label)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(
                            Circle().fill(isOn ? Color.accentColor : Color.secondary.opacity(0.15))
                        )
                        .foregroundColor(isOn ? .white : .primary)
                }
                .buttonStyle(.plain)
                // veryShortWeekdaySymbols は火/木など同じ頭文字になる言語があるため、
                // ホバー時のツールチップとVoiceOver向けに完全な曜日名を添える。
                .help(fullName)
                .accessibilityLabel(fullName)
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    /// 指定ロケールの曜日記号(1=日 始まり)。WeekdaySelectorのチップと
    /// ScheduleSectionのサマリーの両方から使い、表記を必ず一致させる。
    static func symbols(for locale: Locale) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        return calendar.veryShortWeekdaySymbols
    }

    /// ツールチップ・VoiceOver用の完全な曜日名(1=日 始まり)。
    static func fullSymbols(for locale: Locale) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        return calendar.weekdaySymbols
    }

    private func toggle(_ weekday: Int) {
        var next = effectiveSelection
        if next.contains(weekday) {
            next.remove(weekday)
        } else {
            next.insert(weekday)
        }
        // 全曜日を選んだ状態は「毎日」= 空集合として正規化しておく
        // (weekdays.isEmpty が「毎日」を意味する ScheduleRule の規約に合わせる)。
        selection = next.count == 7 ? [] : next
    }
}

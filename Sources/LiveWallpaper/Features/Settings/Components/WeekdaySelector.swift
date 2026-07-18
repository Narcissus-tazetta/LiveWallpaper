import SwiftUI

/// 曜日集合(Calendar.weekday準拠、1=日...7=土)を選ぶ7つのカプセル型トグル。
/// 空集合は「毎日」を意味する運用のため、UI上は空集合を「全曜日選択中」として表示する。
struct WeekdaySelector: View {
    @Binding var selection: Set<Int>
    let calendar: Calendar = .current

    private var symbols: [(weekday: Int, label: String)] {
        // veryShortWeekdaySymbols は 1=日 始まりの固定順(Calendar.firstWeekday非依存)。
        calendar.veryShortWeekdaySymbols.enumerated().map { index, label in
            (weekday: index + 1, label: label)
        }
    }

    private var effectiveSelection: Set<Int> {
        selection.isEmpty ? Set(1 ... 7) : selection
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(symbols, id: \.weekday) { entry in
                let isOn = effectiveSelection.contains(entry.weekday)
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
            }
        }
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

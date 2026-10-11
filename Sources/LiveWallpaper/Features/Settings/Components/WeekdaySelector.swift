import AppKit
import SwiftUI

/// 曜日集合(Calendar.weekday準拠、1=日...7=土)を選ぶ、複数選択のネイティブなセグメント。
/// 空集合は「毎日」を意味する運用のため、UI上は空集合を「全曜日選択中」として表示する。
/// 記号はシステムロケールではなくアプリ内の言語設定(locale)に従わせる。
struct WeekdaySelector: NSViewRepresentable {
    @Binding var selection: Set<Int>
    let locale: Locale

    private var effectiveSelection: Set<Int> {
        selection.isEmpty ? Set(1 ... 7) : selection
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: Self.symbols(for: locale),
            trackingMode: .selectAny,
            target: context.coordinator,
            action: #selector(Coordinator.segmentChanged(_:))
        )
        control.segmentDistribution = .fillEqually
        apply(to: control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        apply(to: control)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func apply(to control: NSSegmentedControl) {
        let labels = Self.symbols(for: locale)
        let fullNames = Self.fullSymbols(for: locale)
        for index in 0 ..< 7 {
            control.setLabel(labels[index], forSegment: index)
            // Text segments cannot carry their own accessibility label, so the full name
            // goes in the tooltip, which VoiceOver also reads as the segment's help.
            control.setToolTip(fullNames[index], forSegment: index)
            control.setSelected(effectiveSelection.contains(index + 1), forSegment: index)
        }
    }

    final class Coordinator: NSObject {
        var parent: WeekdaySelector

        init(parent: WeekdaySelector) {
            self.parent = parent
        }

        @objc func segmentChanged(_ sender: NSSegmentedControl) {
            let selected = Set((0 ..< 7).filter { sender.isSelected(forSegment: $0) }.map { $0 + 1 })
            // 全曜日を選んだ状態は「毎日」= 空集合として正規化しておく
            // (weekdays.isEmpty が「毎日」を意味する ScheduleRule の規約に合わせる)。
            // 全部外した場合も空集合になり、毎日として全選択の表示に戻る。
            parent.selection = selected.count == 7 ? [] : selected
        }
    }

    /// 指定ロケールの曜日記号(1=日 始まり)。WeekdaySelectorのセグメントと
    /// ScheduleSectionのサマリーの両方から使い、表記を必ず一致させる。
    /// veryShort だと英語の T(火/木)のように区別できない言語があるため short を使う。
    static func symbols(for locale: Locale) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        return calendar.shortWeekdaySymbols
    }

    /// ツールチップ・VoiceOver用の完全な曜日名(1=日 始まり)。
    static func fullSymbols(for locale: Locale) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        return calendar.weekdaySymbols
    }
}

import SwiftUI

/// A value shown in the unit people read (%, °, s) that can also be typed. The typed
/// number is applied on Return or when the field loses focus, clamped to `range`.
struct SceneNumberField: View {
    let title: String
    let value: Double
    /// Shown number = value × factor.
    var factor: Double = 1
    let unit: String
    let range: ClosedRange<Double>
    var fractionDigits = 0
    let onCommit: (Double) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 2) {
            TextField(title, text: $text)
                .labelsHidden()
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.caption.monospacedDigit())
                .focused($isFocused)
                .onSubmit(commit)
                .accessibilityLabel(title)
            Text(unit)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(isFocused ? 0.1 : 0.05))
        )
        .frame(width: 64)
        .onAppear {
            text = formatted(value)
        }
        .onChange(of: value) { newValue in
            if !isFocused {
                text = formatted(newValue)
            }
        }
        .onChange(of: isFocused) { focused in
            if !focused {
                commit()
            }
        }
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.\(fractionDigits)f", value * factor)
    }

    private func commit() {
        let normalized = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let shown = Double(normalized), shown.isFinite else {
            text = formatted(value)
            return
        }
        let newValue = min(max(shown / factor, range.lowerBound), range.upperBound)
        text = formatted(newValue)
        if newValue != value {
            onCommit(newValue)
        }
    }
}

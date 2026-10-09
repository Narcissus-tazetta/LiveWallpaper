import SwiftUI

extension View {
    /// 壁紙・編集・Store タブで内容を区切るカードの共通背景。設定タブの grouped Form の
    /// セクションと同じ濃さに揃え、ライトモードでも輪郭が消えないよう細い縁を付ける。
    func settingsCardBackground(cornerRadius: CGFloat = 12) -> some View {
        modifier(SettingsCardBackground(cornerRadius: cornerRadius))
    }
}

private struct SettingsCardBackground: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let increased = contrast == .increased
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(increased ? 0.08 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(increased ? 0.35 : 0.07), lineWidth: 1)
            )
    }
}

extension View {
    /// Controls that float over content (the playback bar, toolbar buttons) get Liquid Glass
    /// where the OS has it; earlier systems fall back to a material with a hairline edge.
    @ViewBuilder
    func floatingGlass<S: InsettableShape>(in shape: S) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
    }
}

/// Section heading inside a settings pane. A heading that just repeats the pane's own title
/// (the "Display" section in the Display pane) is left out, as System Settings does.
struct SettingsSectionHeader: View {
    let title: String
    @Environment(\.settingsPaneTitle) private var paneTitle

    var body: some View {
        if title != paneTitle {
            Text(title)
        }
    }
}

/// White symbol on a tinted rounded square, as in the System Settings sidebar.
struct SettingsIconTile: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                tint.gradient,
                in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            )
    }
}

private struct SettingsPaneTitleKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var settingsPaneTitle: String? {
        get { self[SettingsPaneTitleKey.self] }
        set { self[SettingsPaneTitleKey.self] = newValue }
    }
}

extension View {
    /// For icon-only controls. VoiceOver names such a control after its SF Symbol ("pencil",
    /// "chevron.up") and reads a tooltip only as extra help, so the tooltip text doubles as the
    /// accessibility label.
    func iconHelp(_ text: String) -> some View {
        help(text).accessibilityLabel(text)
    }
}

import SwiftUI

extension SettingsView {
    /// 表示可能な設定先タブ。ロック画面は対応OSのときだけ現れる。
    var availableAssignmentTargets: [WallpaperAssignmentTarget] {
        if model.lockScreenSyncService.isSupported {
            return [.desktop, .lockScreen]
        }
        return [.desktop]
    }

    /// 「どこに設定するか」を切り替えるタブバー。各タブは現在割り当て中の
    /// 壁紙のサムネイルと名前を兼ねるので、旧ステータスカードの役割も持つ。
    var wallpaperTargetTabBar: some View {
        HStack(alignment: .center, spacing: 8) {
            ForEach(availableAssignmentTargets, id: \.self) { target in
                targetTabButton(target)
            }

            Spacer(minLength: 8)

            Text("\(model.localizedString("表示")): \(currentDisplayModeSummaryText())")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func targetTabButton(_ target: WallpaperAssignmentTarget) -> some View {
        let isSelected = selectedAssignmentTarget == target
        let tint = targetTint(for: target)

        return Button {
            selectedAssignmentTarget = target
        } label: {
            HStack(spacing: 10) {
                targetPreview(for: target)
                    .frame(width: 72, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Label(targetTitle(for: target), systemImage: targetIconName(for: target))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isSelected ? tint : .primary)
                    Text(targetSummary(for: target))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(minWidth: 90, maxWidth: 200, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? tint.opacity(0.14) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? tint : Color.clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(targetTitle(for: target))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    func targetTitle(for target: WallpaperAssignmentTarget) -> String {
        switch target {
        case .desktop:
            return model.localizedString("デスクトップ")
        case .lockScreen:
            return model.localizedString("ロック画面")
        }
    }

    private func targetIconName(for target: WallpaperAssignmentTarget) -> String {
        switch target {
        case .desktop:
            return "display"
        case .lockScreen:
            return "lock.fill"
        }
    }

    func targetTint(for target: WallpaperAssignmentTarget) -> Color {
        switch target {
        case .desktop:
            return .accentColor
        case .lockScreen:
            return .orange
        }
    }

    private func targetSummary(for target: WallpaperAssignmentTarget) -> String {
        switch target {
        case .desktop:
            return currentWallpaperSummaryText()
        case .lockScreen:
            return currentLockScreenWallpaperSummaryText()
        }
    }

    @ViewBuilder
    private func targetPreview(for target: WallpaperAssignmentTarget) -> some View {
        switch target {
        case .desktop:
            desktopWallpaperPreview
        case .lockScreen:
            lockScreenWallpaperPreview
        }
    }
}

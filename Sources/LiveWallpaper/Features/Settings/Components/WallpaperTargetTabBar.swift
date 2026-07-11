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
    /// 複数ディスプレイ接続時は「デスクトップ」タブの右にシェブロンが付き、
    /// 画面ごとの個別壁紙(プレイリスト込み)へ切り替えられる。
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

    /// 接続が切れた画面を選択したままにならないよう解決した現在の画面ID。
    var resolvedDisplayOverrideScreenID: String? {
        guard let id = selectedDisplayOverrideScreenID else {
            return nil
        }
        guard model.availableDisplayScreens().contains(where: { $0.id == id }) else {
            return nil
        }
        return id
    }

    /// 「デスクトップ」タブが特定ディスプレイの割り当てを表示しているか。
    var isDisplayOverrideModeActive: Bool {
        selectedAssignmentTarget == .desktop && resolvedDisplayOverrideScreenID != nil
    }

    /// コンテンツ側(壁紙一覧・再生コントロールなど)が実際に使ってよい画面ID。
    /// resolvedDisplayOverrideScreenID はデスクトップタブ自身が「前回選んだ画面」を
    /// 覚えておくためタブの選択状態に関わらず値を持ち続けるが、コンテンツ側は
    /// デスクトップタブが選ばれているときだけ画面スコープの表示に切り替えるべき
    /// なので、ここで selectedAssignmentTarget を通す。
    var activeDisplayOverrideScreenID: String? {
        guard selectedAssignmentTarget == .desktop else {
            return nil
        }
        return resolvedDisplayOverrideScreenID
    }

    private var displayScopeBinding: Binding<String?> {
        Binding(
            get: { resolvedDisplayOverrideScreenID },
            set: {
                selectedDisplayOverrideScreenID = $0
                selectedAssignmentTarget = .desktop
            }
        )
    }

    /// デスクトップタブに埋め込む画面切り替えメニュー。インライン Picker なので
    /// チェックマークはシステム標準の見た目になる。
    private func displayScopePicker(tint: Color) -> some View {
        Menu {
            Picker("", selection: displayScopeBinding) {
                Label(
                    model.localizedString("デスクトップ（共有）"),
                    systemImage: "rectangle.on.rectangle"
                )
                .tag(String?.none)
                ForEach(model.availableDisplayScreens()) { screen in
                    Label(screen.name, systemImage: "display").tag(Optional(screen.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(tint)
                .frame(width: 20, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.localizedString("画面ごとに壁紙を切り替え"))
    }

    private func targetTabButton(_ target: WallpaperAssignmentTarget) -> some View {
        let isSelected = selectedAssignmentTarget == target
        let tint = targetTint(for: target)
        let showsDisplayPicker =
            target == .desktop && model.availableDisplayScreens().count > 1

        // カード全体を1つの Button にするとシェブロンのメニューと当たり判定が
        // 競合するため、本体(選択)とシェブロン(画面切り替え)を別コントロール
        // としてカードの装飾を共有する。
        return HStack(spacing: 8) {
            Button {
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)

            if showsDisplayPicker {
                Divider()
                    .frame(height: 28)
                    .opacity(0.4)
                displayScopePicker(tint: isSelected ? tint : .secondary)
            }
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
        .accessibilityLabel(targetTitle(for: target))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    func targetTitle(for target: WallpaperAssignmentTarget) -> String {
        switch target {
        case .desktop:
            if let screenID = resolvedDisplayOverrideScreenID {
                return screenDisplayName(for: screenID)
            }
            return model.localizedString("デスクトップ")
        case .lockScreen:
            return model.localizedString("ロック画面")
        }
    }

    private func targetIconName(for target: WallpaperAssignmentTarget) -> String {
        switch target {
        case .desktop:
            return resolvedDisplayOverrideScreenID != nil ? "display.2" : "display"
        case .lockScreen:
            return "lock.fill"
        }
    }

    func targetTint(for target: WallpaperAssignmentTarget) -> Color {
        switch target {
        case .desktop:
            return resolvedDisplayOverrideScreenID != nil ? .purple : .accentColor
        case .lockScreen:
            return .orange
        }
    }

    private func targetSummary(for target: WallpaperAssignmentTarget) -> String {
        switch target {
        case .desktop:
            if let screenID = resolvedDisplayOverrideScreenID {
                guard let path = model.videoOverride(forScreenID: screenID) else {
                    return model.localizedString("未設定")
                }
                return model.registeredVideoDisplayName(for: path)
            }
            return currentWallpaperSummaryText()
        case .lockScreen:
            return currentLockScreenWallpaperSummaryText()
        }
    }

    @ViewBuilder
    private func targetPreview(for target: WallpaperAssignmentTarget) -> some View {
        switch target {
        case .desktop:
            if let screenID = resolvedDisplayOverrideScreenID {
                displayOverrideWallpaperPreview(forScreenID: screenID)
            } else {
                desktopWallpaperPreview
            }
        case .lockScreen:
            lockScreenWallpaperPreview
        }
    }

    private func screenDisplayName(for screenID: String) -> String {
        model.availableDisplayScreens().first(where: { $0.id == screenID })?.name ?? screenID
    }

    @ViewBuilder
    private func displayOverrideWallpaperPreview(forScreenID screenID: String) -> some View {
        let path = model.videoOverride(forScreenID: screenID)
        wallpaperPreviewThumbnail(
            image: path.flatMap { thumbnailCache.image(for: $0) },
            accessibilityLabel: model.localizedString("現在の壁紙プレビュー")
        )
        .onAppear {
            if let path {
                requestWallpaperThumbnail(path: path)
            }
        }
    }
}

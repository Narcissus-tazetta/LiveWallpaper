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

    /// 削除された Space を選択したままにならないよう解決した現在の Space uuid。
    /// (割り当てデータ自体は保持される。UIスコープの選択だけを解除する)
    var resolvedSpaceScopeUUID: String? {
        guard model.spaceWallpaperFeatureEnabled, model.isSpaceWallpaperAvailable,
              let uuid = selectedSpaceScopeUUID
        else {
            return nil
        }
        guard model.knownDesktopSpaces.contains(where: { $0.uuid == uuid }) else {
            return nil
        }
        return uuid
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

    /// コンテンツ側が実際に使ってよい Space uuid(activeDisplayOverrideScreenID の
    /// Space 版)。画面スコープが有効な間は nil。
    var activeSpaceScopeUUID: String? {
        guard selectedAssignmentTarget == .desktop,
              resolvedDisplayOverrideScreenID == nil
        else {
            return nil
        }
        return resolvedSpaceScopeUUID
    }

    /// スコープ Picker の選択値。共有(nil)・画面("d:<id>")・Space("s:<uuid>") を
    /// 1つの Picker で排他選択させるためのエンコード。
    private var scopeSelectionBinding: Binding<String?> {
        Binding(
            get: {
                if let screenID = resolvedDisplayOverrideScreenID {
                    return "d:\(screenID)"
                }
                if let uuid = resolvedSpaceScopeUUID {
                    return "s:\(uuid)"
                }
                return nil
            },
            set: { value in
                if let value, value.hasPrefix("d:") {
                    selectedDisplayOverrideScreenID = String(value.dropFirst(2))
                    selectedSpaceScopeUUID = nil
                } else if let value, value.hasPrefix("s:") {
                    selectedSpaceScopeUUID = String(value.dropFirst(2))
                    selectedDisplayOverrideScreenID = nil
                } else {
                    selectedDisplayOverrideScreenID = nil
                    selectedSpaceScopeUUID = nil
                }
                selectedAssignmentTarget = .desktop
            }
        )
    }

    /// スコープ Picker に Space の選択肢を出すか。
    private var showsSpaceScopeOptions: Bool {
        model.spaceWallpaperFeatureEnabled && model.isSpaceWallpaperAvailable
            && !model.knownDesktopSpaces.isEmpty
    }

    /// デスクトップタブに埋め込むスコープ切り替えメニュー(共有 / 画面ごと /
    /// Spaceごと)。インライン Picker なのでチェックマークはシステム標準の見た目。
    private func displayScopePicker(tint: Color) -> some View {
        Menu {
            Picker("", selection: scopeSelectionBinding) {
                Label(
                    model.localizedString("デスクトップ（共有）"),
                    systemImage: "infinity"
                )
                .tag(String?.none)

                let screens = model.availableDisplayScreens()
                if !screens.isEmpty {
                    Section(model.localizedString("画面")) {
                        ForEach(screens) { screen in
                            Label(screen.name, systemImage: "display")
                                .tag(Optional("d:\(screen.id)"))
                        }
                    }
                }
                if showsSpaceScopeOptions {
                    Section(model.localizedString("仮想デスクトップ")) {
                        ForEach(model.knownDesktopSpaces) { space in
                            Label(
                                desktopSpaceDisplayName(for: space),
                                systemImage: "macwindow"
                            )
                            .tag(Optional("s:\(space.uuid)"))
                        }
                    }
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

    /// 「デスクトップ2 (現在)」のような Space の表示名。
    func desktopSpaceDisplayName(for space: SpaceInfo) -> String {
        let base = String(
            format: model.localizedString("デスクトップ%d"),
            space.ordinal ?? 0
        )
        if space.uuid == model.currentSpaceUUIDForMainDisplay {
            return "\(base) (\(model.localizedString("現在")))"
        }
        return base
    }

    private func targetTabButton(_ target: WallpaperAssignmentTarget) -> some View {
        let isSelected = selectedAssignmentTarget == target
        let tint = targetTint(for: target)
        let showsDisplayPicker =
            target == .desktop
            && (model.availableDisplayScreens().count > 1 || showsSpaceScopeOptions)

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
            if let uuid = resolvedSpaceScopeUUID,
               let space = model.knownDesktopSpaces.first(where: { $0.uuid == uuid })
            {
                return desktopSpaceDisplayName(for: space)
            }
            return model.localizedString("デスクトップ")
        case .lockScreen:
            return model.localizedString("ロック画面")
        }
    }

    private func targetIconName(for target: WallpaperAssignmentTarget) -> String {
        switch target {
        case .desktop:
            if resolvedDisplayOverrideScreenID != nil {
                return "display.2"
            }
            if resolvedSpaceScopeUUID != nil {
                return "square.on.square"
            }
            return "display"
        case .lockScreen:
            return "lock.fill"
        }
    }

    func targetTint(for target: WallpaperAssignmentTarget) -> Color {
        switch target {
        case .desktop:
            if resolvedDisplayOverrideScreenID != nil {
                return .purple
            }
            if resolvedSpaceScopeUUID != nil {
                return .teal
            }
            return .accentColor
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
            if let uuid = resolvedSpaceScopeUUID {
                guard let path = model.spaceVideo(forSpaceUUID: uuid) else {
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
            } else if let uuid = resolvedSpaceScopeUUID {
                spaceScopeWallpaperPreview(forSpaceUUID: uuid)
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

    @ViewBuilder
    private func spaceScopeWallpaperPreview(forSpaceUUID uuid: String) -> some View {
        let path = model.spaceVideo(forSpaceUUID: uuid)
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

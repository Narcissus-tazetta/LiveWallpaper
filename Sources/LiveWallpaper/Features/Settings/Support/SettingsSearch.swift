import SwiftUI

/// 設定タブのセクション検索。
/// キーワードは各セクションの見出し・項目ラベルのローカライズキー(=日本語文字列)で持ち、
/// 照合時に localizedString を通すことで表示言語でもヒットする。
extension SettingsView {
    enum SettingsSection: CaseIterable {
        case video
        case share
        case webWallpaper
        case display
        case hotKeys
        case screenSaver
        case schedule
        case focusFilter
        case language
        case cache
        case reconversion
        case reset
        case support
        case update
    }

    /// キーワードの実体は各セクションのファイル(VideoSection.swift の `videoSearchKeywords` 等)
    /// に、そのセクションが描く行ラベルと同居させている。ここは種類ごとに参照するだけの
    /// 薄いディスパッチ ― ラベル文言を編集する人とキーワードを編集する人を同じファイル・
    /// 同じスクロール範囲に強制的に同居させ、変更漏れに気付きやすくするため。
    private static func searchKeywords(for section: SettingsSection) -> [String] {
        switch section {
        case .video: return videoSearchKeywords
        case .share: return shareSearchKeywords
        case .webWallpaper: return webWallpaperSearchKeywords
        case .display: return displaySearchKeywords
        case .hotKeys: return hotKeysSearchKeywords
        // 本体は壁紙タブ。schedule と同じく案内行(screenSaverSearchRedirectSection)を出す。
        case .screenSaver: return screenSaverSearchKeywords
        // スケジュール本体は壁紙タブに住んでいる。ここでヒットしても設定タブには
        // セクションを描かず、壁紙タブへ飛ぶ案内行(scheduleSearchRedirectSection)を出す。
        case .schedule: return scheduleSearchKeywords
        // 集中モードカード本体も壁紙タブに住んでいる。scheduleと同じ理由で
        // 案内行(focusFilterSearchRedirectSection)を出す。
        case .focusFilter: return focusFilterSearchKeywords
        case .language: return languageSearchKeywords
        case .cache: return cacheSearchKeywords
        case .reconversion: return reconversionSearchKeywords
        case .reset: return resetSearchKeywords
        case .support: return supportSearchKeywords
        case .update: return updateSearchKeywords
        }
    }

    private var trimmedSettingsSearchQuery: String {
        settingsSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSettingsSearchActive: Bool {
        !trimmedSettingsSearchQuery.isEmpty
    }

    /// 一致したかどうかに加え、どのキーワードで一致したかも返す。一致理由をUIに出すことで、
    /// セクション丸ごと表示という粗い粒度でも「なぜこのセクションが出てきたか」が分かるようにする。
    func settingsSectionMatch(_ section: SettingsSection) -> (matches: Bool, matchedKeyword: String?) {
        let query = trimmedSettingsSearchQuery
        guard !query.isEmpty else {
            return (true, nil)
        }
        let keywords = Self.searchKeywords(for: section)
        let matched = keywords.first { keyword in
            keyword.localizedCaseInsensitiveContains(query)
                || model.localizedString(keyword).localizedCaseInsensitiveContains(query)
        }
        return (matched != nil, matched)
    }

    func settingsSectionMatches(_ section: SettingsSection) -> Bool {
        settingsSectionMatch(section).matches
    }

    /// While searching every matching section shows; otherwise only the chosen category's.
    func settingsSectionVisible(_ section: SettingsSection) -> Bool {
        if isSettingsSearchActive {
            return settingsSectionMatches(section)
        }
        return settingsCategory.sections.contains(section)
    }

    var settingsSidebar: some View {
        VStack(spacing: 6) {
            settingsSearchField
                .background(
                    Button("") { isSettingsSearchFocused = true }
                        .keyboardShortcut("f", modifiers: .command)
                        .hidden()
                )
                .padding(.horizontal, 10)
                .padding(.top, 10)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(SettingsCategory.allCases, id: \.self) { category in
                        settingsSidebarButton(for: category)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .motionAnimation(Motion.standard, value: settingsCategory)
                .motionAnimation(Motion.quick, value: isSettingsSearchActive)
                .motionAnimation(Motion.quick, value: hoveredSettingsCategory)
            }
        }
    }

    /// No row is highlighted while searching, since the results span every category.
    /// Picking a row ends the search.
    private func selectSettingsCategory(_ category: SettingsCategory) {
        settingsCategory = category
        settingsSearchText = ""
        isSettingsSearchFocused = false
    }

    private func settingsSidebarButton(for category: SettingsCategory) -> some View {
        let isSelected = !isSettingsSearchActive && settingsCategory == category
        let isHovered = hoveredSettingsCategory == category
        return Button {
            selectSettingsCategory(category)
        } label: {
            HStack(spacing: 8) {
                SettingsIconTile(systemImage: category.systemImage, tint: category.tint)
                Text(model.localizedString(category.titleKey))
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
                        )
                        .matchedGeometryEffect(id: "selectedSettingsCategory", in: tabSelectionNamespace)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .focused($focusedSettingsCategory, equals: category)
        // The plain List this replaced moved between rows with the arrow keys.
        .onMoveCommand { direction in
            let all = SettingsCategory.allCases
            guard let index = all.firstIndex(of: category) else {
                return
            }
            let next: Int
            switch direction {
            case .up: next = index - 1
            case .down: next = index + 1
            default: return
            }
            guard all.indices.contains(next) else {
                return
            }
            selectSettingsCategory(all[next])
            focusedSettingsCategory = all[next]
        }
        .onHover { hovering in
            hoveredSettingsCategory = hovering
                ? category
                : (hoveredSettingsCategory == category ? nil : hoveredSettingsCategory)
        }
        .accessibilityLabel(model.localizedString(category.titleKey))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    var settingsPaneHeader: some View {
        Section {
            VStack(spacing: 6) {
                SettingsIconTile(
                    systemImage: settingsCategory.systemImage,
                    tint: settingsCategory.tint,
                    size: 52
                )
                .padding(.bottom, 4)
                Text(model.localizedString(settingsCategory.titleKey))
                    .font(.title2.weight(.bold))
                Text(model.localizedString(settingsCategory.subtitleKey))
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }

    var anySettingsSectionMatches: Bool {
        SettingsSection.allCases.contains { settingsSectionMatches($0) }
    }

    /// セクション見出し直下に小さく出す「この検索語に一致した理由」。非検索時や
    /// 一致キーワードがない場合(空クエリ時など)は何も表示しない。
    @ViewBuilder
    func settingsSectionMatchHint(_ section: SettingsSection) -> some View {
        if isSettingsSearchActive, let keyword = settingsSectionMatch(section).matchedKeyword {
            Text(String(format: model.localizedString("一致: %@"), model.localizedString(keyword)))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    var settingsSearchField: some View {
        SearchField(
            placeholder: model.localizedString("設定を検索"),
            text: $settingsSearchText,
            isFocused: $isSettingsSearchFocused,
            clearButtonLabel: model.localizedString("検索をクリア")
        )
        .frame(minWidth: 120, maxWidth: .infinity)
    }
}

#if DEBUG
extension SettingsView {
    /// 新セクション追加時にキーワード登録を丸ごと忘れるケースを検出する軽量チェック。
    static func assertAllSettingsSectionsHaveSearchKeywords() {
        for section in SettingsSection.allCases {
            assert(
                !searchKeywords(for: section).isEmpty,
                "SettingsSection.\(section) has no search keywords registered"
            )
        }
    }
}
#endif

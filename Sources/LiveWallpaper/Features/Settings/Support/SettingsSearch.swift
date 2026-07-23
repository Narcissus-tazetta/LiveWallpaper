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
        case schedule
        case focusFilter
        case language
        case cache
        case reset
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
        // スケジュール本体は壁紙タブに住んでいる。ここでヒットしても設定タブには
        // セクションを描かず、壁紙タブへ飛ぶ案内行(scheduleSearchRedirectSection)を出す。
        case .schedule: return scheduleSearchKeywords
        // 集中モードカード本体も壁紙タブに住んでいる。scheduleと同じ理由で
        // 案内行(focusFilterSearchRedirectSection)を出す。
        case .focusFilter: return focusFilterSearchKeywords
        case .language: return languageSearchKeywords
        case .cache: return cacheSearchKeywords
        case .reset: return resetSearchKeywords
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

    var anySettingsSectionMatches: Bool {
        SettingsSection.allCases.contains { settingsSectionMatches($0) }
    }

    /// セクション見出し直下に小さく出す「この検索語に一致した理由」。非検索時や
    /// 一致キーワードがない場合(空クエリ時など)は何も表示しない。
    @ViewBuilder
    func settingsSectionMatchHint(_ section: SettingsSection) -> some View {
        if isSettingsSearchActive, let keyword = settingsSectionMatch(section).matchedKeyword {
            Text("\(model.localizedString("一致")): \(model.localizedString(keyword))")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    var settingsSearchField: some View {
        SearchField(
            placeholder: model.localizedString("設定を検索"),
            text: $settingsSearchText,
            isFocused: $isSettingsSearchFocused
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

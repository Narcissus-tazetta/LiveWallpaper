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
        case language
        case cache
        case reset
        case update
    }

    private static let settingsSectionKeywords: [SettingsSection: [String]] = [
        .video: [
            "動画",
            "メディアを追加",
            "GIF",
            "WebP",
            "APNG",
            "アニメ画像",
            "クリック貫通を有効にする",
            "ログイン時に自動起動する",
            "音声を再生する",
            "音量"
        ],
        .share: [
            "共有",
            "高度な共有を有効にする",
            ".lwpkg"
        ],
        .webWallpaper: [
            "Web壁紙",
            "Web壁紙機能を有効にする",
            "URL"
        ],
        .display: [
            "表示",
            "デスクトップ切り替え",
            "パフォーマンス・省電力",
            "メニューバー",
            "壁紙の表示先",
            "メインのみ",
            "全ディスプレイ",
            "動画のフィット",
            "デスクトップのアイコンを表示",
            "再生の軽量モード（省電力）",
            "作業中は壁紙の再生を自動停止",
            "ほかのアプリを使っている間は再生を停止",
            "画面がほぼ隠れたら停止（高精度）",
            "再生を止めないアプリ",
            "自動停止しないディスプレイ",
            "デスクトップ（Space）ごとに壁紙を切り替える",
            "メニューバーにデスクトップ番号を表示",
            "デスクトップ・画面切替時に再生位置を記憶する",
            "Space",
            "Mission Control",
            "メニューバーを不透明にする",
            "詳細設定",
            "画質",
            "動作プロファイル",
            "再生負荷",
            "デコード",
            "デスクトップレベル",
            "環境に応じて再生負荷を自動調整",
            "バッテリー残量に応じて画質を自動調整",
            "fullScreenAuxiliary を有効化"
        ],
        .language: [
            "言語",
            "アプリの言語"
        ],
        .cache: [
            "キャッシュ",
            "保存先を開く",
            "キャッシュ削除"
        ],
        .reset: [
            "設定の管理",
            "再生をリフレッシュ",
            "設定をリセット",
            "設定を書き出す…",
            "設定を読み込む…",
            "バックアップ"
        ],
        .update: [
            "アップデート",
            "アップデートを自動で確認する（起動時にも通知）",
            "今すぐ確認",
            "手動ダウンロード"
        ]
    ]

    private var trimmedSettingsSearchQuery: String {
        settingsSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSettingsSearchActive: Bool {
        !trimmedSettingsSearchQuery.isEmpty
    }

    func settingsSectionMatches(_ section: SettingsSection) -> Bool {
        let query = trimmedSettingsSearchQuery
        guard !query.isEmpty else {
            return true
        }
        guard let keywords = Self.settingsSectionKeywords[section] else {
            return true
        }
        return keywords.contains { keyword in
            keyword.localizedCaseInsensitiveContains(query)
                || model.localizedString(keyword).localizedCaseInsensitiveContains(query)
        }
    }

    var anySettingsSectionMatches: Bool {
        SettingsSection.allCases.contains { settingsSectionMatches($0) }
    }

    var settingsSearchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundColor(.secondary)
                .onTapGesture {
                    isSettingsSearchFocused = true
                }
            LibrarySearchField(
                text: $settingsSearchText,
                placeholder: model.localizedString("設定を検索"),
                isFocused: $isSettingsSearchFocused
            )
            .frame(width: 170)
            Button {
                settingsSearchText = ""
                isSettingsSearchFocused = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(settingsSearchText.isEmpty ? 0 : 1)
            .disabled(settingsSearchText.isEmpty)
            .allowsHitTesting(!settingsSearchText.isEmpty)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isSettingsSearchFocused ? Color.accentColor : Color.clear,
                    lineWidth: 1.5
                )
        )
    }
}

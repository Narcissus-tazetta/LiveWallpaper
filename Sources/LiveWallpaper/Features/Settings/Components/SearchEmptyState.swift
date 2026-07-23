import SwiftUI

/// 「そもそも中身が無い」と「検索条件に一致しない」を区別するための共有の空状態View。
/// 呼び出し側は既にローカライズ済みの文言/Viewを渡す(このコンポーネント自体は文言を持たない)。
struct SearchEmptyState<NoContent: View, NoMatch: View>: View {
    var isSearchActive: Bool
    var clearButtonTitle: String? = nil
    var onClearSearch: (() -> Void)? = nil
    @ViewBuilder var noContent: () -> NoContent
    @ViewBuilder var noMatch: () -> NoMatch

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isSearchActive {
                noMatch()
                if let clearButtonTitle, let onClearSearch {
                    Button(clearButtonTitle, action: onClearSearch)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            } else {
                noContent()
            }
        }
    }
}

extension SearchEmptyState where NoContent == Text, NoMatch == Text {
    /// 両状態ともプレーンな caption + secondary色のテキストで十分な場合の簡易イニシャライザ。
    init(
        isSearchActive: Bool,
        noContentText: String,
        noMatchText: String,
        clearButtonTitle: String? = nil,
        onClearSearch: (() -> Void)? = nil
    ) {
        self.init(
            isSearchActive: isSearchActive,
            clearButtonTitle: clearButtonTitle,
            onClearSearch: onClearSearch,
            noContent: {
                Text(noContentText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            },
            noMatch: {
                Text(noMatchText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        )
    }
}

import SwiftUI

extension SettingsView {
    /// 壁紙タブの一覧ペイン下に並ぶ折りたたみカード(スケジュール/集中モード)の
    /// 共通ヘッダー。アイコン付きタイトル・1行サマリー・開閉シェブロンを持ち、
    /// 行全体のタップで開閉する。`trailing` には集中モードのマスタースイッチの
    /// ように、閉じたままでも操作したい追加コントロールを渡せる。
    @ViewBuilder
    func collapsibleCardHeader<Trailing: View>(
        title: String,
        systemImage: String,
        summary: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
            Text(summary)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            trailing()
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.wrappedValue.toggle()
            }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title)
        .accessibilityValue(summary)
    }

    /// `trailing` 不要な呼び出し向けのオーバーロード。
    func collapsibleCardHeader(
        title: String,
        systemImage: String,
        summary: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        collapsibleCardHeader(
            title: title,
            systemImage: systemImage,
            summary: summary,
            isExpanded: isExpanded,
            trailing: { EmptyView() }
        )
    }

    /// スケジュールルール/集中モードのターゲットピッカーに共通のWeb壁紙カード。
    /// サムネイル+名前のボタンで、選択状態(`isSelected`)とタップ時の割り当て
    /// 処理(`onSelect`)だけが呼び出し元ごとに異なる。
    func webWallpaperTargetButton(
        source: WebWallpaperSource,
        isSelected: Bool,
        cardWidth: CGFloat,
        onSelect: @escaping () -> Void
    ) -> some View {
        Button(action: onSelect) {
            VStack(spacing: 4) {
                WebWallpaperThumbnailView(
                    source: source,
                    isActive: isSelected,
                    thumbnailStore: webThumbnailStore,
                    width: cardWidth,
                    height: (cardWidth * 9 / 16).rounded()
                )
                Text(source.displayName)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

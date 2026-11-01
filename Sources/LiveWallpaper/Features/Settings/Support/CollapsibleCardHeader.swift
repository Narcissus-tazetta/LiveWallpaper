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
            // Labelling the whole row would hand the label to each child (three identical
            // buttons in VoiceOver) and swallow the trailing switch, so only the title part
            // becomes the button.
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.numericText())
                    .motionAnimation(Motion.quick, value: summary)
                Spacer()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(title)
            .accessibilityValue(summary)
            .accessibilityAction {
                isExpanded.wrappedValue.toggle()
            }
            trailing()
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withMotion {
                isExpanded.wrappedValue.toggle()
            }
        }
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
        selectionGroupID: String = "pickerWallpaperGridSelection",
        onSelect: @escaping () -> Void
    ) -> some View {
        let thumbnailWidth = max(cardWidth - 8, 1)
        let thumbnailHeight = (thumbnailWidth * 9 / 16).rounded()
        return Button {
            withMotion {
                onSelect()
            }
        } label: {
            VStack(spacing: 4) {
                WebWallpaperThumbnailView(
                    source: source,
                    isActive: isSelected,
                    thumbnailStore: webThumbnailStore,
                    width: thumbnailWidth,
                    height: thumbnailHeight
                )
                Text(source.displayName)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .padding(4)
            .frame(width: cardWidth)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                        )
                        .shadow(color: Color.accentColor.opacity(0.38), radius: 6, y: 0)
                        .matchedGeometryEffect(id: selectionGroupID, in: tabSelectionNamespace)
                        .transition(.asymmetric(insertion: .identity, removal: .opacity))
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(PressableButtonStyle())
        .zIndex(isSelected ? 2 : 0)
    }
}

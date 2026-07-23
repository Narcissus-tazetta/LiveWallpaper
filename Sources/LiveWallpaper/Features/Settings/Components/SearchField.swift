import SwiftUI

/// アプリ全体で使う検索フィールド。虫眼鏡アイコン + テキスト入力 + クリアボタン + 任意の
/// インフライト・インジケータを1つにまとめ、複数箇所の検索バーで見た目と挙動を統一する。
struct SearchField: View {
    var placeholder: String
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var isSearching: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundColor(.secondary)

            // grouped Form 内では `TextField(タイトル, text:)` がタイトル付きフォーム行と
            // 見なされ、値が右寄せ/中央寄せになる(macOS 26)。`prompt:` + `.labelsHidden()`
            // で通常の左寄せ入力欄に固定する。
            TextField("", text: $text, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .multilineTextAlignment(.leading)
                .focused(isFocused)

            if isSearching {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            } else {
                Button {
                    text = ""
                    isFocused.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(text.isEmpty ? 0 : 1)
                .disabled(text.isEmpty)
                .allowsHitTesting(!text.isEmpty)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFocused.wrappedValue ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { isFocused.wrappedValue = true }
    }
}

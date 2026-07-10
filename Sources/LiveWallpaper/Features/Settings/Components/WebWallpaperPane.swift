import SwiftUI

extension SettingsView {
    /// Web壁紙セクション。設定タブの「Web壁紙機能を有効にする」がONのときだけ
    /// 壁紙タブの下部に表示される。
    var webWallpaperPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Label(model.localizedString("Web壁紙"), systemImage: "globe")
                    .font(.system(size: 13, weight: .semibold))
                if model.isWebWallpaperActive {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                }
                Spacer(minLength: 0)
                Text("\(model.webWallpaperSources.count) \(model.localizedString("本"))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            webWallpaperURLInputSection
            webWallpaperContent
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    @ViewBuilder
    private var webWallpaperContent: some View {
        if model.webWallpaperSources.isEmpty {
            Text(model.localizedString("登録済みのWeb壁紙はありません"))
                .font(.caption)
                .foregroundColor(.secondary)
        } else if filteredWebSources.isEmpty {
            Text(model.localizedString("該当するWeb壁紙がありません"))
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            webWallpaperGrid
        }
    }

    private var webWallpaperURLInputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.localizedString("WebサイトのURLを入力すると、そのページを壁紙として表示できます"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(model.localizedString("※ いま動作確認できているのは YouTube だけです。ほかのサイトも試せますが、表示できない場合があります"))
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                PasteableTextField(
                    text: $webURLInput,
                    placeholder: model.localizedString("https://example.com"),
                    onSubmit: submitWebWallpaperURL
                )
                .frame(minWidth: 200)

                Button {
                    if let pasted = PasteboardPaste.readPlainText() {
                        webURLInput = pasted
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .help(model.localizedString("クリップボードから貼り付け"))

                Button(model.localizedString("追加")) {
                    submitWebWallpaperURL()
                }
                .buttonStyle(.borderedProminent)
                .disabled(webURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let errorMessage = model.webWallpaperErrorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    private var webWallpaperGrid: some View {
        GeometryReader { proxy in
            let layout = wallpaperGridLayout(for: proxy.size.width)
            ScrollView {
                LazyVGrid(
                    columns: layout.0,
                    alignment: .leading,
                    spacing: wallpaperGridRowSpacing
                ) {
                    ForEach(filteredWebSources) { source in
                        webWallpaperCard(source: source, cardWidth: layout.1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
        }
        .frame(minHeight: 160, maxHeight: 340)
    }
}

import SwiftUI

extension SettingsView {
    var webWallpaperPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isWebWallpaperExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Label(model.localizedString("Web壁紙"), systemImage: "globe")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    webWallpaperStatusLabel()
                    Image(systemName: isWebWallpaperExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isWebWallpaperExpanded {
                webWallpaperExpandedContent
                    .padding(.top, 10)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var webWallpaperExpandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.localizedString("WebサイトのURLを入力すると、そのページを壁紙として表示できます"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(model.localizedString("YouTubeのURLは動画のみの表示に自動変換されます"))
                .font(.caption2)
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

            if model.webWallpaperSources.isEmpty {
                Text(model.localizedString("登録済みのWeb壁紙はありません"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.webWallpaperSources) { source in
                        webWallpaperRow(source: source)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func webWallpaperStatusLabel() -> some View {
        if model.isWebWallpaperActive {
            switch model.webWallpaperLoadState {
            case .loading:
                Text(model.localizedString("読み込み中"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            case .loaded:
                Text(model.localizedString("表示中"))
                    .font(.caption)
                    .foregroundColor(.green)
            case .failed:
                Text(model.localizedString("読み込み失敗"))
                    .font(.caption)
                    .foregroundColor(.orange)
            case .idle:
                EmptyView()
            }
        }
    }

    private func webWallpaperRow(source: WebWallpaperSource) -> some View {
        let isActive = model.currentWebWallpaperID == source.id && model.isWebWallpaperActive

        return HStack(spacing: 10) {
            WebWallpaperThumbnailView(
                source: source,
                isActive: isActive,
                thumbnailStore: webThumbnailStore
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                    .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                    .lineLimit(1)
                Text(source.url.absoluteString)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isActive {
                Text(model.localizedString("選択中"))
                    .font(.caption2)
                    .foregroundColor(.accentColor)
            }

            Button {
                model.selectWebWallpaper(id: source.id)
            } label: {
                Text(model.localizedString("適用"))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(role: .destructive) {
                webThumbnailStore.remove(sourceID: source.id)
                model.removeWebWallpaper(id: source.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
        )
    }

    func submitWebWallpaperURL() {
        do {
            _ = try model.addWebWallpaper(urlString: webURLInput)
            webURLInput = ""
            isWebWallpaperExpanded = true
        } catch {
            if let urlError = error as? WebWallpaperURLError {
                model.webWallpaperErrorMessage = model.localizedString(
                    urlError.errorDescription ?? error.localizedDescription
                )
            } else {
                model.webWallpaperErrorMessage = error.localizedDescription
            }
            isWebWallpaperExpanded = true
        }
    }
}

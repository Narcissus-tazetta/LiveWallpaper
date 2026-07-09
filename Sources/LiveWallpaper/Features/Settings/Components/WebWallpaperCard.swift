import SwiftUI

extension SettingsView {
    func webWallpaperCard(source: WebWallpaperSource, cardWidth: CGFloat) -> some View {
        let thumbnailWidth = max(cardWidth - 8, 1)
        let thumbnailHeight = (thumbnailWidth * 9 / 16).rounded()
        let isActive = model.currentWebWallpaperID == source.id && model.isWebWallpaperActive
        let strokeColor: Color = isActive ? Color.accentColor : .clear

        let thumbnailButton = Button {
            model.selectWebWallpaper(id: source.id)
        } label: {
            ZStack {
                WebWallpaperThumbnailView(
                    source: source,
                    isActive: isActive,
                    thumbnailStore: webThumbnailStore,
                    width: thumbnailWidth,
                    height: thumbnailHeight
                )

                VStack {
                    HStack {
                        webWallpaperStatusBadge(isActive: isActive)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 4)
                    .padding(.horizontal, 4)
                    Spacer(minLength: 0)
                }
            }
            .frame(width: thumbnailWidth, height: thumbnailHeight)
        }
        .buttonStyle(.plain)

        return VStack(alignment: .leading, spacing: 8) {
            thumbnailButton

            HStack(spacing: 2) {
                Text(source.displayName)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(4)
        .frame(width: cardWidth, alignment: .leading)
        .clipped()
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(strokeColor, lineWidth: strokeColor == .clear ? 0 : 1.5)
        )
        .contextMenu {
            Button(model.localizedString("適用")) {
                model.selectWebWallpaper(id: source.id)
            }
            Divider()
            Button(role: .destructive) {
                webThumbnailStore.remove(sourceID: source.id)
                model.removeWebWallpaper(id: source.id)
            } label: {
                Text(model.localizedString("削除"))
            }
        }
    }

    @ViewBuilder
    private func webWallpaperStatusBadge(isActive: Bool) -> some View {
        if isActive, let (text, color) = webWallpaperStatusBadgeContent {
            Text(text)
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(color.opacity(0.85), in: Capsule())
        }
    }

    private var webWallpaperStatusBadgeContent: (String, Color)? {
        switch model.webWallpaperLoadState {
        case .loading:
            return (model.localizedString("読み込み中"), .secondary)
        case .loaded:
            return (model.localizedString("表示中"), .green)
        case .failed:
            return (model.localizedString("読み込み失敗"), .orange)
        case .idle:
            return nil
        }
    }
}

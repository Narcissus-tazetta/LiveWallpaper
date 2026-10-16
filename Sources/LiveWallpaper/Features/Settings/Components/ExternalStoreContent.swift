import AVFoundation
import ImageIO
import SwiftUI

extension SettingsView {
    var externalStoreContent: some View {
        let query = externalStoreSearchText.trimmingCharacters(in: .whitespaces)
        let wallpapers = model.externalWallpapers.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
        }
        return VStack(alignment: .leading, spacing: 10) {
            SearchField(
                placeholder: model.localizedString("タイトルで検索"),
                text: $externalStoreSearchText,
                isFocused: $isStoreSearchFocused,
                isSearching: false,
                clearButtonLabel: model.localizedString("検索をクリア")
            )
            .frame(maxWidth: 260)

            if wallpapers.isEmpty {
                SearchEmptyState(
                    isSearchActive: true,
                    noContentText: "",
                    noMatchText: model.localizedString("検索条件に一致する壁紙がありません"),
                    clearButtonTitle: model.localizedString("検索をクリア"),
                    onClearSearch: { externalStoreSearchText = ""; isStoreSearchFocused = true }
                )
            } else {
                GeometryReader { proxy in
                    let layout = wallpaperGridLayout(for: proxy.size.width)
                    ScrollView {
                        LazyVGrid(
                            columns: layout.0,
                            alignment: .leading,
                            spacing: wallpaperGridRowSpacing
                        ) {
                            ForEach(wallpapers) { wallpaper in
                                externalStoreCard(wallpaper, cardWidth: layout.1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                }
                .frame(minHeight: 320, maxHeight: 560)
            }
        }
    }

    private func externalStoreCard(
        _ wallpaper: ExternalWallpaper,
        cardWidth: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ExternalWallpaperThumbnail(wallpaper: wallpaper)
                .frame(width: cardWidth, height: cardWidth * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)

            Text(wallpaper.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Text(wallpaper.providerName)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)

            if model.libraryPath(forExternalWallpaperID: wallpaper.id) != nil {
                Text(model.localizedString("追加しました"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if model.importingExternalWallpaperID == wallpaper.id {
                ProgressView().controlSize(.small)
            } else {
                Button(model.localizedString("追加")) {
                    Task {
                        await model.importExternalWallpaper(id: wallpaper.id)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.importingExternalWallpaperID != nil)
                .accessibilityLabel("\(model.localizedString("追加")) \(wallpaper.name)")
                if model.failedExternalWallpaperImportID == wallpaper.id {
                    Text(model.localizedString("追加できませんでした"))
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
        .frame(width: cardWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// The provider's own image when it gave one, otherwise a frame from the video.
struct ExternalWallpaperThumbnail: View {
    let wallpaper: ExternalWallpaper
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film.stack")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary)
            }
        }
        .task(id: wallpaper.id) {
            image = await Self.load(wallpaper)
        }
    }

    private static let maxPixelSize = 480

    private static func load(_ wallpaper: ExternalWallpaper) async -> CGImage? {
        if let path = wallpaper.thumbnailPath,
           let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
           ] as CFDictionary)
        {
            return image
        }
        let generator =
            AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: wallpaper.path)))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        do {
            return try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        } catch {
            AppLog.externalWallpapers.error(
                "no thumbnail for \(wallpaper.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}

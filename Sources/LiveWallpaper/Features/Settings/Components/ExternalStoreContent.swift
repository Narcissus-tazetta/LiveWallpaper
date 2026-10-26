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
            HStack(alignment: .center) {
                SearchField(
                    placeholder: model.localizedString("タイトルで検索"),
                    text: $externalStoreSearchText,
                    isFocused: $isStoreSearchFocused,
                    isSearching: false,
                    clearButtonLabel: model.localizedString("検索をクリア")
                )
                .frame(maxWidth: 260)

                Spacer()

                Button {
                    model.openExternalWallpaperProvider()
                } label: {
                    Label(model.localizedString("Workshopで探す"), systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(model.localizedString("we-import を開いて Steam Workshop から壁紙を探します"))
            }

            if wallpapers.isEmpty {
                VStack(spacing: 12) {
                    SearchEmptyState(
                        isSearchActive: !query.isEmpty,
                        noContentText: model.localizedString("外部アプリの壁紙がありません"),
                        noMatchText: model.localizedString("検索条件に一致する壁紙がありません"),
                        clearButtonTitle: model.localizedString("検索をクリア"),
                        onClearSearch: { externalStoreSearchText = ""; isStoreSearchFocused = true }
                    )
                    if query.isEmpty {
                        Button {
                            model.openExternalWallpaperProvider()
                        } label: {
                            Label(model.localizedString("Workshopで壁紙を探す"), systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                GeometryReader { proxy in
                    let layout = wallpaperGridLayout(for: proxy.size.width)
                    ScrollView {
                        LazyVGrid(
                            columns: layout.0.map { column in
                                var column = column
                                column.alignment = .top
                                return column
                            },
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
                // Clipping the image does not keep its hit region out of adjacent rows.
                .allowsHitTesting(false)

            Text(wallpaper.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Text(wallpaper.providerName)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)

            if let warnings = wallpaper.webSource?.warnings, !warnings.isEmpty {
                Label(model.localizedString("未対応"), systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .help(warnings.joined(separator: "\n"))
                    .accessibilityLabel(warnings.joined(separator: "\n"))
            }
            HStack(alignment: .top, spacing: 6) {
                if model.hasAuthorSettings(forExternalWallpaper: wallpaper) {
                    Button(model.localizedString("作品の設定")) {
                        if let context = model.authorSettingsContext(forExternalWallpaper: wallpaper) {
                            authorSettingsContext = context
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if !model.isExternalWallpaperReady(wallpaper) {
                    externalScenePreparationStatus(wallpaper)
                } else if model.libraryPath(forExternalWallpaperID: wallpaper.id) != nil {
                    Text(model.localizedString("追加しました"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if model.importingExternalWallpaperID == wallpaper.id {
                    ProgressView().controlSize(.small)
                } else {
                    Button(model.localizedString("追加")) {
                        AppLog.externalWallpapers.info("add button clicked for \(wallpaper.id, privacy: .public)")
                        Task {
                            await model.importExternalWallpaper(id: wallpaper.id)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.importingExternalWallpaperID != nil)
                    .contentShape(Rectangle())
                    .accessibilityLabel("\(model.localizedString("追加")) \(wallpaper.name)")
                    if model.failedExternalWallpaperImportID == wallpaper.id {
                        Text(model.localizedString("追加できませんでした"))
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            .frame(minHeight: 22, alignment: .topLeading)
        }
        .frame(width: cardWidth, alignment: .leading)
        .id(wallpaper.id)
        .accessibilityElement(children: .contain)
    }
}

/// The provider's own image when it gave one, otherwise a frame from the video.
struct ExternalWallpaperThumbnail: View {
    let wallpaper: ExternalWallpaper
    @State private var image: CGImage?

    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 24
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    private static func cacheKey(for wallpaper: ExternalWallpaper) -> NSString {
        let rev = wallpaper.sceneRevision?.timeIntervalSince1970 ?? 0
        let thumb = wallpaper.thumbnailPath ?? ""
        return "\(wallpaper.id):\(rev):\(thumb)" as NSString
    }

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: wallpaper.webSource == nil ? "film.stack" : "globe")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .onAppear {
            if image == nil, let cached = Self.cache.object(forKey: Self.cacheKey(for: wallpaper)) {
                image = cached
            }
        }
        .task(id: wallpaper.id) {
            if image == nil {
                image = await Self.load(wallpaper)
            }
        }
    }

    private static let maxPixelSize = 480

    private static func load(_ wallpaper: ExternalWallpaper) async -> CGImage? {
        let key = cacheKey(for: wallpaper)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let image: CGImage?
        if let path = wallpaper.thumbnailPath,
           let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let generated = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetCount(source) / 2, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
           ] as CFDictionary)
        {
            image = generated
        } else if wallpaper.webSource != nil || wallpaper.path.isEmpty || !FileManager.default.fileExists(atPath: wallpaper.path) {
            return nil
        } else {
            let generator =
                AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: wallpaper.path)))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
            do {
                image = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
            } catch {
                AppLog.externalWallpapers.error(
                    "no thumbnail for \(wallpaper.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }
        if let image {
            cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        }
        return image
    }
}

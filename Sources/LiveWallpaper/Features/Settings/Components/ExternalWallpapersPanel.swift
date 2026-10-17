import SwiftUI

extension SettingsView {
    /// Shown only while a provider app offers wallpapers, so the library looks the same
    /// as always when none is running.
    var externalWallpapersPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.localizedString("外部アプリの壁紙"))
                    .font(.headline)
                Text(providerNames)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if model.activeExternalWallpaperID != nil {
                    Button(model.localizedString("元の壁紙に戻す")) {
                        model.stopExternalWallpaper()
                    }
                }
            }
            if !model.canShowExternalWallpaper {
                Text(model.localizedString("Web壁紙の表示中は使えません"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(model.externalWallpapers) { wallpaper in
                        externalWallpaperButton(wallpaper)
                    }
                }
            }
        }
    }

    /// Every card would repeat the same provider, so it is named once by the title.
    private var providerNames: String {
        var seen = Set<String>()
        return model.externalWallpapers.map(\.providerName)
            .filter { seen.insert($0).inserted }
            .joined(separator: model.localizedString("・"))
    }

    private func externalWallpaperButton(_ wallpaper: ExternalWallpaper) -> some View {
        let isActive = model.activeExternalWallpaperID == wallpaper.id
        let width: CGFloat = 132
        return Button {
            model.showExternalWallpaper(id: wallpaper.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                ExternalWallpaperThumbnail(wallpaper: wallpaper)
                    .frame(width: width, height: width * 9 / 16)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor, lineWidth: isActive ? 2.5 : 0)
                    )
                Text(wallpaper.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: width, alignment: .leading)
                externalScenePreparationStatus(wallpaper)
                    .frame(width: width, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canShowExternalWallpaper || !model.isExternalWallpaperReady(wallpaper))
        .opacity(model.canShowExternalWallpaper && model.isExternalWallpaperReady(wallpaper) ? 1 : 0.5)
        .help(wallpaper.name)
        .accessibilityLabel(wallpaper.name)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    /// A scene is baked into a video before it can be shown; nothing for videos.
    @ViewBuilder
    func externalScenePreparationStatus(_ wallpaper: ExternalWallpaper) -> some View {
        if model.isPreparingExternalScene(wallpaper) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.localizedString("変換中…"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if let progress = model.sceneBakeProgress[wallpaper.path] {
                    ProgressView(value: progress)
                        .controlSize(.small)
                }
            }
        } else if model.didFailToPrepareExternalScene(wallpaper) {
            Text(model.localizedString("変換できませんでした"))
                .font(.caption2)
                .foregroundColor(.red)
        }
    }
}

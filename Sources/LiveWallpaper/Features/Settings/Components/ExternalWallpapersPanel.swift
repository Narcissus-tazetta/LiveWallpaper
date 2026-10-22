import SwiftUI

extension SettingsView {
    /// Shown only while a provider app offers wallpapers, so the library looks the same
    /// as always when none is running.
    var externalWallpapersPanel: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .foregroundColor(.accentColor)
                .font(.system(size: 14))

            if let active = model.activeExternalWallpaper {
                HStack(spacing: 6) {
                    Text(model.localizedString("外部アプリの壁紙を適用中:"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(active.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(model.localizedString("元の壁紙に戻す")) {
                    model.stopExternalWallpaper()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                HStack(spacing: 4) {
                    Text(model.localizedString("外部アプリの壁紙:"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(String.localizedStringWithFormat(model.localizedString("%d件"), model.externalWallpapers.count))
                        .font(.subheadline.weight(.medium))
                    if !providerNames.isEmpty {
                        Text("(\(providerNames))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 8)
            }

            Button {
                selectedTab = .store
                storeTabMode = .external
            } label: {
                HStack(spacing: 4) {
                    Text(model.localizedString("Storeで確認"))
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .foregroundColor(.accentColor)
        }
    }

    /// Every card would repeat the same provider, so it is named once by the title.
    private var providerNames: String {
        var seen = Set<String>()
        return model.externalWallpapers.map(\.providerName)
            .filter { seen.insert($0).inserted }
            .joined(separator: model.localizedString("・"))
    }

    /// A scene is baked into a video before it can be shown; nothing for videos.
    @ViewBuilder
    func externalScenePreparationStatus(_ wallpaper: ExternalWallpaper) -> some View {
        if model.didFailToPrepareExternalScene(wallpaper) {
            Text(model.localizedString("変換できませんでした"))
                .font(.caption2)
                .foregroundColor(.red)
        } else if !model.isExternalWallpaperReady(wallpaper) {
            VStack(alignment: .leading, spacing: 4) {
                ExternalScenePreparationProgress(model: model, progress: model.sceneBakeProgressStore, path: wallpaper.path)
                Text(model.localizedString("バックグラウンドで準備しています。完了すると追加できます。"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption2)
            .foregroundColor(.secondary)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Observes the progress alone, so its updates redraw this row and not the settings window.
private struct ExternalScenePreparationProgress: View {
    let model: WallpaperModel
    @ObservedObject var progress: SceneBakeProgress
    let path: String

    var body: some View {
        HStack(spacing: 4) {
            if let value = progress.values[path] {
                Text(model.localizedString("変換中…"))
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            } else {
                ProgressView().controlSize(.mini)
                Text(model.localizedString("準備中…"))
            }
        }
        if let value = progress.values[path] {
            ProgressView(value: value).controlSize(.small)
        }
    }
}

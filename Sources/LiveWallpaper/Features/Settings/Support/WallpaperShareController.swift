import AppKit
import SwiftUI

/// The picker sheet for sharing one wallpaper, and the share entry points of the
/// settings window. The export itself runs in ShareExportController.
extension SettingsView {
    func beginShareWallpaperSelection(path: String) {
        isWallpaperShareSheetPresented = false
        DispatchQueue.main.async {
            shareWallpaper(path: path)
        }
    }

    var shareWallpaperPickerSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.localizedString("共有する壁紙を選択"))
                        .font(.system(size: 18, weight: .semibold))
                    Text(shareWallpaperPickerDescriptionText())
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 0)

                Button(model.localizedString("ライブラリ全体を書き出す…")) {
                    isWallpaperShareSheetPresented = false
                    let selection = PackageSelection.library(of: model)
                    DispatchQueue.main.async {
                        ShareExportController.shared.savePackage(
                            selection: selection,
                            model: model
                        )
                    }
                }
                .buttonStyle(.bordered)
                .help(model.localizedString("すべての壁紙・Web壁紙・プレイリスト・自分のプリセットを1つの .lwpkg にまとめます"))

                Button(model.localizedString("閉じる")) {
                    isWallpaperShareSheetPresented = false
                }
                .buttonStyle(.bordered)
            }

            if model.allRegisteredVideoPaths.isEmpty {
                Text(model.localizedString("共有できる壁紙がありません"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                GeometryReader { proxy in
                    let layout = wallpaperGridLayout(for: proxy.size.width)
                    ScrollView {
                        LazyVGrid(
                            columns: layout.0,
                            alignment: .leading,
                            spacing: wallpaperGridRowSpacing
                        ) {
                            ForEach(model.allRegisteredVideoPaths, id: \.self) { path in
                                shareWallpaperSelectionCard(path: path, cardWidth: layout.1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                }
                .frame(minHeight: 280, maxHeight: 520)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 460)
    }

    func shareWallpaperSelectionCard(path: String, cardWidth: CGFloat) -> some View {
        Button {
            beginShareWallpaperSelection(path: path)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    if let image = thumbnailCache.image(for: path) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle().fill(Color.secondary.opacity(0.15))
                        Image(systemName: "film")
                            .font(.system(size: 18))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: max(cardWidth - 8, 1), height: 60)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(model.registeredVideoDisplayName(for: path))
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 10, weight: .semibold))
                    Text(model.localizedString("共有"))
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(.secondary)
            }
            .padding(4)
            .frame(width: cardWidth, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }

    func shareWallpaper(path: String) {
        ShareExportController.shared.share(
            title: model.registeredVideoDisplayName(for: path),
            model: model
        ) { folder, progress in
            try await PackageExporter().exportSingleWallpaper(
                model: model,
                videoPath: path,
                outputFolderURL: folder,
                includePackage: model.advancedSharingEnabled,
                progress: progress
            )
        }
    }

    func sharePackage(_ selection: PackageSelection) {
        ShareExportController.shared.sharePackage(selection, model: model)
    }

    func shareWallpaperPickerDescriptionText() -> String {
        if model.advancedSharingEnabled {
            return model.localizedString("選ぶと macOS の共有シートを開き、動画ファイルと .lwpkg を共有できます")
        }
        return model.localizedString("選ぶと macOS の共有シートを開き、動画ファイルを共有できます")
    }
}

import AppKit
import SwiftUI

/// 壁紙を macOS の共有シート経由でエクスポート/共有する機能。
/// 一時フォルダの用意・古い共有フォルダの掃除・NSSharingServicePicker の
/// 提示までを担う。汎用の SwiftUI ヘルパー(Support/Helpers.swift)とは
/// 別関心事のため独立したファイルに分けている。
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
        Task { @MainActor in
            do {
                let shareFolderURL = try prepareWallpaperShareFolder()
                let exporter = PackageExporter()
                let shareURLs = try await exporter.exportSingleWallpaper(
                    model: model,
                    videoPath: path,
                    outputFolderURL: shareFolderURL,
                    includePackage: model.advancedSharingEnabled
                )
                presentWallpaperSharePicker(for: shareURLs)
            } catch {
                showShareFailureAlert(message: error.localizedDescription)
            }
        }
    }

    func shareWallpaperPickerDescriptionText() -> String {
        if model.advancedSharingEnabled {
            return model.localizedString("選ぶと macOS の共有シートを開き、動画ファイルと .lwpkg を共有できます")
        }
        return model.localizedString("選ぶと macOS の共有シートを開き、動画ファイルを共有できます")
    }

    func prepareWallpaperShareFolder() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LiveWallpaperShares",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        cleanupOldWallpaperShareFolders(in: rootURL)

        let shareFolderURL = rootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: shareFolderURL, withIntermediateDirectories: true)
        return shareFolderURL
    }

    func cleanupOldWallpaperShareFolders(in rootURL: URL) {
        guard let folderURLs = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let expirationDate = Date().addingTimeInterval(-24 * 60 * 60)
        for folderURL in folderURLs {
            let values = try? folderURL.resourceValues(forKeys: [.creationDateKey])
            if values?.creationDate ?? .distantPast < expirationDate {
                try? FileManager.default.removeItem(at: folderURL)
            }
        }
    }

    func presentWallpaperSharePicker(for urls: [URL]) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let view = window.contentView
        else {
            let alert = NSAlert()
            alert.messageText = model.localizedString("共有に失敗しました")
            alert.informativeText = model.localizedString("共有シートを開けませんでした")
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        let picker = NSSharingServicePicker(items: urls)
        picker.show(relativeTo: sharePickerAnchorRect(in: view, window: window), of: view, preferredEdge: .maxY)
    }

    func sharePickerAnchorRect(in view: NSView, window: NSWindow) -> NSRect {
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let viewPoint = view.convert(windowPoint, from: nil)
        let fallbackPoint = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        let anchorPoint = view.bounds.contains(viewPoint) ? viewPoint : fallbackPoint
        return NSRect(x: anchorPoint.x, y: anchorPoint.y, width: 1, height: 1)
    }

    func showShareFailureAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = model.localizedString("共有に失敗しました")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

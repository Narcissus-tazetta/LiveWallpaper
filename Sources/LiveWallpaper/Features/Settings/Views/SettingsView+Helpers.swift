import AppKit
import SwiftUI

extension SettingsView {
    func tabButton(_ tab: SettingsTab, title: String, systemImage: String) -> some View {
        Button {
            selectedTab = tab
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .frame(minWidth: 130)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(selectedTab == tab ? Color.accentColor : Color.clear)
                )
                .foregroundColor(selectedTab == tab ? Color.white : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func compactToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .fixedSize()
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    func syncVolumeInputWithModel() {
        let percent = Int((model.audioVolume * 100).rounded())
        volumeInput = String(percent)
    }

    func commitVolumeInput() {
        guard !volumeInput.isEmpty else {
            syncVolumeInputWithModel()
            return
        }
        let percent = min(max(Int(volumeInput) ?? 0, 0), 100)
        model.setAudioVolume(Float(percent) / 100)
        volumeInput = String(percent)
    }

    func currentWallpaperSummaryText() -> String {
        guard let currentPath = model.currentVideoPath else {
            return model.allRegisteredVideoPaths.isEmpty
                ? model.localizedString("未登録")
                : model.localizedString("未再生")
        }
        return model.registeredVideoDisplayName(for: currentPath)
    }

    func currentPlaylistSummaryText() -> String {
        guard !model.playlists.isEmpty else {
            return model.localizedString("未作成")
        }
        return model.selectedPlaylistName
    }

    func currentDisplayModeSummaryText() -> String {
        switch model.displayMode {
        case .mainOnly:
            return model.localizedString("メインのみ")
        case .allScreens:
            return model.localizedString("全ディスプレイ")
        }
    }

    func currentWallpaperPreviewImage() -> NSImage? {
        guard let currentPath = model.currentVideoPath else {
            return nil
        }
        return thumbnailCache.image(for: currentPath)
    }

    func requestCurrentWallpaperThumbnailIfNeeded() {
        guard let currentPath = model.currentVideoPath else {
            return
        }
        requestWallpaperThumbnail(path: currentPath)
    }

    @ViewBuilder
    var currentWallpaperPreview: some View {
        let image = currentWallpaperPreviewImage()

        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 122, height: 70)
                    .clipped()
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                        .font(.system(size: 18, weight: .medium))
                    Text(model.localizedString("プレビューなし"))
                        .font(.caption2)
                }
                .foregroundColor(.secondary)
            }
        }
        .frame(width: 122, height: 70)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .accessibilityLabel(model.localizedString("現在の壁紙プレビュー"))
    }

    func toggleHelp(_ topic: HelpTopic) {
        if expandedHelpTopics.contains(topic) {
            expandedHelpTopics.remove(topic)
        } else {
            expandedHelpTopics.insert(topic)
        }
    }

    func selectAppForSuspendExclusion() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [.applicationBundle]
        } else {
            panel.allowedFileTypes = ["app"]
        }
        panel.allowsOtherFileTypes = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = model.localizedString("追加")

        if panel.runModal() == .OK,
           let url = panel.url
        {
            _ = model.addSuspendExclusionFromAppURL(url)
        }
    }

    func beginShareWallpaperSelection(path: String) {
        isWallpaperShareSheetPresented = false
        DispatchQueue.main.async {
            shareWallpaper(path: path)
        }
    }

    @ViewBuilder
    var shareWallpaperPickerSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.localizedString("共有する壁紙を選択"))
                        .font(.system(size: 18, weight: .semibold))
                    Text(model.localizedString("選ぶと保存先フォルダを指定して、.lwpkg と .mov を出力します"))
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
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = model.localizedString("共有")
        panel.message = model.localizedString("壁紙を保存するフォルダを選択してください")

        if panel.runModal() == .OK,
           let folderURL = panel.url
        {
            Task {
                do {
                    let exporter = PackageExporter()
                    try await exporter.exportSingleWallpaper(
                        model: model,
                        videoPath: path,
                        outputFolderURL: folderURL
                    )
                } catch {
                    let alert = NSAlert()
                    alert.messageText = model.localizedString("共有に失敗しました")
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }
}

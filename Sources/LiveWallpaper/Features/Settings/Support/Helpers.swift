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
        if model.isWebWallpaperActive, let source = model.activeWebWallpaperSource {
            return source.displayName
        }
        guard let currentPath = model.currentVideoPath else {
            return model.allRegisteredVideoPaths.isEmpty
                ? model.localizedString("未登録")
                : model.localizedString("未再生")
        }
        return model.registeredVideoDisplayName(for: currentPath)
    }

    func currentLockScreenWallpaperSummaryText() -> String {
        guard model.lockScreenSyncService.isSupported else {
            return model.localizedString("未対応")
        }
        guard let lockScreenPath = model.lockScreenVideoPath else {
            return model.localizedString("未設定")
        }
        return model.registeredVideoDisplayName(for: lockScreenPath)
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

    func lockScreenWallpaperPreviewImage() -> NSImage? {
        guard let lockScreenPath = model.lockScreenVideoPath else {
            return nil
        }
        return thumbnailCache.image(for: lockScreenPath)
    }

    func requestCurrentWallpaperThumbnailIfNeeded() {
        guard let currentPath = model.currentVideoPath else {
            releaseCurrentWallpaperThumbnailVisibility()
            return
        }
        if let previousPath = currentWallpaperPreviewThumbnailPath,
           previousPath != currentPath
        {
            setThumbnailVisibility(path: previousPath, isVisible: false)
        }
        currentWallpaperPreviewThumbnailPath = currentPath
        setThumbnailVisibility(path: currentPath, isVisible: true)
        requestWallpaperThumbnail(path: currentPath)
    }

    func releaseCurrentWallpaperThumbnailVisibility() {
        guard let currentWallpaperPreviewThumbnailPath else {
            return
        }
        setThumbnailVisibility(path: currentWallpaperPreviewThumbnailPath, isVisible: false)
        self.currentWallpaperPreviewThumbnailPath = nil
    }

    func requestLockScreenWallpaperThumbnailIfNeeded() {
        guard let lockScreenPath = model.lockScreenVideoPath else {
            releaseLockScreenWallpaperThumbnailVisibility()
            return
        }
        if let previousPath = currentLockScreenPreviewThumbnailPath,
           previousPath != lockScreenPath
        {
            setThumbnailVisibility(path: previousPath, isVisible: false)
        }
        currentLockScreenPreviewThumbnailPath = lockScreenPath
        setThumbnailVisibility(path: lockScreenPath, isVisible: true)
        requestWallpaperThumbnail(path: lockScreenPath)
    }

    func releaseLockScreenWallpaperThumbnailVisibility() {
        guard let currentLockScreenPreviewThumbnailPath else {
            return
        }
        setThumbnailVisibility(path: currentLockScreenPreviewThumbnailPath, isVisible: false)
        self.currentLockScreenPreviewThumbnailPath = nil
    }

    @ViewBuilder
    var desktopWallpaperPreview: some View {
        if model.isWebWallpaperActive, let source = model.activeWebWallpaperSource {
            WebWallpaperThumbnailView(
                source: source,
                isActive: true,
                thumbnailStore: webThumbnailStore,
                width: 88,
                height: 50
            )
            .accessibilityLabel(model.localizedString("現在の壁紙プレビュー"))
        } else {
            wallpaperPreviewThumbnail(
                image: currentWallpaperPreviewImage(),
                accessibilityLabel: model.localizedString("現在の壁紙プレビュー")
            )
        }
    }

    @ViewBuilder
    var lockScreenWallpaperPreview: some View {
        wallpaperPreviewThumbnail(
            image: lockScreenWallpaperPreviewImage(),
            accessibilityLabel: model.localizedString("ロック画面壁紙プレビュー")
        )
    }

    @ViewBuilder
    func wallpaperPreviewThumbnail(image: NSImage?, accessibilityLabel: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    var currentWallpaperPreview: some View {
        desktopWallpaperPreview
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

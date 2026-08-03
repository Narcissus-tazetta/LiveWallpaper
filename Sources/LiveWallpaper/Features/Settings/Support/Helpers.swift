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
                .foregroundColor(
                    selectedTab == tab ? selectedTabForegroundColor : Color.primary
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedTab == tab ? [.isSelected] : [])
    }

    /// White text on the accent-color fill above reads fine for the default
    /// blue/purple/red accents, but macOS also offers light accents (Yellow,
    /// Green) where white loses contrast. Picking black vs. white by the
    /// accent color's own luminance keeps this readable under every system
    /// accent color choice instead of assuming it's always dark.
    private var selectedTabForegroundColor: Color {
        guard let rgb = NSColor(Color.accentColor).usingColorSpace(.deviceRGB) else {
            return .white
        }
        let luminance =
            0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.6 ? .black : .white
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

    /// プレイリスト編集中に名前行へ出すチェックボックスの汎用実装。ON=そのプレイリストに含まれる。
    /// 動画カード・Web壁紙カードの両方から、対象に応じたクロージャを渡して使う。
    func membershipCheckbox(
        isOn: @escaping () -> Bool,
        setOn: @escaping (Bool) -> Void
    ) -> some View {
        Toggle("", isOn: Binding(get: isOn, set: setOn))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .controlSize(.small)
            .help(model.localizedString("チェックでこのプレイリストに追加・解除"))
    }

    /// 「プレイリストに追加…/から外す…」コンテキストメニューの汎用実装。
    /// 動画カード・Web壁紙カードの両方から、対象に応じたクロージャを渡して使う。
    @ViewBuilder
    func playlistMembershipMenus(
        isContained: @escaping (WallpaperPlaylist) -> Bool,
        add: @escaping (UUID) -> Void,
        remove: @escaping (UUID) -> Void,
        addToNewPlaylist: @escaping () -> Void
    ) -> some View {
        Menu(model.localizedString("プレイリストに追加…")) {
            if model.playlists.isEmpty {
                Button(model.localizedString("新規プレイリストを作成して追加")) {
                    addToNewPlaylist()
                }
                .disabled(!model.canAddPlaylist)
            } else {
                ForEach(model.playlists) { playlist in
                    Button(playlist.name) {
                        add(playlist.id)
                    }
                    .disabled(isContained(playlist))
                }
                Divider()
                Button(model.localizedString("新規プレイリストを作成して追加")) {
                    addToNewPlaylist()
                }
                .disabled(!model.canAddPlaylist)
            }
        }
        let containingPlaylists = model.playlists.filter(isContained)
        if !containingPlaylists.isEmpty {
            Menu(model.localizedString("プレイリストから外す…")) {
                ForEach(containingPlaylists) { playlist in
                    Button(playlist.name) {
                        remove(playlist.id)
                    }
                }
            }
        }
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
            // statusWallpaperSlot constrains this preview to a 72x40 box; the
            // thumbnail's own width/height must match or it renders larger
            // than that box and overflows uncropped (no .clipped() here).
            WebWallpaperThumbnailView(
                source: source,
                isActive: true,
                thumbnailStore: webThumbnailStore,
                width: 72,
                height: 40
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

    func helpIconButton(for topic: HelpTopic) -> some View {
        Button(action: { toggleHelp(topic) }) {
            Image(
                systemName: expandedHelpTopics.contains(topic) || hoveredHelpTopic == topic
                    ? "questionmark.circle.fill"
                    : "questionmark.circle"
            )
        }
        .buttonStyle(.plain)
        .onHover { over in
            hoveredHelpTopic = over ? topic : nil
        }
    }

    @ViewBuilder
    func helpFootnote(for topic: HelpTopic, text: String) -> some View {
        if expandedHelpTopics.contains(topic) {
            settingsFootnote(text)
        }
    }

    /// トグル本体とヘルプアイコン、展開時の説明文をまとめた行。
    /// 「Toggle + はてなアイコン + 折りたたみ説明」が表示セクション全体で
    /// 繰り返し登場するため、ここに集約している。
    func toggleWithHelp(
        _ title: String,
        isOn: Binding<Bool>,
        helpTopic: HelpTopic,
        helpText: String,
        disabled: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: isOn) {
                HStack(spacing: 6) {
                    Text(title)
                    helpIconButton(for: helpTopic)
                }
            }
            .disabled(disabled)

            helpFootnote(for: helpTopic, text: helpText)
        }
    }

    func settingsFootnote(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(color)
            .frame(maxWidth: .infinity, alignment: .leading)
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

}

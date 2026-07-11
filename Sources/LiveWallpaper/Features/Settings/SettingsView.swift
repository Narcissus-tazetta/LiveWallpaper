import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: WallpaperModel
    @State var selectedTab: SettingsTab = .wallpaper
    @State var isAdvancedExpanded: Bool = false
    @State var volumeInput: String = ""
    @State var expandedHelpTopics: Set<HelpTopic> = []
    @State var hoveredHelpTopic: HelpTopic?
    @StateObject var thumbnailCache: DiskThumbnailCache
    @StateObject var webThumbnailStore: WebWallpaperThumbnailStore
    @State var editingPlaylistID: UUID?
    @State var editingPlaylistNameInput: String = ""
    @State var editingWallpaperPath: String?
    @State var editingWallpaperNameInput: String = ""
    @State var isDropTargeted: Bool = false
    @State var selectedAssignmentTarget: WallpaperAssignmentTarget = .desktop
    /// 「デスクトップ」タブが共有壁紙ではなく特定ディスプレイの割り当てを
    /// 表示している場合の画面ID。接続が切れた画面は resolvedDisplayOverrideScreenID
    /// 側で自動的に無視される。
    @State var selectedDisplayOverrideScreenID: String?
    @StateObject var fitEditor: FitEditorController
    @State var isResetSettingsDialogPresented: Bool = false
    @State var librarySearchText: String = ""
    @State var isWallpaperShareSheetPresented: Bool = false
    @State var isSuspendExclusionAppPickerPresented: Bool = false
    @State var suspendExclusionAppPickerSearchText: String = ""
    @State var currentWallpaperPreviewThumbnailPath: String?
    @State var currentLockScreenPreviewThumbnailPath: String?
    @State var webURLInput: String = ""
    @State var isWebWallpaperURLPopoverPresented: Bool = false
    @State var editingWebWallpaperID: UUID?
    @State var editingWebWallpaperNameInput: String = ""
    @FocusState var isVolumeInputFocused: Bool
    @FocusState var focusedPlaylistID: UUID?
    @FocusState var focusedWallpaperPath: String?
    @FocusState var focusedWebWallpaperID: UUID?
    @State var isLibrarySearchFocused: Bool = false
    @State var settingsSearchText: String = ""
    @State var isSettingsSearchFocused: Bool = false
    let wallpaperCardMinimumWidth: CGFloat = 140
    let wallpaperCardMaximumWidth: CGFloat = 220
    let wallpaperGridColumnSpacing: CGFloat = 6
    let wallpaperGridRowSpacing: CGFloat = 12

    init(model: WallpaperModel) {
        self.model = model
        _thumbnailCache = StateObject(wrappedValue: DiskThumbnailCache())
        _webThumbnailStore = StateObject(wrappedValue: WebWallpaperThumbnailStore())
        _fitEditor = StateObject(wrappedValue: FitEditorController(model: model))
    }

    func wallpaperGridLayout(for availableWidth: CGFloat) -> ([GridItem], CGFloat) {
        let width = max(availableWidth, wallpaperCardMinimumWidth)
        let rawCount = Int(
            (width + wallpaperGridColumnSpacing)
                / (wallpaperCardMinimumWidth + wallpaperGridColumnSpacing)
        )
        let columnCount = max(rawCount, 1)
        let totalSpacing = wallpaperGridColumnSpacing * CGFloat(columnCount - 1)
        let computedWidth = floor((width - totalSpacing) / CGFloat(columnCount))
        let cardWidth = min(
            max(computedWidth, wallpaperCardMinimumWidth),
            wallpaperCardMaximumWidth
        )
        let columns = Array(
            repeating: GridItem(.fixed(cardWidth), spacing: wallpaperGridColumnSpacing),
            count: columnCount
        )
        return (columns, cardWidth)
    }

    var body: some View {
        // タブバーはコンテンツの Form とは別の(スクロール無効な)Form として描画する。
        // 同じ grouped スタイルを使うことで横幅・インセットが本文のセクションと揃い、
        // かつコンテンツをスクロールしてもタブバーは常に見える。
        let content = VStack(spacing: 0) {
            Form {
                tabBarSection
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            // grouped Form の上マージン(約20pt) + タブバー行(72pt+行パディング)が
            // 収まる高さ。小さすぎるとタブバーが下に見切れる。
            .frame(height: 112)

            Form {
                tabContentSection

                footerSection
            }
            .formStyle(.grouped)
        }

        let modified1 = applyMainModifiers(content)
        let modified2 = applyNotificationAndChangeModifiers(modified1)
        let modified3 = applyLifecycleModifiers(modified2)
        return applyDialogAndSheetModifiers(modified3)
    }

    private func applyMainModifiers<V: View>(_ view: V) -> some View {
        view
            .font(.system(size: 14, weight: .medium))
            .tint(.accentColor)
            .frame(
                minWidth: 780, idealWidth: 780, maxWidth: .infinity,
                minHeight: 540, idealHeight: 540, maxHeight: .infinity
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDroppedVideoProviders(providers)
            }
            .background(InitialFocusSink().frame(width: 0, height: 0))
    }

    private func applyNotificationAndChangeModifiers<V: View>(_ view: V) -> some View {
        view
            .onChange(of: model.webWallpaperSources) { sources in
                webThumbnailStore.prune(validSourceIDs: Set(sources.map(\.id)))
                if let editingID = editingWebWallpaperID,
                   !sources.contains(where: { $0.id == editingID })
                {
                    cancelWebWallpaperNameEdit()
                }
            }
            .onChange(of: model.audioVolume) { _ in
                if !isVolumeInputFocused {
                    syncVolumeInputWithModel()
                }
            }
            .onChange(of: model.registeredVideoPaths) { _ in
                pruneMissingWallpaperThumbnails()
            }
            .onChange(of: model.playlists) { _ in
                pruneMissingWallpaperThumbnails()
                guard let editingID = editingPlaylistID else {
                    return
                }
                if !model.playlists.contains(where: { $0.id == editingID }) {
                    cancelPlaylistNameEdit()
                }
            }
            .onChange(of: model.selectedPlaylistID) { _ in
                resetLibrarySearchState()
            }
            .onChange(of: isVolumeInputFocused) { focused in
                if !focused {
                    commitVolumeInput()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openWallpaperTab)) { _ in
                selectedTab = .wallpaper
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsTab)) { _ in
                selectedTab = .settings
            }
            .onReceive(NotificationCenter.default.publisher(for: .openWallpaperFitTab)) { _ in
                selectedTab = .wallpaperFit
            }
            .onReceive(NotificationCenter.default.publisher(for: .openWallpaperShareSheet)) { _ in
                selectedTab = .wallpaper
                isWallpaperShareSheetPresented = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .thumbnailCacheDidClear)) { _ in
                thumbnailCache.clear()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.refreshDesktopIconsVisibility()
                model.refreshScreenRecordingTrustForCoverage()
            }
            .onChange(of: selectedTab) { tab in
                resetLibrarySearchState()
                settingsSearchText = ""
                isSettingsSearchFocused = false
                if tab == .settings {
                    model.refreshDesktopIconsVisibility()
                }
                if tab == .wallpaperFit {
                    fitEditor.activate()
                } else {
                    fitEditor.deactivate()
                }
            }
            .onChange(of: model.lockScreenVideoPath) { _ in
                requestLockScreenWallpaperThumbnailIfNeeded()
            }
            .onChange(of: model.currentVideoPath) { _ in
                requestCurrentWallpaperThumbnailIfNeeded()
                fitEditor.handleCurrentVideoPathChange()
            }
            .onChange(of: model.currentWebWallpaperID) { _ in
                if let source = model.activeWebWallpaperSource {
                    webThumbnailStore.loadIfNeeded(for: source)
                }
            }
    }

    private func applyLifecycleModifiers<V: View>(_ view: V) -> some View {
        view
            .onAppear {
                syncVolumeInputWithModel()
                pruneMissingWallpaperThumbnails()
                requestCurrentWallpaperThumbnailIfNeeded()
                requestLockScreenWallpaperThumbnailIfNeeded()
                model.refreshScreenRecordingTrustForCoverage()
                thumbnailCache.prewarm(paths: Array(model.allRegisteredVideoPaths.prefix(10)))
                processThumbnailQueue()
                if selectedTab == .wallpaperFit {
                    fitEditor.activate()
                }
            }
            .onDisappear {
                releaseCurrentWallpaperThumbnailVisibility()
                releaseLockScreenWallpaperThumbnailVisibility()
                fitEditor.deactivate()
            }
    }

    private func applyDialogAndSheetModifiers<V: View>(_ view: V) -> some View {
        view
            .sheet(isPresented: $isWallpaperShareSheetPresented) {
                shareWallpaperPickerSheet
            }
            .confirmationDialog(
                model.localizedString("設定を初期化"),
                isPresented: $isResetSettingsDialogPresented,
                titleVisibility: .visible
            ) {
                Button(model.localizedString("リセット"), role: .destructive) {
                    model.resetSettingsToDefaults()
                    syncVolumeInputWithModel()
                }
                Button(model.localizedString("キャンセル"), role: .cancel) {}
            } message: {
                Text(model.localizedString("表示・再生に関する設定を初期値へ戻します"))
            }
    }

    private var tabBarSection: some View {
        Section {
            HStack(spacing: 10) {
                tabButton(
                    .wallpaper,
                    title: model.localizedString("壁紙"),
                    systemImage: "photo.on.rectangle"
                )
                tabButton(
                    .wallpaperFit,
                    title: model.localizedString("配置"),
                    systemImage: "viewfinder"
                )
                tabButton(
                    .settings,
                    title: model.localizedString("設定"),
                    systemImage: "gearshape"
                )
                Spacer(minLength: 0)

                if selectedTab == .settings {
                    settingsSearchField
                }
            }
            .padding(8)
            .frame(minHeight: 72)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.12))
            )
        }
    }

    @ViewBuilder
    private var tabContentSection: some View {
        switch selectedTab {
        case .wallpaper:
            WallpaperTabView(title: model.localizedString("壁紙")) {
                VStack(alignment: .leading, spacing: 12) {
                    wallpaperTargetTabBar
                    wallpaperContentPane
                }
            }
        case .wallpaperFit:
            WallpaperFitTabView(title: model.localizedString("配置")) {
                wallpaperFitEditorPanel
            } library: {
                wallpaperFitLibraryPanel
            }
        case .settings:
            SettingsTabView {
                Group {
                    if let message = model.persistenceFailureMessage {
                        Section {
                            Text(message)
                                .font(.caption)
                                .foregroundColor(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if settingsSectionMatches(.video) {
                        videoSettingsSection
                    }
                    if settingsSectionMatches(.share) {
                        shareSettingsSection
                    }
                    if settingsSectionMatches(.webWallpaper) {
                        webWallpaperSettingsSection
                    }
                    if settingsSectionMatches(.display) {
                        displaySettingsSection
                    }
                    if settingsSectionMatches(.language) {
                        languageSettingsSection
                    }
                    if settingsSectionMatches(.cache) {
                        cacheSettingsSection
                    }
                }
                Group {
                    if settingsSectionMatches(.reset) {
                        resetSettingsSection
                    }
                    if settingsSectionMatches(.update) {
                        updateSettingsSection
                    }
                    if isSettingsSearchActive, !anySettingsSectionMatches {
                        Section {
                            Text(model.localizedString("該当する設定がありません"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private var footerSection: some View {
        Section {
            footerCreditText
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var footerCreditText: Text {
        var authorName = AttributedString("Narcissus-tazetta")
        authorName.link = URL(string: "https://github.com/Narcissus-tazetta/LiveWallpaper")
        authorName.foregroundColor = .secondary
        let year = String(Calendar.current.component(.year, from: Date()))
        return Text("©︎") + Text(authorName) + Text(" \(year)  •  v\(model.currentAppVersion())")
    }
}

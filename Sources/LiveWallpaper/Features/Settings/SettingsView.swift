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
    @State var editingPlaylistID: UUID?
    @State var editingPlaylistNameInput: String = ""
    @State var editingWallpaperPath: String?
    @State var editingWallpaperNameInput: String = ""
    @State var pendingDroppedVideoURL: URL?
    @State var isDropTargeted: Bool = false
    @State var isDropPlaylistDialogPresented: Bool = false
    @State var hoveredPlaylistDropTargetID: UUID?
    @State var isPlaylistSectionDropTargeted: Bool = false
    @State var selectedFitScreenID: String = ""
    @State var fitEditorDraftPath: String = ""
    @State var fitEditorDraftScreenID: String = ""
    @State var fitEditorDraftFitMode: VideoFitMode = .fill
    @State var fitEditorDraftZoom: Double = 1.0
    @State var fitEditorDraftOffsetX: Double = 0.0
    @State var fitEditorDraftOffsetY: Double = 0.0
    @State var fitEditorSelectedVideoPath: String?
    @State var isFitEditorInteractionEnabled: Bool = false
    @State var fitPreviewMode: FitPreviewMode = .still
    @State var fitPreviewStillImages: [String: NSImage] = [:]
    @State var fitPreviewStillImageInFlight: Set<String> = []
    @State var fitEditorPreviewFrameSize: CGSize = .zero
    @State var isResetSettingsDialogPresented: Bool = false
    @State var isWallpaperShareSheetPresented: Bool = false
    @State var keyEventMonitor: Any?
    @FocusState var isVolumeInputFocused: Bool
    @FocusState var focusedPlaylistID: UUID?
    @FocusState var focusedWallpaperPath: String?
    let wallpaperCardMinimumWidth: CGFloat = 140
    let wallpaperCardMaximumWidth: CGFloat = 220
    let wallpaperGridColumnSpacing: CGFloat = 6
    let wallpaperGridRowSpacing: CGFloat = 12

    init(model: WallpaperModel) {
        self.model = model
        _thumbnailCache = StateObject(wrappedValue: DiskThumbnailCache())
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

    private var pendingDroppedVideoName: String {
        pendingDroppedVideoURL?.lastPathComponent ?? ""
    }

    var currentStatusSection: some View {
        Section {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.localizedString("現在の壁紙")): \(currentWallpaperSummaryText())")
                    Text("\(model.localizedString("プレイリスト")): \(currentPlaylistSummaryText())")
                    Text("\(model.localizedString("表示")): \(currentDisplayModeSummaryText())")
                }
                .font(.caption)
                .foregroundColor(.secondary)

                Spacer(minLength: 0)

                currentWallpaperPreview
            }
        }
    }

    var body: some View {
        let form = Form {
            tabBarSection

            currentStatusSection

            tabContentSection

            footerSection
        }

        let modified1 = applyMainModifiers(form)
        let modified2 = applyNotificationAndChangeModifiers(modified1)
        let modified3 = applyLifecycleModifiers(modified2)
        return applyDialogAndSheetModifiers(modified3)
    }

    private func applyMainModifiers<V: View>(_ view: V) -> some View {
        view
            .onTapGesture {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            .font(.system(size: 14, weight: .medium))
            .tint(.accentColor)
            .formStyle(.grouped)
            .frame(minWidth: 760, idealWidth: 760, minHeight: 460, idealHeight: 460)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDroppedVideoProviders(providers)
            }
    }

    private func applyNotificationAndChangeModifiers<V: View>(_ view: V) -> some View {
        view
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
            .onChange(of: selectedTab) { tab in
                if tab == .wallpaperFit {
                    ensureFitEditorScreenSelection()
                    syncFitEditorSelectionWithCurrentVideoIfNeeded()
                    syncFitEditorDraftWithCurrentSelection()
                    isFitEditorInteractionEnabled = false
                    installFitKeyMonitorIfNeeded()
                } else {
                    removeFitKeyMonitor()
                }
            }
            .onChange(of: model.currentVideoPath) { _ in
                requestCurrentWallpaperThumbnailIfNeeded()
                if fitEditorSelectedVideoPath == nil {
                    syncFitEditorSelectionWithCurrentVideoIfNeeded()
                }
                syncFitEditorDraftWithCurrentSelection()
                prepareFitPreviewStillImageIfNeeded()
            }
            .onChange(of: selectedFitScreenID) { _ in
                syncFitEditorDraftWithCurrentSelection()
            }
            .onChange(of: fitPreviewMode) { _ in
                prepareFitPreviewStillImageIfNeeded()
            }
    }

    private func applyLifecycleModifiers<V: View>(_ view: V) -> some View {
        view
            .onAppear {
                syncVolumeInputWithModel()
                pruneMissingWallpaperThumbnails()
                requestCurrentWallpaperThumbnailIfNeeded()
                thumbnailCache.prewarm(paths: Array(model.allRegisteredVideoPaths.prefix(10)))
                processThumbnailQueue()
                ensureFitEditorScreenSelection()
                syncFitEditorSelectionWithCurrentVideoIfNeeded()
                syncFitEditorDraftWithCurrentSelection()
                prepareFitPreviewStillImageIfNeeded()
                installFitKeyMonitorIfNeeded()
            }
            .onDisappear {
                model.removeEmptyPlaylists()
                removeFitKeyMonitor()
            }
    }

    private func applyDialogAndSheetModifiers<V: View>(_ view: V) -> some View {
        view
            .sheet(isPresented: $isWallpaperShareSheetPresented) {
                shareWallpaperPickerSheet
            }
            .confirmationDialog(
                model.localizedString("追加先プレイリスト"),
                isPresented: $isDropPlaylistDialogPresented,
                titleVisibility: .visible
            ) {
                ForEach(model.playlists) { playlist in
                    Button(playlist.name) {
                        Task {
                            await applyDroppedVideo(to: playlist.id)
                        }
                    }
                }
                Button(model.localizedString("新規プレイリストを作成して追加")) {
                    Task {
                        await applyDroppedVideo(to: nil)
                    }
                }
                .disabled(!model.canAddPlaylist)
                Button(model.localizedString("キャンセル"), role: .cancel) {
                    pendingDroppedVideoURL = nil
                }
            } message: {
                Text(pendingDroppedVideoName)
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
                wallpaperLibraryPanel
            } playlist: {
                playlistSettingsPanel
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
                    videoSettingsSection
                    displaySettingsSection
                    languageSettingsSection
                    cacheSettingsSection
                }
                Group {
                    resetSettingsSection
                    updateSettingsSection
                }
            }
        }
    }

    private var footerSection: some View {
        Section {
            Text("©︎Narcissus-tazetta 2026  •  v\(model.currentAppVersion())")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

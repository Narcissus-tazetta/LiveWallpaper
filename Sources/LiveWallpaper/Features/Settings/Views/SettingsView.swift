import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    enum FitPreviewMode: String, CaseIterable {
        case video
        case still
    }

    enum SettingsTab: Hashable {
        case wallpaper
        case wallpaperFit
        case settings
    }

    enum HelpTopic: Hashable {
        case qualityPreset
        case workProfile
        case frameRate
        case decode
        case desktopLevel
        case fullScreenAuxiliary
    }

    @ObservedObject var model: WallpaperModel
    @State var selectedTab: SettingsTab = .settings
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

    @ViewBuilder
    var settingsTabSections: some View {
        if selectedTab == .settings {
            videoSettingsSection
            displaySettingsSection
            cacheSettingsSection
            resetSettingsSection
            updateSettingsSection
        }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    tabButton(.settings, title: "設定", systemImage: "gearshape")
                    tabButton(.wallpaper, title: "壁紙を変更", systemImage: "photo.on.rectangle")
                    tabButton(.wallpaperFit, title: "壁紙設定", systemImage: "viewfinder")
                    Spacer(minLength: 0)
                }
                .padding(8)
                .frame(minHeight: 72)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.secondary.opacity(0.12))
                )
            }

            if selectedTab == .wallpaper {
                Section(header: Label("壁紙を変更", systemImage: "photo.on.rectangle")) {
                    wallpaperLibraryPanel
                    playlistSettingsPanel
                }
            }

            if selectedTab == .wallpaperFit {
                Section(header: Label("壁紙設定", systemImage: "viewfinder")) {
                    wallpaperFitLibraryPanel
                    wallpaperFitEditorPanel
                }
            }

            settingsTabSections
            Section {
                Text("©︎Narcissus-tazetta 2026  •  v\(model.currentAppVersion())")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .font(.system(size: 14, weight: .medium))
        .tint(.accentColor)
        .formStyle(.grouped)
        .frame(minWidth: 760, idealWidth: 760, minHeight: 460, idealHeight: 460)
        .onAppear {
            syncVolumeInputWithModel()
            pruneMissingWallpaperThumbnails()
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
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDroppedVideoProviders(providers)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .confirmationDialog(
            "追加先プレイリスト",
            isPresented: $isDropPlaylistDialogPresented,
            titleVisibility: .visible
        ) {
            ForEach(model.playlists) { playlist in
                Button(playlist.name) {
                    applyDroppedVideo(to: playlist.id)
                }
            }
            Button("新規プレイリストを作成して追加") {
                applyDroppedVideo(to: nil)
            }
            .disabled(!model.canAddPlaylist)
            Button("キャンセル", role: .cancel) {
                pendingDroppedVideoURL = nil
            }
        } message: {
            Text(pendingDroppedVideoURL?.lastPathComponent ?? "")
        }
        .confirmationDialog(
            "設定を初期化",
            isPresented: $isResetSettingsDialogPresented,
            titleVisibility: .visible
        ) {
            Button("リセット", role: .destructive) {
                model.resetSettingsToDefaults()
                syncVolumeInputWithModel()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("表示・再生に関する設定を初期値へ戻します")
        }
    }
}

struct LeftDragCaptureView: NSViewRepresentable {
    var isEnabled: Bool = true
    var onActivate: (() -> Void)?
    var onDelta: (CGSize) -> Void
    var onScrollDelta: ((CGSize) -> Void)?
    var currentZoom: (() -> Double)?
    var onZoomChange: ((Double) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isEnabled: isEnabled,
            onActivate: onActivate,
            onDelta: onDelta,
            onScrollDelta: onScrollDelta,
            currentZoom: currentZoom,
            onZoomChange: onZoomChange
        )
    }

    func makeNSView(context: Context) -> LeftDragCaptureNSView {
        let view = LeftDragCaptureNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: LeftDragCaptureNSView, context: Context) {
        nsView.coordinator = context.coordinator
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onActivate = onActivate
        context.coordinator.currentZoom = currentZoom
        context.coordinator.onZoomChange = onZoomChange
    }

    final class Coordinator {
        var isEnabled: Bool
        var onActivate: (() -> Void)?
        var onDelta: (CGSize) -> Void
        var onScrollDelta: ((CGSize) -> Void)?
        var currentZoom: (() -> Double)?
        var onZoomChange: ((Double) -> Void)?
        var lastGestureMagnification: CGFloat = 0

        init(
            isEnabled: Bool = true,
            onActivate: (() -> Void)? = nil,
            onDelta: @escaping (CGSize) -> Void,
            onScrollDelta: ((CGSize) -> Void)? = nil,
            currentZoom: (() -> Double)? = nil,
            onZoomChange: ((Double) -> Void)? = nil
        ) {
            self.isEnabled = isEnabled
            self.onActivate = onActivate
            self.onDelta = onDelta
            self.onScrollDelta = onScrollDelta
            self.currentZoom = currentZoom
            self.onZoomChange = onZoomChange
        }

        func handleActivate() {
            onActivate?()
        }

        func handleDelta(_ delta: CGSize) {
            onDelta(delta)
        }

        func handleScrollDelta(_ delta: CGSize) {
            onScrollDelta?(delta)
        }

        func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
            guard isEnabled else {
                lastGestureMagnification = 0
                return
            }

            switch gesture.state {
            case .began:
                lastGestureMagnification = 0
            case .changed:
                let delta = gesture.magnification - lastGestureMagnification
                lastGestureMagnification = gesture.magnification
                let current = currentZoom?() ?? 1.0
                let multiplier = max(0.2, 1.0 + Double(delta))
                let nextZoom = min(max(current * multiplier, 1.0), 3.0)
                onZoomChange?(nextZoom)
            default:
                lastGestureMagnification = 0
            }
        }
    }
}

final class LeftDragCaptureNSView: NSView {
    weak var coordinator: LeftDragCaptureView.Coordinator?
    private lazy var dragGesture: NSPanGestureRecognizer = {
        let gesture = NSPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        gesture.buttonMask = 0x1
        return gesture
    }()

    private lazy var magnificationGesture: NSMagnificationGestureRecognizer = .init(
        target: self,
        action: #selector(handleMagnification(_:))
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addGestureRecognizer(dragGesture)
        addGestureRecognizer(magnificationGesture)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addGestureRecognizer(dragGesture)
        addGestureRecognizer(magnificationGesture)
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func scrollWheel(with event: NSEvent) {
        guard coordinator?.isEnabled == true else {
            nextResponder?.scrollWheel(with: event)
            return
        }

        var deltaX = event.scrollingDeltaX
        var deltaY = event.scrollingDeltaY

        if !event.hasPreciseScrollingDeltas {
            deltaX *= 10
            deltaY *= 10
        }

        if !event.isDirectionInvertedFromDevice {
            deltaX *= -1
            deltaY *= -1
        }

        coordinator?.handleScrollDelta(CGSize(width: deltaX, height: deltaY))
    }

    override func mouseDown(with event: NSEvent) {
        coordinator?.handleActivate()
        super.mouseDown(with: event)
    }

    @objc
    private func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
        coordinator?.handleMagnification(gesture)
    }

    @objc
    private func handleDrag(_ gesture: NSPanGestureRecognizer) {
        guard coordinator?.isEnabled == true else {
            gesture.setTranslation(.zero, in: self)
            return
        }

        switch gesture.state {
        case .began, .changed:
            let translation = gesture.translation(in: self)
            coordinator?.handleDelta(
                CGSize(width: translation.x, height: translation.y)
            )
            gesture.setTranslation(.zero, in: self)
        default:
            gesture.setTranslation(.zero, in: self)
        }
    }
}

extension Notification.Name {
    static let chooseVideo = Notification.Name("ChooseVideo")
    static let createPlaylistAndChooseVideo = Notification.Name("CreatePlaylistAndChooseVideo")
    static let openWallpaperTab = Notification.Name("OpenWallpaperTab")
    static let openWallpaperFitTab = Notification.Name("OpenWallpaperFitTab")
    static let openSettingsTab = Notification.Name("OpenSettingsTab")
    static let toggleLaunchAtLogin = Notification.Name("ToggleLaunchAtLogin")
    static let openCacheFolder = Notification.Name("OpenCacheFolder")
    static let clearCache = Notification.Name("ClearCache")
    static let toggleAutoUpdate = Notification.Name("ToggleAutoUpdate")
    static let checkUpdatesNow = Notification.Name("CheckUpdatesNow")
    static let refreshPlayback = Notification.Name("RefreshPlayback")
}

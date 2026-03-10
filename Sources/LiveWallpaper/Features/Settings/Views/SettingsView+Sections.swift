import AppKit
import AVFoundation
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    private var fitEditorSegmentedPickerWidth: CGFloat {
        200
    }

    private var wallpaperLibraryGridMinHeight: CGFloat {
        210
    }

    var wallpaperLibraryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("壁紙一覧", systemImage: "square.grid.2x2")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(model.allRegisteredVideoPaths.count) 本")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                Text(
                    model.currentVideoPath.map { model.registeredVideoDisplayName(
                        for: $0
                    ) } ?? "(選択なし)"
                )
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("動画を追加") {
                    NotificationCenter.default.post(name: .chooseVideo, object: nil)
                }
                .buttonStyle(.borderedProminent)
            }

            if model.allRegisteredVideoPaths.isEmpty {
                Text("登録済みの壁紙はまだありません。動画を追加するか、ここへドラッグ&ドロップしてください。")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
                                wallpaperCard(
                                    path: path,
                                    cardWidth: layout.1,
                                    canDragToPlaylist: true
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                }
                .frame(minHeight: wallpaperLibraryGridMinHeight, maxHeight: 360)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    var playlistSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("プレイリスト・設定", systemImage: "list.bullet.rectangle")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Text(model.playlistCapacityText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Text("選択中: \(model.selectedPlaylistName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
                Text("\(model.registeredVideoPaths.count) 本")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(alignment: .center, spacing: 10) {
                if model.playlists.isEmpty {
                    Text("プレイリストはありません")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.playlists) { playlist in
                                playlistChip(playlist)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button("新規プレイリスト") {
                    if let created = model.createPlaylist() {
                        model.selectPlaylist(created)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!model.canAddPlaylist)
            }

            if !model.registeredVideoPaths.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 14) {
                        compactToggle(
                            "プレイリスト連続再生",
                            isOn: Binding<Bool>(
                                get: { model.playlistPlaybackEnabled },
                                set: { model.setPlaylistPlaybackEnabled($0) }
                            )
                        )

                        compactToggle(
                            "シャッフル",
                            isOn: Binding<Bool>(
                                get: { model.shufflePlaybackEnabled },
                                set: { model.setShufflePlaybackEnabled($0) }
                            )
                        )
                        .disabled(!model.playlistPlaybackEnabled || model.registeredVideoPaths
                            .count < 2)

                        Spacer(minLength: 12)

                        if let index = model.currentVideoIndex {
                            Text("\(index + 1) / \(model.registeredVideoPaths.count)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack(spacing: 8) {
                        Button {
                            model.playPreviousVideo()
                        } label: {
                            Label("前へ", systemImage: "backward.fill")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.registeredVideoPaths.count < 2)

                        Button {
                            model.playNextVideo()
                        } label: {
                            Label("次へ", systemImage: "forward.fill")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.registeredVideoPaths.count < 2)

                        Spacer(minLength: 0)
                    }

                    GeometryReader { proxy in
                        let layout = wallpaperGridLayout(for: proxy.size.width)
                        ScrollView {
                            LazyVGrid(
                                columns: layout.0,
                                alignment: .leading,
                                spacing: wallpaperGridRowSpacing
                            ) {
                                ForEach(model.registeredVideoPaths, id: \.self) { path in
                                    wallpaperCard(path: path, cardWidth: layout.1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                        }
                    }
                    .frame(minHeight: wallpaperLibraryGridMinHeight, maxHeight: 260)
                }
            } else {
                Text("このプレイリストに動画がありません")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isPlaylistSectionDropTargeted ? Color.accentColor : Color.clear,
                    lineWidth: 2
                )
        )
        .onDrop(of: [UTType.text], isTargeted: $isPlaylistSectionDropTargeted) { providers in
            handleDraggedWallpaperDropToSelectedPlaylist(providers)
        }
    }

    var wallpaperFitLibraryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("壁紙一覧", systemImage: "square.grid.2x2")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(model.allRegisteredVideoPaths.count) 本")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if model.allRegisteredVideoPaths.isEmpty {
                Text("登録済みの壁紙がありません")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
                                wallpaperCard(
                                    path: path,
                                    cardWidth: layout.1,
                                    switchToWallpaperTabOnSelect: false,
                                    isSelected: resolvedFitEditorVideoPath() == path,
                                    onSelect: {
                                        selectFitEditorVideo(path: path)
                                    }
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                }
                .frame(minHeight: wallpaperLibraryGridMinHeight, maxHeight: 360)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    var wallpaperFitEditorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("フィット編集", systemImage: "crop")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }

            if let path = resolvedFitEditorVideoPath(),
               !path.isEmpty
            {
                let screenID = resolvedFitScreenID()
                HStack(spacing: 10) {
                    Text(model.registeredVideoDisplayName(for: path))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !fitEditorScreens.isEmpty {
                        Picker(
                            "",
                            selection: Binding<String>(
                                get: { resolvedFitScreenID() },
                                set: { selectedFitScreenID = $0 }
                            )
                        ) {
                            ForEach(fitEditorScreens) { screen in
                                Text(screen.name).tag(screen.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                }

                wallpaperFitPreview(path: path, screenID: screenID)

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("保存して再適用") {
                        applyFitEditorDraft(path: path, screenID: screenID)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("リセット") {
                        resetFitEditorDraft(path: path, screenID: screenID)
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                HStack(spacing: 12) {
                    Text("表示")
                        .frame(width: 72, alignment: .leading)
                    Spacer(minLength: 0)
                    EqualSegmentedControl(
                        options: [("拡大", VideoFitMode.fill), ("全体", VideoFitMode.fit)],
                        selection: fitModeBinding(path: path, screenID: screenID)
                    )
                    .frame(width: fitEditorSegmentedPickerWidth, height: 24)
                }

                HStack(spacing: 12) {
                    Text("プレビュー")
                        .lineLimit(1)
                        .frame(width: 72, alignment: .leading)
                    Spacer(minLength: 0)
                    EqualSegmentedControl(
                        options: [("動画", FitPreviewMode.video), ("静止画", FitPreviewMode.still)],
                        selection: $fitPreviewMode
                    )
                    .frame(width: fitEditorSegmentedPickerWidth, height: 24)
                }

                HStack(spacing: 12) {
                    Text("ズーム")
                        .frame(width: 56, alignment: .leading)
                    Slider(value: zoomBinding(path: path, screenID: screenID), in: 1 ... 3)
                    Text(
                        String(
                            format: "%.2fx", fitEditorZoom(path: path, screenID: screenID)
                        )
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .trailing)
                }

                HStack(spacing: 12) {
                    Text("X")
                        .frame(width: 56, alignment: .leading)
                    Slider(value: offsetXBinding(path: path, screenID: screenID), in: -1 ... 1)
                    Text(
                        String(
                            format: "%.3f", fitEditorOffsetX(path: path, screenID: screenID)
                        )
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .trailing)
                }

                HStack(spacing: 12) {
                    Text("Y")
                        .frame(width: 56, alignment: .leading)
                    Slider(value: offsetYBinding(path: path, screenID: screenID), in: -1 ... 1)
                    Text(
                        String(
                            format: "%.3f", fitEditorOffsetY(path: path, screenID: screenID)
                        )
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .trailing)
                }

                Text("矢印キーで位置を調整できます（Shift 併用で速く移動）。左クリックを押したままドラッグでも調整できます")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("この画面ではプレビューのみ更新されます。『保存して再適用』で壁紙に反映されます")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("上の壁紙一覧から動画を選択すると、画面ごとにフィット設定を編集できます")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    func wallpaperFitPreview(path: String, screenID: String) -> some View {
        GeometryReader { geo in
            let canvasSize = geo.size
            let frameSize = centeredPreviewFrameSize(canvasSize: canvasSize, screenID: screenID)
            let frameGeometry = model.wallpaperRenderGeometry(
                path: path,
                screenID: screenID,
                containerSize: frameSize,
                fitMode: fitEditorFitMode(path: path, screenID: screenID),
                zoom: fitEditorZoom(path: path, screenID: screenID),
                offsetX: fitEditorOffsetX(path: path, screenID: screenID),
                offsetY: fitEditorOffsetY(path: path, screenID: screenID)
            )

            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.72))

                if FileManager.default.fileExists(atPath: path) {
                    if fitPreviewMode == .video {
                        WallpaperAVLayerPreview(
                            videoPath: path,
                            fitMode: fitEditorFitMode(path: path, screenID: screenID),
                            renderedSize: frameGeometry.renderedSize,
                            translation: frameGeometry.translation
                        )
                        .id(path)
                        .frame(width: canvasSize.width, height: canvasSize.height)
                    } else {
                        if let image = fitPreviewStillImages[path] {
                            Image(nsImage: image)
                                .resizable()
                                .frame(
                                    width: frameGeometry.renderedSize.width,
                                    height: frameGeometry.renderedSize.height
                                )
                                .offset(
                                    x: frameGeometry.translation.width,
                                    y: frameGeometry.translation.height
                                )
                        } else {
                            ProgressView()
                                .controlSize(.small)
                                .onAppear {
                                    requestFitPreviewStillImage(path: path)
                                }
                        }
                    }
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: frameSize.width, height: frameSize.height)
                    Image(systemName: "film")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                }

                LeftDragCaptureView(
                    isEnabled: isFitEditorInteractionEnabled,
                    onActivate: {
                        isFitEditorInteractionEnabled = true
                    },
                    onDelta: { delta in
                        let normalizedDX = Double(delta.width / max(frameSize.width, 1)) * 2
                        let normalizedDY = Double(delta.height / max(frameSize.height, 1)) * 2
                        moveFitEditorDraftOffset(
                            dx: normalizedDX,
                            dy: normalizedDY,
                            path: path,
                            screenID: screenID
                        )
                    },
                    onScrollDelta: { delta in
                        let normalizedDX = Double(delta.width / max(frameSize.width, 1)) * 2
                        let normalizedDY = Double(delta.height / max(frameSize.height, 1)) * 2
                        moveFitEditorDraftOffset(
                            dx: normalizedDX,
                            dy: normalizedDY,
                            path: path,
                            screenID: screenID
                        )
                    },
                    currentZoom: {
                        fitEditorZoom(path: path, screenID: screenID)
                    },
                    onZoomChange: { zoom in
                        setFitEditorDraftZoom(zoom, path: path, screenID: screenID)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(isFitEditorInteractionEnabled)

                if !isFitEditorInteractionEnabled {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.clear)
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                        .onTapGesture {
                            isFitEditorInteractionEnabled = true
                        }
                }
            }
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .clipped()
            .overlay(alignment: .center) {
                fitEditorCenterFrameOverlay(frameSize: frameSize)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onAppear {
                updateFitEditorPreviewFrameSize(frameSize, path: path, screenID: screenID)
            }
            .onChange(of: frameSize) { newSize in
                updateFitEditorPreviewFrameSize(newSize, path: path, screenID: screenID)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 240, maxHeight: 300)
    }

    var fitEditorScreens: [WallpaperModel.DisplayScreenInfo] {
        model.availableDisplayScreens()
    }

    func screenAspect(for screenID: String) -> CGFloat {
        if let screen = fitEditorScreens.first(where: { $0.id == screenID }) {
            let width = max(screen.frame.width, 1)
            let height = max(screen.frame.height, 1)
            return width / height
        }
        return 16.0 / 9.0
    }

    func ensureFitEditorScreenSelection() {
        let screens = fitEditorScreens
        if screens.isEmpty {
            selectedFitScreenID = ""
            return
        }
        if screens.contains(where: { $0.id == selectedFitScreenID }) {
            return
        }
        selectedFitScreenID = screens[0].id
    }

    func resolvedFitScreenID() -> String {
        if fitEditorScreens.contains(where: { $0.id == selectedFitScreenID }) {
            return selectedFitScreenID
        }
        return fitEditorScreens.first?.id ?? "main"
    }

    func fitModeBinding(path: String, screenID: String) -> Binding<VideoFitMode> {
        Binding(
            get: { fitEditorFitMode(path: path, screenID: screenID) },
            set: { setFitEditorDraftFitMode($0, path: path, screenID: screenID) }
        )
    }

    func zoomBinding(path: String, screenID: String) -> Binding<Double> {
        Binding(
            get: { fitEditorZoom(path: path, screenID: screenID) },
            set: { setFitEditorDraftZoom($0, path: path, screenID: screenID) }
        )
    }

    func offsetXBinding(path: String, screenID: String) -> Binding<Double> {
        Binding(
            get: { fitEditorOffsetX(path: path, screenID: screenID) },
            set: { setFitEditorDraftOffsetX($0, path: path, screenID: screenID) }
        )
    }

    func offsetYBinding(path: String, screenID: String) -> Binding<Double> {
        Binding(
            get: { fitEditorOffsetY(path: path, screenID: screenID) },
            set: { setFitEditorDraftOffsetY($0, path: path, screenID: screenID) }
        )
    }

    func centeredPreviewFrameSize(canvasSize: CGSize, screenID: String) -> CGSize {
        let maxWidth = max(canvasSize.width * 0.63, 1)
        let maxHeight = max(canvasSize.height * 0.63, 1)
        let aspect = max(screenAspect(for: screenID), 0.2)

        var width = maxWidth
        var height = width / aspect
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }
        return CGSize(width: width, height: height)
    }

    func fitEditorCenterFrameOverlay(frameSize: CGSize) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.92), lineWidth: 2.5)
                .frame(width: frameSize.width, height: frameSize.height)

            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.78), lineWidth: 1)
                .frame(width: frameSize.width + 6, height: frameSize.height + 6)

            Rectangle()
                .stroke(
                    Color.white.opacity(0.42),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
                .frame(width: frameSize.width * 0.7, height: 1)

            Rectangle()
                .stroke(
                    Color.white.opacity(0.42),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
                .frame(width: 1, height: frameSize.height * 0.7)
        }
        .allowsHitTesting(false)
    }

    func installFitKeyMonitorIfNeeded() {
        guard keyEventMonitor == nil else {
            return
        }

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard selectedTab == .wallpaperFit else {
                return event
            }
            guard let path = resolvedFitEditorVideoPath(), !path.isEmpty else {
                return event
            }

            let step = event.modifierFlags.contains(.shift) ? 0.01 : 0.002
            let screenID = resolvedFitScreenID()

            switch event.keyCode {
            case 123:
                moveFitEditorDraftOffset(dx: -step, dy: 0, path: path, screenID: screenID)
                return nil
            case 124:
                moveFitEditorDraftOffset(dx: step, dy: 0, path: path, screenID: screenID)
                return nil
            case 125:
                moveFitEditorDraftOffset(dx: 0, dy: step, path: path, screenID: screenID)
                return nil
            case 126:
                moveFitEditorDraftOffset(dx: 0, dy: -step, path: path, screenID: screenID)
                return nil
            default:
                return event
            }
        }
    }

    func removeFitKeyMonitor() {
        guard let monitor = keyEventMonitor else {
            return
        }
        NSEvent.removeMonitor(monitor)
        keyEventMonitor = nil
    }

    func wallpaperCard(
        path: String,
        cardWidth: CGFloat,
        canDragToPlaylist: Bool = false,
        switchToWallpaperTabOnSelect: Bool = true,
        isSelected: Bool? = nil,
        onSelect: (() -> Void)? = nil
    ) -> some View {
        let thumbnailWidth = max(cardWidth - 8, 1)

        return VStack(alignment: .leading, spacing: 8) {
            Group {
                if canDragToPlaylist {
                    Button {
                        if let onSelect {
                            onSelect()
                        } else {
                            model.selectRegisteredVideo(path: path)
                            if switchToWallpaperTabOnSelect {
                                selectedTab = .wallpaper
                            }
                        }
                    } label: {
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
                        .frame(width: thumbnailWidth, height: 60)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onAppear {
                            setThumbnailVisibility(path: path, isVisible: true)
                        }
                        .onDisappear {
                            setThumbnailVisibility(path: path, isVisible: false)
                        }
                    }
                    .buttonStyle(.plain)
                    .onDrag {
                        NSItemProvider(object: path as NSString)
                    }
                } else {
                    Button {
                        if let onSelect {
                            onSelect()
                        } else {
                            model.selectRegisteredVideo(path: path)
                            if switchToWallpaperTabOnSelect {
                                selectedTab = .wallpaper
                            }
                        }
                    } label: {
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
                        .frame(width: thumbnailWidth, height: 60)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onAppear {
                            setThumbnailVisibility(path: path, isVisible: true)
                        }
                        .onDisappear {
                            setThumbnailVisibility(path: path, isVisible: false)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if editingWallpaperPath == path {
                HStack(spacing: 4) {
                    TextField(
                        "名前",
                        text: $editingWallpaperNameInput
                    )
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: 10))
                    .focused($focusedWallpaperPath, equals: path)
                    .onSubmit {
                        commitWallpaperNameEdit(path: path)
                    }

                    Button {
                        commitWallpaperNameEdit(path: path)
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderless)

                    Button {
                        cancelWallpaperNameEdit()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderless)
                }
            } else {
                HStack(spacing: 2) {
                    Text(model.registeredVideoDisplayName(for: path))
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        startWallpaperNameEdit(path: path)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(4)
        .frame(width: cardWidth, alignment: .leading)
        .clipped()
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    (isSelected ?? (model.currentVideoPath == path)) ? Color.accentColor : Color
                        .clear,
                    lineWidth: 1.5
                )
        )
        .contextMenu {
            Button("この壁紙に切り替え") {
                model.selectRegisteredVideo(path: path)
            }
            Menu("プレイリストに追加…") {
                if model.playlists.isEmpty {
                    Button("新規プレイリストを作成して追加") {
                        addToNewPlaylist(path: path)
                    }
                    .disabled(!model.canAddPlaylist)
                } else {
                    ForEach(model.playlists) { playlist in
                        Button(playlist.name) {
                            _ = model.addRegisteredVideo(path: path, to: playlist.id)
                        }
                        .disabled(model.playlistContainsVideo(playlist.id, path: path))
                    }
                    Divider()
                    Button("新規プレイリストを作成して追加") {
                        addToNewPlaylist(path: path)
                    }
                    .disabled(!model.canAddPlaylist)
                }
            }
            Button("名前を編集") {
                startWallpaperNameEdit(path: path)
            }
            Button("登録から削除") {
                model.removeRegisteredVideo(path: path)
            }
        }
    }

    func playlistChip(_ playlist: WallpaperPlaylist) -> some View {
        Group {
            if editingPlaylistID == playlist.id {
                HStack(spacing: 4) {
                    TextField("プレイリスト名", text: $editingPlaylistNameInput)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.system(size: 11, weight: .medium))
                        .frame(minWidth: 120, idealWidth: 150, maxWidth: 180)
                        .focused($focusedPlaylistID, equals: playlist.id)
                        .onSubmit {
                            commitPlaylistNameEdit(playlistID: playlist.id)
                        }

                    Button {
                        commitPlaylistNameEdit(playlistID: playlist.id)
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderless)

                    Button {
                        cancelPlaylistNameEdit()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderless)
                }
            } else {
                Button {
                    model.selectPlaylist(playlist.id)
                } label: {
                    HStack(spacing: 4) {
                        Text(playlist.name)
                            .lineLimit(1)
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .semibold))
                            .opacity(0.75)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minWidth: 72, maxWidth: 180)
                    .background(
                        Capsule()
                            .fill(
                                model.isSelectedPlaylist(playlist.id)
                                    ? Color.accentColor : Color.secondary.opacity(0.16)
                            )
                    )
                    .foregroundColor(model.isSelectedPlaylist(playlist.id) ? .white : .primary)
                }
                .buttonStyle(.plain)
                .overlay(
                    Capsule()
                        .stroke(
                            hoveredPlaylistDropTargetID == playlist.id ? Color.accentColor : Color
                                .clear,
                            lineWidth: 2
                        )
                )
                .onDrop(
                    of: [UTType.text],
                    isTargeted: playlistDropTargetBinding(for: playlist.id)
                ) {
                    providers in
                    handleDraggedWallpaperDrop(providers, to: playlist.id)
                }
                .contextMenu {
                    Button("このプレイリストに切り替え") {
                        model.selectPlaylist(playlist.id)
                    }
                    Button("名前を編集") {
                        startPlaylistNameEdit(playlistID: playlist.id)
                    }
                    Button("プレイリストを削除") {
                        model.removePlaylist(playlist.id)
                    }
                }
            }
        }
    }
}

private struct WallpaperAVLayerPreview: NSViewRepresentable {
    let videoPath: String
    let fitMode: VideoFitMode
    let renderedSize: CGSize
    let translation: CGSize

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PreviewPlayerView {
        let view = PreviewPlayerView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.playerLayer.backgroundColor = NSColor.black.cgColor
        view.playerLayer.needsDisplayOnBoundsChange = true
        context.coordinator.attachPlayer(to: view.playerLayer, path: videoPath)
        context.coordinator.applyPresentation(fitMode: fitMode, on: view.playerLayer)
        view.updateContentLayout(renderedSize: renderedSize, translation: translation)
        return view
    }

    func updateNSView(_ nsView: PreviewPlayerView, context: Context) {
        context.coordinator.attachPlayer(to: nsView.playerLayer, path: videoPath)
        context.coordinator.applyPresentation(fitMode: fitMode, on: nsView.playerLayer)
        nsView.updateContentLayout(renderedSize: renderedSize, translation: translation)
    }

    static func dismantleNSView(_ nsView: PreviewPlayerView, coordinator: Coordinator) {
        nsView.playerLayer.player = nil
        coordinator.stop()
    }

    final class Coordinator {
        private var currentPath: String?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?

        func attachPlayer(to layer: AVPlayerLayer, path: String) {
            if currentPath == path, let player {
                if layer.player !== player {
                    layer.player = player
                }
                return
            }

            stop()

            let url = URL(fileURLWithPath: path)
            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)
            let queue = AVQueuePlayer()
            queue.isMuted = true
            queue.volume = 0
            queue.allowsExternalPlayback = false
            queue.preventsDisplaySleepDuringVideoPlayback = false
            queue.automaticallyWaitsToMinimizeStalling = true
            queue.actionAtItemEnd = .none
            looper = AVPlayerLooper(player: queue, templateItem: item)
            queue.play()

            currentPath = path
            player = queue
            layer.player = queue
        }

        func applyPresentation(fitMode: VideoFitMode, on layer: AVPlayerLayer) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.videoGravity = fitMode == .fit ? .resizeAspect : .resizeAspectFill
            layer.setAffineTransform(.identity)
            CATransaction.commit()
        }

        func stop() {
            player?.pause()
            player?.removeAllItems()
            looper = nil
            player = nil
            currentPath = nil
        }
    }
}

private final class PreviewPlayerView: NSView {
    let playerLayer: AVPlayerLayer = .init()
    private var renderedSize: CGSize = .zero
    private var translation: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    override func makeBackingLayer() -> CALayer {
        CALayer()
    }

    override func layout() {
        super.layout()
        layer?.frame = bounds
        let originX = (bounds.width - renderedSize.width) * 0.5 + translation.width
        let originY = (bounds.height - renderedSize.height) * 0.5 + translation.height
        playerLayer.frame = CGRect(origin: CGPoint(x: originX, y: originY), size: renderedSize)
    }

    override var isFlipped: Bool {
        true
    }

    func updateContentLayout(renderedSize: CGSize, translation: CGSize) {
        self.renderedSize = renderedSize
        self.translation = translation
        needsLayout = true
    }

    private func setupLayers() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.needsDisplayOnBoundsChange = true
        if playerLayer.superlayer == nil {
            layer?.addSublayer(playerLayer)
        }
    }
}

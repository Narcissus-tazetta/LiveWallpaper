import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    var wallpaperContentPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            wallpaperContentHeader

            switch selectedLibrarySource {
            case .all, .playlist:
                wallpaperActionToolbar
                wallpaperVideoContent

                if isViewingActivePlaylist, !model.registeredVideoPaths.isEmpty {
                    playlistPlaybackControls
                }
            case .web:
                webWallpaperURLInputSection
                webWallpaperContent
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isContentPaneDropActive ? Color.accentColor : Color.clear,
                    lineWidth: 2
                )
        )
        .onChange(of: selectedLibrarySource) { _ in
            resetLibrarySearchState()
        }
        .onDrop(of: [UTType.text], isTargeted: $isPlaylistSectionDropTargeted) { providers in
            handleDropOntoContentPane(providers)
        }
    }

    /// Only show the drop highlight when the pane is a valid drop target
    /// (a playlist). All / Web reject drops, so they must not invite one.
    private var isContentPaneDropActive: Bool {
        isPlaylistSectionDropTargeted && activePlaylistLibrarySourceID != nil
    }

    private func handleDropOntoContentPane(_ providers: [NSItemProvider]) -> Bool {
        guard let playlistID = activePlaylistLibrarySourceID else {
            return false
        }
        return handleDraggedWallpaperDrop(providers, to: playlistID)
    }

    private var currentSourceTitle: String {
        switch selectedLibrarySource {
        case .all:
            return model.localizedString("すべての壁紙")
        case .playlist(let id):
            return model.playlists.first(where: { $0.id == id })?.name
                ?? model.localizedString("プレイリスト")
        case .web:
            return model.localizedString("Web壁紙")
        }
    }

    private var currentSourceIcon: String {
        switch selectedLibrarySource {
        case .all: return "square.grid.2x2"
        case .playlist: return "list.bullet.rectangle"
        case .web: return "globe"
        }
    }

    private var isLibrarySearchActive: Bool {
        !librarySearchQuery.isEmpty
    }

    private var librarySearchQuery: String {
        librarySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayedItemCount: Int {
        switch selectedLibrarySource {
        case .web:
            return isLibrarySearchActive
                ? filteredWebSources.count
                : model.webWallpaperSources.count
        default:
            return isLibrarySearchActive ? filteredPaths.count : currentPaths.count
        }
    }

    private var currentPaths: [String] {
        switch selectedLibrarySource {
        case .all:
            return model.allRegisteredVideoPaths
        case .playlist(let id):
            return model.playlists.first(where: { $0.id == id })?.videoPaths ?? []
        case .web:
            return []
        }
    }

    private func matchesLibrarySearch(_ text: String, query: String) -> Bool {
        guard !query.isEmpty else {
            return true
        }
        return text.localizedCaseInsensitiveContains(query)
    }

    private var filteredPaths: [String] {
        let query = librarySearchQuery
        guard !query.isEmpty else {
            return currentPaths
        }
        return currentPaths.filter { path in
            matchesLibrarySearch(model.registeredVideoDisplayName(for: path), query: query)
                || matchesLibrarySearch(URL(fileURLWithPath: path).lastPathComponent, query: query)
        }
    }

    private var filteredWebSources: [WebWallpaperSource] {
        let query = librarySearchQuery
        guard !query.isEmpty else {
            return model.webWallpaperSources
        }
        return model.webWallpaperSources.filter { source in
            matchesLibrarySearch(source.displayName, query: query)
                || matchesLibrarySearch(source.url.absoluteString, query: query)
        }
    }

    private var wallpaperContentHeader: some View {
        HStack(spacing: 10) {
            Label(currentSourceTitle, systemImage: currentSourceIcon)
                .font(.system(size: 13, weight: .semibold))
                .layoutPriority(1)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .onTapGesture {
                        isLibrarySearchFocused = true
                    }
                LibrarySearchField(
                    text: $librarySearchText,
                    placeholder: model.localizedString("検索"),
                    isFocused: $isLibrarySearchFocused
                )
                .frame(minWidth: 120, maxWidth: .infinity)
                Button {
                    librarySearchText = ""
                    isLibrarySearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(librarySearchText.isEmpty ? 0 : 1)
                .disabled(librarySearchText.isEmpty)
                .allowsHitTesting(!librarySearchText.isEmpty)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isLibrarySearchFocused ? Color.accentColor : Color.clear,
                        lineWidth: 1.5
                    )
            )
            Text("\(displayedItemCount) \(model.localizedString("本"))")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var wallpaperVideoContent: some View {
        if currentPaths.isEmpty {
            wallpaperEmptyStateText
        } else if filteredPaths.isEmpty {
            librarySearchNoMatchText
        } else {
            wallpaperGrid
        }
    }

    @ViewBuilder
    private var webWallpaperContent: some View {
        if model.webWallpaperSources.isEmpty {
            Text(model.localizedString("登録済みのWeb壁紙はありません"))
                .font(.caption)
                .foregroundColor(.secondary)
        } else if filteredWebSources.isEmpty {
            librarySearchNoMatchText
        } else {
            webWallpaperGrid
        }
    }

    private var librarySearchNoMatchText: some View {
        Text(
            selectedLibrarySource == .web
                ? model.localizedString("該当するWeb壁紙がありません")
                : model.localizedString("該当する壁紙がありません")
        )
        .font(.caption)
        .foregroundColor(.secondary)
    }

    private var wallpaperActionToolbar: some View {
        HStack(spacing: 8) {
            if model.lockScreenSyncService.isSupported {
                Text(model.localizedString("クリックでデスクトップに設定、🔒でロック画面に設定"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button(model.localizedString("壁紙を共有")) {
                isWallpaperShareSheetPresented = true
            }
            .buttonStyle(.bordered)
            .disabled(model.allRegisteredVideoPaths.isEmpty)

            Button(model.localizedString("動画を追加")) {
                NotificationCenter.default.post(name: .chooseVideo, object: nil)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var wallpaperEmptyStateText: some View {
        if case .playlist = selectedLibrarySource, !model.allRegisteredVideoPaths.isEmpty {
            Text(model.localizedString("このプレイリストに動画がありません"))
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.localizedString("1. 「動画を追加」を押して動画を選ぶ\n2. 選んだ動画がそのまま壁紙として再生されます"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(model.localizedString("動画ファイルをウィンドウにドラッグ&ドロップして追加することもできます"))
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.85))
            }
        }
    }

    private var wallpaperGrid: some View {
        GeometryReader { proxy in
            let layout = wallpaperGridLayout(for: proxy.size.width)
            ScrollView {
                LazyVGrid(
                    columns: layout.0,
                    alignment: .leading,
                    spacing: wallpaperGridRowSpacing
                ) {
                    ForEach(filteredPaths, id: \.self) { path in
                        wallpaperCard(
                            path: path,
                            cardWidth: layout.1,
                            canDragToPlaylist: true,
                            assignmentTarget: .desktop,
                            showLockScreenButton: true
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
        }
        .frame(minHeight: wallpaperLibraryGridMinHeight, maxHeight: 300)
    }

    private var playlistPlaybackControls: some View {
        let registeredCount = model.registeredVideoPaths.count
        return VStack(alignment: .leading, spacing: 6) {
            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    compactToggle(
                        model.localizedString("ループ再生"),
                        isOn: Binding<Bool>(
                            get: { model.videoLoopEnabled },
                            set: { model.setVideoLoopEnabled($0) }
                        )
                    )
                    .disabled(!model.isVideoLoopSettingEnabled)

                    helpIconButton(for: .videoLoop)
                        .disabled(false)
                }

                if expandedHelpTopics.contains(.videoLoop) {
                    Text(
                        model.localizedString(
                            "動画が1本のときは常にループします。複数あるときは、連続再生中は次の動画へ進みます。"
                        )
                    )
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 14) {
                compactToggle(
                    model.localizedString("プレイリスト連続再生"),
                    isOn: Binding<Bool>(
                        get: { model.playlistPlaybackEnabled },
                        set: { model.setPlaylistPlaybackEnabled($0) }
                    )
                )

                compactToggle(
                    model.localizedString("シャッフル"),
                    isOn: Binding<Bool>(
                        get: { model.shufflePlaybackEnabled },
                        set: { model.setShufflePlaybackEnabled($0) }
                    )
                )
                .disabled(
                    !model.playlistPlaybackEnabled
                        || registeredCount < 2
                        || model.pinCurrentVideo
                )

                if model.canPinCurrentVideo || model.pinCurrentVideo {
                    compactToggle(
                        model.localizedString("この動画で固定"),
                        isOn: Binding<Bool>(
                            get: { model.pinCurrentVideo },
                            set: { model.setPinCurrentVideo($0) }
                        )
                    )
                }

                Spacer(minLength: 12)

                if let index = model.currentVideoIndex {
                    Text("\(index + 1) / \(registeredCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button {
                    model.playPreviousVideo()
                } label: {
                    Label(model.localizedString("前へ"), systemImage: "backward.fill")
                }
                .buttonStyle(.bordered)
                .disabled(registeredCount < 2)

                Button {
                    model.playNextVideo()
                } label: {
                    Label(model.localizedString("次へ"), systemImage: "forward.fill")
                }
                .buttonStyle(.bordered)
                .disabled(registeredCount < 2)

                Spacer(minLength: 0)
            }

            if model.canPinCurrentVideo || model.pinCurrentVideo {
                Text(model.localizedString("固定はアプリ再起動まで有効です。"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var webWallpaperURLInputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.localizedString("WebサイトのURLを入力すると、そのページを壁紙として表示できます"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(model.localizedString("※ いま動作確認できているのは YouTube だけです。ほかのサイトも試せますが、表示できない場合があります"))
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                PasteableTextField(
                    text: $webURLInput,
                    placeholder: model.localizedString("https://example.com"),
                    onSubmit: submitWebWallpaperURL
                )
                .frame(minWidth: 200)

                Button {
                    if let pasted = PasteboardPaste.readPlainText() {
                        webURLInput = pasted
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .help(model.localizedString("クリップボードから貼り付け"))

                Button(model.localizedString("追加")) {
                    submitWebWallpaperURL()
                }
                .buttonStyle(.borderedProminent)
                .disabled(webURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let errorMessage = model.webWallpaperErrorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    private var webWallpaperGrid: some View {
        GeometryReader { proxy in
            let layout = wallpaperGridLayout(for: proxy.size.width)
            ScrollView {
                LazyVGrid(
                    columns: layout.0,
                    alignment: .leading,
                    spacing: wallpaperGridRowSpacing
                ) {
                    ForEach(filteredWebSources) { source in
                        webWallpaperCard(source: source, cardWidth: layout.1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
        }
        .frame(minHeight: wallpaperLibraryGridMinHeight, maxHeight: 300)
    }
}

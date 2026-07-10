import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    var wallpaperContentPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            wallpaperContentHeader
            wallpaperActionToolbar
            wallpaperVideoContent

            if selectedAssignmentTarget == .desktop,
               !model.registeredVideoPaths.isEmpty
            {
                playlistPlaybackControls
            }

            if selectedAssignmentTarget == .lockScreen {
                Divider()
                lockScreenSyncControls
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var isLibrarySearchActive: Bool {
        !librarySearchQuery.isEmpty
    }

    private var librarySearchQuery: String {
        librarySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayedItemCount: Int {
        isLibrarySearchActive ? filteredPaths.count : model.libraryVideoPaths.count
    }

    private func matchesLibrarySearch(_ text: String, query: String) -> Bool {
        guard !query.isEmpty else {
            return true
        }
        return text.localizedCaseInsensitiveContains(query)
    }

    var filteredPaths: [String] {
        let query = librarySearchQuery
        guard !query.isEmpty else {
            return model.libraryVideoPaths
        }
        return model.libraryVideoPaths.filter { path in
            matchesLibrarySearch(model.registeredVideoDisplayName(for: path), query: query)
                || matchesLibrarySearch(URL(fileURLWithPath: path).lastPathComponent, query: query)
        }
    }

    var filteredWebSources: [WebWallpaperSource] {
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
            playlistFilterControl

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

    /// プレイリストの選択・作成・名前変更・削除を1つに集約したメニュー。
    /// 選択=そのプレイリストの編集(チェックボックス表示)と再生対象の切り替え。
    @ViewBuilder
    private var playlistFilterControl: some View {
        if let editingID = editingPlaylistID {
            playlistInlineNameEditor(playlistID: editingID)
        } else {
            Menu {
                Picker("", selection: playlistSelectionBinding) {
                    Label(
                        "\(model.localizedString("すべての壁紙")) (\(model.libraryVideoPaths.count))",
                        systemImage: "square.grid.2x2"
                    )
                    .tag(UUID?.none)

                    ForEach(model.playlists) { playlist in
                        Label(
                            "\(playlist.name) (\(playlist.videoPaths.count))",
                            systemImage: "list.bullet.rectangle"
                        )
                        .tag(Optional(playlist.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                Divider()

                Button {
                    createAndSelectPlaylist()
                } label: {
                    Label(model.localizedString("新規プレイリスト"), systemImage: "plus")
                }
                .disabled(!model.canAddPlaylist)

                if let selectedID = model.selectedPlaylistID {
                    Divider()
                    Button(model.localizedString("名前を編集")) {
                        startPlaylistNameEdit(playlistID: selectedID)
                    }
                    Button(role: .destructive) {
                        model.removePlaylist(selectedID)
                    } label: {
                        Text(model.localizedString("プレイリストを削除"))
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(
                        systemName: model.selectedPlaylistID == nil
                            ? "square.grid.2x2"
                            : "list.bullet.rectangle"
                    )
                    .font(.system(size: 11, weight: .semibold))
                    Text(model.selectedPlaylistName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
            )
        }
    }

    private var playlistSelectionBinding: Binding<UUID?> {
        Binding(
            get: { model.selectedPlaylistID },
            set: { model.selectPlaylist($0) }
        )
    }

    private func createAndSelectPlaylist() {
        guard let created = model.createPlaylist() else {
            return
        }
        model.selectPlaylist(created)
        startPlaylistNameEdit(playlistID: created)
    }

    private func playlistInlineNameEditor(playlistID: UUID) -> some View {
        HStack(spacing: 4) {
            TextField(model.localizedString("プレイリスト名"), text: $editingPlaylistNameInput)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 160)
                .focused($focusedPlaylistID, equals: playlistID)
                .onSubmit {
                    commitPlaylistNameEdit(playlistID: playlistID)
                }

            Button {
                commitPlaylistNameEdit(playlistID: playlistID)
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
    }

    @ViewBuilder
    private var wallpaperVideoContent: some View {
        if model.libraryVideoPaths.isEmpty {
            wallpaperEmptyStateText
        } else if filteredPaths.isEmpty {
            Text(model.localizedString("該当する壁紙がありません"))
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            wallpaperGrid
        }
    }

    private var wallpaperActionToolbar: some View {
        HStack(spacing: 8) {
            if let selectedID = model.selectedPlaylistID,
               let playlist = model.playlists.first(where: { $0.id == selectedID })
            {
                Text(
                    "\(model.localizedString("チェックした動画がこのプレイリストで再生されます")) (\(playlist.videoPaths.count))"
                )
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
            .disabled(model.libraryVideoPaths.isEmpty)

            Button(model.localizedString("動画を追加")) {
                NotificationCenter.default.post(name: .chooseVideo, object: nil)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var wallpaperEmptyStateText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.localizedString("1. 「動画を追加」を押して動画を選ぶ\n2. 選んだ動画がそのまま壁紙として再生されます"))
                .font(.caption)
                .foregroundColor(.secondary)
            Text(model.localizedString("動画ファイルをウィンドウにドラッグ&ドロップして追加することもできます"))
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.85))
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
                            assignmentTarget: selectedAssignmentTarget,
                            playlistEditingID: model.selectedPlaylistID
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
        }
        .frame(minHeight: wallpaperLibraryGridMinHeight, maxHeight: 340)
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
}

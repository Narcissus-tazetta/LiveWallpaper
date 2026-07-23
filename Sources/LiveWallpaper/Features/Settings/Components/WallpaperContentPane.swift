import SwiftUI
import UniformTypeIdentifiers

private enum WallpaperListEntry: Identifiable {
    case video(String)
    case web(WebWallpaperSource)

    var id: String {
        switch self {
        case .video(let path):
            return "video:\(path)"
        case .web(let source):
            return "web:\(source.id.uuidString)"
        }
    }
}

extension SettingsView {
    var wallpaperContentPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            wallpaperContentHeader
            wallpaperActionToolbar

            if let importErrorMessage = model.mediaImportErrorMessage {
                Text(importErrorMessage)
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            wallpaperListContent

            if let screenID = activeDisplayOverrideScreenID {
                displayOverridePlaybackControls(forScreenID: screenID)
            } else if let spaceUUID = activeSpaceScopeUUID {
                spaceScopeControls(forSpaceUUID: spaceUUID)
            } else if selectedAssignmentTarget == .desktop,
                      !model.registeredPlaybackEntries.isEmpty
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

    private var librarySearchQuery: String {
        librarySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayedItemCount: Int {
        mergedListEntries.count
    }

    private func matchesLibrarySearch(_ text: String, query: String) -> Bool {
        guard !query.isEmpty else {
            return true
        }
        return text.localizedCaseInsensitiveContains(query)
    }

    var filteredPaths: [String] {
        let basePaths = activeDisplayOverrideScreenID.map(model.screenVideoPaths(forScreenID:))
            ?? model.libraryVideoPaths
        let query = librarySearchQuery
        guard !query.isEmpty else {
            return basePaths
        }
        return basePaths.filter { path in
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

    private var mergedListEntries: [WallpaperListEntry] {
        let videoEntries = filteredPaths.map { WallpaperListEntry.video($0) }
        // ディスプレイ/Space割り当てはまだ動画のみ対応(専用プレイヤーがWeb壁紙に非対応)。
        guard model.webWallpaperFeatureEnabled,
              activeDisplayOverrideScreenID == nil,
              activeSpaceScopeUUID == nil
        else {
            return videoEntries
        }
        return videoEntries + filteredWebSources.map { WallpaperListEntry.web($0) }
    }

    private var wallpaperContentHeader: some View {
        HStack(spacing: 10) {
            playlistFilterControl

            SearchField(
                placeholder: model.localizedString("タイトルや名前で壁紙を検索"),
                text: $librarySearchText,
                isFocused: $isLibrarySearchFocused
            )
            .frame(minWidth: 120, maxWidth: .infinity)

            Text("\(displayedItemCount) \(model.localizedString("本"))")
                .font(.caption)
                .foregroundColor(.secondary)

            if model.isWebWallpaperActive {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text(model.localizedString("Web壁紙再生中"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    /// プレイリストの選択・作成・名前変更・削除を1つに集約したメニュー。
    /// 選択=そのプレイリストの編集(チェックボックス表示)と再生対象の切り替え。
    @ViewBuilder
    private var playlistFilterControl: some View {
        if let editingID = editingPlaylistID {
            playlistInlineNameEditor(playlistID: editingID)
        } else if let screenID = activeDisplayOverrideScreenID {
            screenPlaylistFilterControl(forScreenID: screenID)
        } else if activeSpaceScopeUUID != nil {
            // Space割り当てはv1では動画1本の固定のみ(プレイリスト非対応)なので、
            // 常にライブラリ全体を表示する。
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(model.localizedString("すべての壁紙")) (\(model.libraryVideoPaths.count))")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
            )
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
                            "\(playlist.name) (\(playlist.videoPaths.count + playlist.webWallpaperIDs.count))",
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

    /// 画面割り当てモード用のプレイリスト選択。作成・名前変更・削除は行わず、
    /// 既存プレイリストへの割り当てまたは「すべての壁紙」への切り替えのみ。
    private func screenPlaylistFilterControl(forScreenID screenID: String) -> some View {
        Menu {
            Picker("", selection: screenPlaylistSelectionBinding(forScreenID: screenID)) {
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
        } label: {
            HStack(spacing: 6) {
                Image(
                    systemName: model.screenPlaylistID(forScreenID: screenID) == nil
                        ? "square.grid.2x2"
                        : "list.bullet.rectangle"
                )
                .font(.system(size: 11, weight: .semibold))
                Text(screenPlaylistName(forScreenID: screenID))
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

    private func screenPlaylistSelectionBinding(forScreenID screenID: String) -> Binding<UUID?> {
        Binding(
            get: { model.screenPlaylistID(forScreenID: screenID) },
            set: { model.setScreenPlaylist($0, forScreenID: screenID) }
        )
    }

    private func screenPlaylistName(forScreenID screenID: String) -> String {
        guard let playlistID = model.screenPlaylistID(forScreenID: screenID),
              let playlist = model.playlists.first(where: { $0.id == playlistID })
        else {
            return model.localizedString("すべての壁紙")
        }
        return playlist.name
    }

    private var autoSwitchIntervalBinding: Binding<Int> {
        Binding(
            get: { model.autoSwitchIntervalMinutes },
            set: { model.setAutoSwitchInterval(minutes: $0) }
        )
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
    private var wallpaperListContent: some View {
        let hasAnySource = !model.libraryVideoPaths.isEmpty
            || (model.webWallpaperFeatureEnabled && !model.webWallpaperSources.isEmpty)
        if !hasAnySource || mergedListEntries.isEmpty {
            SearchEmptyState(
                isSearchActive: hasAnySource && !librarySearchQuery.isEmpty,
                clearButtonTitle: model.localizedString("検索をクリア"),
                onClearSearch: { librarySearchText = ""; isLibrarySearchFocused = true },
                noContent: { wallpaperEmptyStateText },
                noMatch: {
                    Text(model.localizedString("該当する壁紙がありません"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            )
        } else {
            wallpaperGrid
        }
    }

    private var selectedPlaylistSummaryText: String? {
        guard let selectedID = model.selectedPlaylistID,
              let playlist = model.playlists.first(where: { $0.id == selectedID })
        else {
            return nil
        }
        var text = "\(model.localizedString("チェックした動画がこのプレイリストで再生されます")) (\(playlist.videoPaths.count))"
        if !playlist.webWallpaperIDs.isEmpty {
            text += " ・ \(model.localizedString("Web壁紙")) \(playlist.webWallpaperIDs.count)"
        }
        return text
    }

    private var wallpaperActionToolbar: some View {
        HStack(spacing: 8) {
            if activeDisplayOverrideScreenID != nil {
                Text(model.localizedString("カードをクリックするとこの画面に割り当てられます"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if activeSpaceScopeUUID != nil {
                Text(model.localizedString("カードをクリックするとこのデスクトップに割り当てられます"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if let summaryText = selectedPlaylistSummaryText {
                Text(summaryText)
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

            if selectedAssignmentTarget == .desktop, activeDisplayOverrideScreenID == nil,
               model.webWallpaperFeatureEnabled
            {
                Button(model.localizedString("Web壁紙を追加")) {
                    isWebWallpaperURLPopoverPresented = true
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $isWebWallpaperURLPopoverPresented) {
                    webWallpaperURLInputSection
                        .padding(16)
                        .frame(width: 360)
                }
            }

            if model.isImportingMedia {
                HStack(spacing: 6) {
                    ProgressView(value: model.mediaImportProgress)
                        .frame(width: 80)
                    Text(model.localizedString("変換中…"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button {
                        model.cancelMediaImport()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(model.localizedString("変換をキャンセル"))
                }
            }

            Button(model.localizedString("メディアを追加")) {
                NotificationCenter.default.post(name: .chooseVideo, object: nil)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isImportingMedia)
        }
    }

    var webWallpaperURLInputSection: some View {
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

    @ViewBuilder
    private var wallpaperEmptyStateText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.localizedString("1. 「メディアを追加」を押して動画やGIFを選ぶ\n2. 選んだメディアがそのまま壁紙として再生されます"))
                .font(.caption)
                .foregroundColor(.secondary)
            Text(model.localizedString("動画やGIFなどのファイルをウィンドウにドラッグ&ドロップして追加することもできます"))
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.85))
            if model.webWallpaperFeatureEnabled {
                Text(model.localizedString("「Web壁紙を追加」からWebサイトのURLを壁紙として追加することもできます"))
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
                    ForEach(mergedListEntries) { entry in
                        switch entry {
                        case .video(let path):
                            if let screenID = activeDisplayOverrideScreenID {
                                wallpaperCard(
                                    path: path,
                                    cardWidth: layout.1,
                                    switchToWallpaperTabOnSelect: false,
                                    isSelected: model.videoOverride(forScreenID: screenID) == path,
                                    onSelect: {
                                        model.setVideoOverride(path: path, forScreenID: screenID)
                                    }
                                )
                            } else if let spaceUUID = activeSpaceScopeUUID {
                                wallpaperCard(
                                    path: path,
                                    cardWidth: layout.1,
                                    switchToWallpaperTabOnSelect: false,
                                    isSelected: model.spaceVideo(forSpaceUUID: spaceUUID) == path,
                                    onSelect: {
                                        model.setSpaceVideo(path: path, forSpaceUUID: spaceUUID)
                                    }
                                )
                            } else {
                                wallpaperCard(
                                    path: path,
                                    cardWidth: layout.1,
                                    assignmentTarget: selectedAssignmentTarget,
                                    playlistEditingID: model.selectedPlaylistID
                                )
                            }
                        case .web(let source):
                            webWallpaperCard(
                                source: source,
                                cardWidth: layout.1,
                                playlistEditingID: model.selectedPlaylistID,
                                assignmentTarget: selectedAssignmentTarget
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
        }
        .frame(minHeight: wallpaperLibraryGridMinHeight, maxHeight: 340)
    }

    /// 画面割り当てモード用の再生コントロール。専用プレイヤーは常にループする
    /// 前提のため、共有側にある「ループ再生」「シャッフル」「固定」は持たない。
    private func displayOverridePlaybackControls(forScreenID screenID: String) -> some View {
        let paths = model.screenVideoPaths(forScreenID: screenID)
        let count = paths.count
        let currentIndex = model.videoOverride(forScreenID: screenID)
            .flatMap { paths.firstIndex(of: $0) }
        return VStack(alignment: .leading, spacing: 6) {
            Divider()

            HStack(spacing: 14) {
                Text(model.localizedString("この画面専用のプレイリストです"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer(minLength: 12)
                if let currentIndex, count > 0 {
                    Text("\(currentIndex + 1) / \(count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button {
                    model.playPreviousVideo(forScreenID: screenID)
                } label: {
                    Label(model.localizedString("前へ"), systemImage: "backward.fill")
                }
                .buttonStyle(.bordered)
                .disabled(count < 2)

                Button {
                    model.playNextVideo(forScreenID: screenID)
                } label: {
                    Label(model.localizedString("次へ"), systemImage: "forward.fill")
                }
                .buttonStyle(.bordered)
                .disabled(count < 2)

                Spacer(minLength: 0)
            }
        }
    }

    /// Space割り当てモード用のフッター。v1は動画1本の固定のみなので、
    /// 再生コントロールは持たず説明と割り当て解除だけを出す。
    private func spaceScopeControls(forSpaceUUID uuid: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()

            Text(
                model.localizedString(
                    "このデスクトップに固定表示する動画です。未割り当てのデスクトップは通常の壁紙を表示します。"
                )
            )
            .font(.caption2)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(model.localizedString("割り当てを解除")) {
                    model.setSpaceVideo(path: nil, forSpaceUUID: uuid)
                }
                .buttonStyle(.bordered)
                .disabled(model.spaceVideo(forSpaceUUID: uuid) == nil)

                Spacer(minLength: 0)
            }
        }
    }

    private var playlistPlaybackControls: some View {
        let registeredCount = model.registeredPlaybackEntries.count
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
                    // 無効時はアクセントカラーのまま暗くすると他のOFFトグルと違う色に沈んで見えるため、
                    // 無効時だけsecondaryに切り替えてOFFトグルと同系統のグレーに揃える。
                    .tint(model.isVideoLoopSettingEnabled ? Color.accentColor : Color.secondary)
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

                if let index = model.currentPlaybackIndex {
                    Text("\(index + 1) / \(registeredCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 8) {
                Text(model.localizedString("自動で次の壁紙へ"))
                Picker("", selection: autoSwitchIntervalBinding) {
                    Text(model.localizedString("オフ")).tag(0)
                    Text(model.localizedString("5分")).tag(5)
                    Text(model.localizedString("15分")).tag(15)
                    Text(model.localizedString("30分")).tag(30)
                    Text(model.localizedString("1時間")).tag(60)
                    Text(model.localizedString("3時間")).tag(180)
                }
                .labelsHidden()
                .fixedSize()
                .disabled(registeredCount < 2 || model.pinCurrentVideo)

                Spacer(minLength: 0)
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

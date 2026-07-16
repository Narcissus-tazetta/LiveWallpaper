import Foundation

@MainActor
extension WallpaperModel {
    func isSelectedPlaylist(_ playlistID: UUID) -> Bool {
        selectedPlaylistID == playlistID
    }

    func playlistName(for playlistID: UUID) -> String {
        playlists.first(where: { $0.id == playlistID })?.name ?? localizedString("プレイリスト")
    }

    func setPlaylistName(_ name: String, for playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else {
            return
        }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return
        }
        guard playlists[index].name != cleaned else {
            return
        }
        playlists[index].name = cleaned
        persistPlaylistState()
    }

    @discardableResult
    func createPlaylist(named name: String? = nil) -> UUID? {
        guard canAddPlaylist else {
            return nil
        }
        let cleaned = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let playlistName = cleaned.isEmpty
            ? "\(localizedString("プレイリスト"))\(playlists.count + 1)"
            : cleaned
        let playlist = WallpaperPlaylist(id: UUID(), name: playlistName, videoPaths: [])
        playlists.append(playlist)
        persistPlaylistState()
        return playlist.id
    }

    /// プレイリストの特定の配列(videoPaths/webWallpaperIDs)に値が含まれるか調べる汎用ヘルパー。
    private func playlistArray<T: Equatable>(
        _ playlistID: UUID,
        keyPath: KeyPath<WallpaperPlaylist, [T]>,
        contains value: T
    ) -> Bool {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else {
            return false
        }
        return playlists[index][keyPath: keyPath].contains(value)
    }

    /// プレイリストの特定の配列へ値を追加する汎用ヘルパー。既に含まれていれば何もしない。
    @discardableResult
    private func addToPlaylistArray<T: Equatable>(
        _ value: T,
        to playlistID: UUID,
        keyPath: WritableKeyPath<WallpaperPlaylist, [T]>
    ) -> Bool {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else {
            return false
        }
        if !playlists[index][keyPath: keyPath].contains(value) {
            playlists[index][keyPath: keyPath].append(value)
        }
        persistPlaylistState()
        return true
    }

    /// プレイリストの特定の配列から値を外す汎用ヘルパー。
    @discardableResult
    private func removeFromPlaylistArray<T: Equatable>(
        _ value: T,
        fromPlaylist playlistID: UUID,
        keyPath: WritableKeyPath<WallpaperPlaylist, [T]>
    ) -> Bool {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }) else {
            return false
        }
        guard let valueIndex = playlists[playlistIndex][keyPath: keyPath].firstIndex(of: value) else {
            return false
        }
        playlists[playlistIndex][keyPath: keyPath].remove(at: valueIndex)
        persistPlaylistState()
        return true
    }

    func playlistContainsVideo(_ playlistID: UUID, path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return playlistArray(playlistID, keyPath: \.videoPaths, contains: trimmed)
    }

    /// プレイリストへ参照を追加する。動画本体はライブラリに登録される。
    @discardableResult
    func addRegisteredVideo(path: String, to playlistID: UUID) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        guard FileManager.default.fileExists(atPath: trimmed) else {
            return false
        }
        guard playlists.contains(where: { $0.id == playlistID }) else {
            return false
        }
        addVideoPathToLibrary(trimmed)
        let added = addToPlaylistArray(trimmed, to: playlistID, keyPath: \.videoPaths)
        if added, selectedPlaylistID == playlistID {
            syncActivePlaylistPaths()
            refreshCurrentVideoIndex()
        }
        return added
    }

    /// プレイリストから参照だけを外す。ライブラリ・他プレイリストには影響しない。
    /// 再生中の動画を外した場合も再生は継続する(次送りでキュー先頭へ戻る)。
    @discardableResult
    func removeVideo(path: String, fromPlaylist playlistID: UUID) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let removed = removeFromPlaylistArray(trimmed, fromPlaylist: playlistID, keyPath: \.videoPaths)
        if removed, selectedPlaylistID == playlistID {
            syncActivePlaylistPaths()
            refreshCurrentVideoIndex()
        }
        return removed
    }

    func playlistContainsWebWallpaper(_ playlistID: UUID, sourceID: UUID) -> Bool {
        playlistArray(playlistID, keyPath: \.webWallpaperIDs, contains: sourceID)
    }

    /// プレイリストへWeb壁紙の参照を追加する。Web壁紙本体は webWallpaperSources で管理される。
    @discardableResult
    func addWebWallpaper(sourceID: UUID, to playlistID: UUID) -> Bool {
        guard webWallpaperSources.contains(where: { $0.id == sourceID }) else {
            return false
        }
        let added = addToPlaylistArray(sourceID, to: playlistID, keyPath: \.webWallpaperIDs)
        if added, selectedPlaylistID == playlistID {
            syncActivePlaylistPaths()
        }
        return added
    }

    /// プレイリストからWeb壁紙の参照だけを外す。webWallpaperSources には影響しない。
    @discardableResult
    func removeWebWallpaper(sourceID: UUID, fromPlaylist playlistID: UUID) -> Bool {
        let removed = removeFromPlaylistArray(sourceID, fromPlaylist: playlistID, keyPath: \.webWallpaperIDs)
        if removed, selectedPlaylistID == playlistID {
            syncActivePlaylistPaths()
        }
        return removed
    }

    /// ライブラリへ動画パスを登録する(未登録の場合のみ)。プレイリストには追加しない。
    @discardableResult
    func addVideoPathToLibrary(
        _ path: String,
        preferredDisplayName: String? = nil
    ) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        guard FileManager.default.fileExists(atPath: trimmed) else {
            return false
        }

        if !libraryVideoPaths.contains(trimmed) {
            libraryVideoPaths.append(trimmed)
        }

        if let preferredDisplayName,
           !preferredDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           registeredVideoDisplayNames[trimmed] == nil
        {
            registeredVideoDisplayNames[trimmed] = preferredDisplayName
            UserDefaults.standard.set(
                registeredVideoDisplayNames,
                forKey: "registeredVideoDisplayNames"
            )
        }

        if selectedPlaylistID == nil {
            syncActivePlaylistPaths()
        }
        persistPlaylistState()
        return true
    }

    @discardableResult
    func addVideo(
        path: String,
        to playlistID: UUID,
        activateAfterAdding: Bool = true
    ) async -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        let sourceURL = URL(fileURLWithPath: trimmed)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return false
        }
        guard playlists.contains(where: { $0.id == playlistID }) else {
            return false
        }

        let destinationPath: String
        if let cacheDirectory = cacheDirectoryURL(), sourceURL.path.hasPrefix(cacheDirectory.path) {
            destinationPath = sourceURL.path
        } else {
            guard let localURL = await importVideoToAppSupport(from: sourceURL) else {
                return false
            }
            destinationPath = localURL.path
            if registeredVideoDisplayNames[destinationPath] == nil {
                registeredVideoDisplayNames[destinationPath] = sourceURL.lastPathComponent
                UserDefaults.standard.set(
                    registeredVideoDisplayNames, forKey: "registeredVideoDisplayNames"
                )
            }
        }

        _ = addRegisteredVideo(path: destinationPath, to: playlistID)

        guard activateAfterAdding else {
            return true
        }

        selectPlaylist(playlistID)
        selectRegisteredVideo(path: destinationPath)
        return true
    }

    /// プレイリストを削除する。中の動画はライブラリに残る。
    func removePlaylist(_ playlistID: UUID) {
        guard let removeIndex = playlists.firstIndex(where: { $0.id == playlistID }) else {
            return
        }
        playlists.remove(at: removeIndex)
        if selectedPlaylistID == playlistID {
            selectedPlaylistID = nil
        }
        syncActivePlaylistPaths()
        refreshCurrentVideoIndex()
        persistPlaylistState()
    }

    /// 再生対象を切り替える。nil は「すべての壁紙(ライブラリ全体)」。
    func selectPlaylist(_ playlistID: UUID?) {
        if let playlistID {
            guard playlists.contains(where: { $0.id == playlistID }) else {
                return
            }
        }
        let playlistChanged = selectedPlaylistID != playlistID
        selectedPlaylistID = playlistID
        if playlistChanged {
            clearPinCurrentVideo()
        }
        syncActivePlaylistPaths()

        if let current = currentPlaybackEntry, registeredPlaybackEntries.contains(current) {
            if case .video(let path) = current {
                currentVideoIndex = registeredVideoPaths.firstIndex(of: path)
            }
            persistPlaylistState()
            return
        }

        if let firstEntry = registeredPlaybackEntries.first {
            selectPlaybackEntry(firstEntry, clearsPin: true)
        } else if let currentPath = currentVideoPath,
                  libraryVideoPaths.contains(currentPath)
        {
            // 空のプレイリストに切り替えた場合。再生中の動画はキュー外だが
            // 壁紙を突然消すより再生継続の方が安全なのでそのままにする。
            currentVideoIndex = nil
            persistPlaylistState()
        } else if isWebWallpaperActive {
            // 空のプレイリストに切り替えた場合。再生中のWeb壁紙はキュー外だが
            // 壁紙を突然消すより再生継続の方が安全なのでそのままにする。
            persistPlaylistState()
        } else {
            stopAllPlayers()
            clearCurrentVideoReference()
        }
    }

    @discardableResult
    func createPlaylistAndSetVideo(path: String) async -> Bool {
        guard canAddPlaylist else {
            return false
        }

        let originalSelectedID = selectedPlaylistID
        guard let newPlaylistID = createPlaylist() else {
            return false
        }
        selectedPlaylistID = newPlaylistID
        syncActivePlaylistPaths()
        persistPlaylistState()

        let beforeCount = registeredVideoPaths.count
        await setVideo(path: path)
        let didAdd = registeredVideoPaths.count > beforeCount
        if didAdd {
            return true
        }

        if let index = playlists.firstIndex(where: { $0.id == newPlaylistID }) {
            playlists.remove(at: index)
        }
        selectedPlaylistID = originalSelectedID
        ensureSelectedPlaylist()
        syncActivePlaylistPaths()
        persistPlaylistState()
        return false
    }

    /// 選択中プレイリスト(または未選択時はライブラリ全体)の再生キュー。
    /// 動画が先、Web壁紙が後の順で並ぶ(一覧のグリッド表示と同じ順序)。
    var registeredPlaybackEntries: [WallpaperPlaybackEntry] {
        registeredVideoPaths.map { .video($0) } + registeredWebWallpaperIDs.map { .web($0) }
    }

    /// 現在再生中のエントリ。動画・Web壁紙のどちらが再生中かに応じて切り替わる。
    var currentPlaybackEntry: WallpaperPlaybackEntry? {
        if wallpaperKind == .web, let currentWebWallpaperID {
            return .web(currentWebWallpaperID)
        }
        if let currentVideoPath {
            return .video(currentVideoPath)
        }
        return nil
    }

    /// 再生キュー内での現在位置。UIの「N / M」表示に使う。
    var currentPlaybackIndex: Int? {
        guard let currentPlaybackEntry else {
            return nil
        }
        return registeredPlaybackEntries.firstIndex(of: currentPlaybackEntry)
    }

    private func selectPlaybackEntry(_ entry: WallpaperPlaybackEntry, clearsPin: Bool) {
        switch entry {
        case .video(let path):
            selectRegisteredVideo(path: path, clearsPin: clearsPin)
        case .web(let id):
            let isSameEntry = wallpaperKind == .web && currentWebWallpaperID == id
            if clearsPin, pinCurrentVideo, !isSameEntry {
                clearPinCurrentVideo()
            }
            selectWebWallpaper(id: id)
        }
    }

    func playNextVideo(advancingPlaylist: Bool = false) {
        let entries = registeredPlaybackEntries
        guard !entries.isEmpty else {
            return
        }
        guard entries.count > 1 else {
            if let entry = entries.first {
                selectPlaybackEntry(entry, clearsPin: !advancingPlaylist)
            }
            return
        }
        let nextIndex = resolvedNextIndex(in: entries, forward: true)
        selectPlaybackEntry(entries[nextIndex], clearsPin: !advancingPlaylist)
    }

    func playPreviousVideo() {
        let entries = registeredPlaybackEntries
        guard !entries.isEmpty else {
            return
        }
        guard entries.count > 1 else {
            if let entry = entries.first {
                selectPlaybackEntry(entry, clearsPin: true)
            }
            return
        }
        let previousIndex = resolvedNextIndex(in: entries, forward: false)
        selectPlaybackEntry(entries[previousIndex], clearsPin: true)
    }

    private func resolvedNextIndex(in entries: [WallpaperPlaybackEntry], forward: Bool) -> Int {
        guard !entries.isEmpty else {
            return 0
        }
        let baseIndex = currentPlaybackEntry.flatMap { entries.firstIndex(of: $0) } ?? 0
        let maxIndex = entries.count - 1
        if shufflePlaybackEnabled, entries.count > 2 {
            var candidate = Int.random(in: 0 ... maxIndex)
            while candidate == baseIndex {
                candidate = Int.random(in: 0 ... maxIndex)
            }
            return candidate
        }
        if forward {
            return (baseIndex + 1) % entries.count
        }
        return (baseIndex - 1 + entries.count) % entries.count
    }

    /// 新しい動画を取り込んでライブラリへ登録し、壁紙として再生する。
    /// プレイリスト選択中はそのプレイリストにも追加される。
    func setVideo(path: String) async {
        let trimmed: String = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        let sourceURL = URL(fileURLWithPath: trimmed)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return
        }

        if libraryVideoPaths.contains(sourceURL.path) {
            addCurrentPathToSelectedPlaylistIfNeeded(sourceURL.path)
            selectRegisteredVideo(path: sourceURL.path)
            return
        }

        if let cacheDirectory = cacheDirectoryURL(), sourceURL.path.hasPrefix(cacheDirectory.path) {
            addVideoPathToLibrary(sourceURL.path)
            addCurrentPathToSelectedPlaylistIfNeeded(sourceURL.path)
            selectRegisteredVideo(path: sourceURL.path)
            return
        }

        guard let localURL: URL = await importVideoToAppSupport(from: sourceURL) else {
            return
        }

        addVideoPathToLibrary(
            localURL.path,
            preferredDisplayName: sourceURL.lastPathComponent
        )
        addCurrentPathToSelectedPlaylistIfNeeded(localURL.path)
        selectRegisteredVideo(path: localURL.path)
    }

    private func addCurrentPathToSelectedPlaylistIfNeeded(_ path: String) {
        guard let selectedPlaylistID else {
            return
        }
        _ = addRegisteredVideo(path: path, to: selectedPlaylistID)
    }

    func registeredVideoDisplayName(for path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored = registeredVideoDisplayNames[trimmed], !stored.isEmpty {
            return stored
        }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    func setRegisteredVideoDisplayName(_ displayName: String, for path: String) {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard libraryVideoPaths.contains(trimmedPath) else {
            return
        }

        let cleaned = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName =
            cleaned.isEmpty
                ? URL(fileURLWithPath: trimmedPath).lastPathComponent
                : cleaned

        guard registeredVideoDisplayNames[trimmedPath] != finalName else {
            return
        }

        registeredVideoDisplayNames[trimmedPath] = finalName
        UserDefaults.standard.set(
            registeredVideoDisplayNames,
            forKey: "registeredVideoDisplayNames"
        )
    }

    func selectRegisteredVideo(path: String, clearsPin: Bool = true) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        guard FileManager.default.fileExists(atPath: trimmed) else {
            removeRegisteredVideo(path: trimmed)
            return
        }
        let switchedFromWeb = wallpaperKind == .web
        if switchedFromWeb {
            wallpaperKind = .video
            currentWebWallpaperID = nil
            webWallpaperLoadState = .idle
            webPlayerViews.removeAll()
            UserDefaults.standard.set(WallpaperKind.video.rawValue, forKey: "wallpaperKind")
            UserDefaults.standard.removeObject(forKey: "currentWebWallpaperID")
            windowRetireWorkItem?.cancel()
            retiredWindows.removeAll()
            rebuildWindows()
        }
        let previousPath = currentVideoPath
        if clearsPin, pinCurrentVideo, previousPath != trimmed {
            clearPinCurrentVideo()
        }
        addVideoPathToLibrary(trimmed)
        currentVideoPath = trimmed
        currentVideoIndex = registeredVideoPaths.firstIndex(of: trimmed)
        UserDefaults.standard.set(trimmed, forKey: "videoPath")
        refreshPlayerPresentations()
        if !switchedFromWeb {
            scheduleWindowRebuild(delay: 0.05)
        }
        playRegisteredVideo(path: trimmed)
        persistPlaylistState()
    }

    /// ライブラリから完全に削除する。すべてのプレイリスト・表示名・配置設定からも除去される。
    func removeRegisteredVideo(path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let libraryIndex = libraryVideoPaths.firstIndex(of: trimmed) else {
            return
        }
        let queueIndexBeforeRemoval = registeredVideoPaths.firstIndex(of: trimmed)
        let wasCurrentVideoPath = currentVideoPath == trimmed
        let wasLockScreen = lockScreenVideoPath == trimmed

        libraryVideoPaths.remove(at: libraryIndex)
        for index in playlists.indices {
            playlists[index].videoPaths.removeAll { $0 == trimmed }
        }
        clearVideoOverrides(forPath: trimmed)
        clearSpaceVideos(forPath: trimmed)
        syncActivePlaylistPaths()
        registeredVideoDisplayNames.removeValue(forKey: trimmed)
        UserDefaults.standard.set(
            registeredVideoDisplayNames,
            forKey: "registeredVideoDisplayNames"
        )

        if wasLockScreen {
            clearLockScreenVideoIfMissing(path: trimmed)
        }

        // Web壁紙が実際に表示中のときの currentVideoPath は「動画に戻すときの
        // フォールバック参照」でしかなく、再生には使われていない。削除しても
        // 表示中のWeb壁紙を中断せず、参照だけ片付ける。
        if wasCurrentVideoPath, isWebWallpaperActive {
            clearCurrentVideoReference()
            return
        }

        if wasCurrentVideoPath {
            if !registeredVideoPaths.isEmpty {
                let nextIndex = min(
                    queueIndexBeforeRemoval ?? 0,
                    registeredVideoPaths.count - 1
                )
                selectRegisteredVideo(path: registeredVideoPaths[nextIndex])
            } else {
                stopAllPlayers()
                clearCurrentVideoReference()
            }
            return
        }

        refreshCurrentVideoIndex()
        persistPlaylistState()
    }

    /// currentVideoPath/currentVideoIndex の参照を消して永続化する。
    /// 再生の停止は呼び出し側の責務(停止すべきかは文脈依存のため)。
    private func clearCurrentVideoReference() {
        currentVideoPath = nil
        currentVideoIndex = nil
        UserDefaults.standard.removeObject(forKey: "videoPath")
        persistPlaylistState()
    }

    private func refreshCurrentVideoIndex() {
        if let currentPath = currentVideoPath,
           let existingIndex = registeredVideoPaths.firstIndex(of: currentPath)
        {
            currentVideoIndex = existingIndex
        } else {
            currentVideoIndex = nil
        }
    }

    /// 選択中プレイリストが削除済みなら「すべて(nil)」へ戻す。
    func ensureSelectedPlaylist() {
        if let selectedPlaylistID,
           !playlists.contains(where: { $0.id == selectedPlaylistID })
        {
            self.selectedPlaylistID = nil
        }
    }

    /// 再生キューを更新する。プレイリスト選択中はその中身、未選択ならライブラリ全体。
    func syncActivePlaylistPaths() {
        ensureSelectedPlaylist()
        if let selectedPlaylistID,
           let index = playlists.firstIndex(where: { $0.id == selectedPlaylistID })
        {
            registeredVideoPaths = playlists[index].videoPaths
            registeredWebWallpaperIDs = webWallpaperFeatureEnabled ? playlists[index].webWallpaperIDs : []
        } else {
            registeredVideoPaths = libraryVideoPaths
            registeredWebWallpaperIDs = webWallpaperFeatureEnabled ? webWallpaperSources.map(\.id) : []
        }
        pruneWallpaperPresentationsForExistingPaths()
        normalizePlaybackConstraints()
    }
}

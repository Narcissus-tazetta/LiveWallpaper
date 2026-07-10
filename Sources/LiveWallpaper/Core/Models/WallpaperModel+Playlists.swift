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

    func playlistContainsVideo(_ playlistID: UUID, path: String) -> Bool {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else {
            return false
        }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return playlists[index].videoPaths.contains(trimmed)
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
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else {
            return false
        }
        addVideoPathToLibrary(trimmed)
        if !playlists[index].videoPaths.contains(trimmed) {
            playlists[index].videoPaths.append(trimmed)
        }
        if selectedPlaylistID == playlistID {
            syncActivePlaylistPaths()
            refreshCurrentVideoIndex()
        }
        persistPlaylistState()
        return true
    }

    /// プレイリストから参照だけを外す。ライブラリ・他プレイリストには影響しない。
    /// 再生中の動画を外した場合も再生は継続する(次送りでキュー先頭へ戻る)。
    @discardableResult
    func removeVideo(path: String, fromPlaylist playlistID: UUID) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }) else {
            return false
        }
        guard let pathIndex = playlists[playlistIndex].videoPaths.firstIndex(of: trimmed) else {
            return false
        }
        playlists[playlistIndex].videoPaths.remove(at: pathIndex)
        if selectedPlaylistID == playlistID {
            syncActivePlaylistPaths()
            refreshCurrentVideoIndex()
        }
        persistPlaylistState()
        return true
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

        if let currentPath = currentVideoPath,
           registeredVideoPaths.contains(currentPath)
        {
            currentVideoIndex = registeredVideoPaths.firstIndex(of: currentPath)
            persistPlaylistState()
            return
        }

        if let firstPath = registeredVideoPaths.first {
            selectRegisteredVideo(path: firstPath)
        } else if let currentPath = currentVideoPath,
                  libraryVideoPaths.contains(currentPath)
        {
            // 空のプレイリストに切り替えた場合。再生中の動画はキュー外だが
            // 壁紙を突然消すより再生継続の方が安全なのでそのままにする。
            currentVideoIndex = nil
            persistPlaylistState()
        } else {
            stopAllPlayers()
            currentVideoPath = nil
            currentVideoIndex = nil
            UserDefaults.standard.removeObject(forKey: "videoPath")
            persistPlaylistState()
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

    func playNextVideo(advancingPlaylist: Bool = false) {
        guard !registeredVideoPaths.isEmpty else {
            return
        }
        guard registeredVideoPaths.count > 1 else {
            if let currentPath = currentVideoPath {
                selectRegisteredVideo(path: currentPath, clearsPin: !advancingPlaylist)
            }
            return
        }
        let nextIndex = resolvedNextIndex(forward: true)
        selectRegisteredVideo(
            path: registeredVideoPaths[nextIndex],
            clearsPin: !advancingPlaylist
        )
    }

    func playPreviousVideo() {
        guard !registeredVideoPaths.isEmpty else {
            return
        }
        guard registeredVideoPaths.count > 1 else {
            if let currentPath = currentVideoPath {
                selectRegisteredVideo(path: currentPath, clearsPin: true)
            }
            return
        }
        let previousIndex = resolvedNextIndex(forward: false)
        selectRegisteredVideo(path: registeredVideoPaths[previousIndex], clearsPin: true)
    }

    private func resolvedNextIndex(forward: Bool) -> Int {
        guard !registeredVideoPaths.isEmpty else {
            return 0
        }
        let baseIndex = currentVideoIndex ?? 0
        let maxIndex = registeredVideoPaths.count - 1
        if shufflePlaybackEnabled, registeredVideoPaths.count > 2 {
            var candidate = Int.random(in: 0 ... maxIndex)
            while candidate == baseIndex {
                candidate = Int.random(in: 0 ... maxIndex)
            }
            return candidate
        }
        if forward {
            return (baseIndex + 1) % registeredVideoPaths.count
        }
        return (baseIndex - 1 + registeredVideoPaths.count) % registeredVideoPaths.count
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
        let wasCurrent = currentVideoPath == trimmed
        let wasLockScreen = lockScreenVideoPath == trimmed

        libraryVideoPaths.remove(at: libraryIndex)
        for index in playlists.indices {
            playlists[index].videoPaths.removeAll { $0 == trimmed }
        }
        syncActivePlaylistPaths()
        registeredVideoDisplayNames.removeValue(forKey: trimmed)
        UserDefaults.standard.set(
            registeredVideoDisplayNames,
            forKey: "registeredVideoDisplayNames"
        )

        if wasLockScreen {
            clearLockScreenVideoIfMissing(path: trimmed)
        }

        if wasCurrent {
            if !registeredVideoPaths.isEmpty {
                let nextIndex = min(
                    queueIndexBeforeRemoval ?? 0,
                    registeredVideoPaths.count - 1
                )
                selectRegisteredVideo(path: registeredVideoPaths[nextIndex])
            } else {
                stopAllPlayers()
                currentVideoPath = nil
                currentVideoIndex = nil
                UserDefaults.standard.removeObject(forKey: "videoPath")
                persistPlaylistState()
            }
            return
        }

        refreshCurrentVideoIndex()
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
        } else {
            registeredVideoPaths = libraryVideoPaths
        }
        pruneWallpaperPresentationsForExistingPaths()
        normalizePlaybackConstraints()
    }
}

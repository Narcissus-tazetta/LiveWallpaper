import Foundation

@MainActor
extension WallpaperModel {
    func removeEmptyPlaylists() {
        let nonEmpty = playlists.filter { !$0.videoPaths.isEmpty }
        guard nonEmpty.count != playlists.count else {
            return
        }

        playlists = nonEmpty
        ensureSelectedPlaylist()
        syncActivePlaylistPaths()

        let validPaths = Set(playlists.flatMap(\.videoPaths))
        if let currentPath = currentVideoPath,
           !validPaths.contains(currentPath)
        {
            if let firstPath = registeredVideoPaths.first {
                selectRegisteredVideo(path: firstPath)
                return
            }
            stopAllPlayers()
            currentVideoPath = nil
            currentVideoIndex = nil
            UserDefaults.standard.removeObject(forKey: "videoPath")
        } else if let currentPath = currentVideoPath,
                  let index = registeredVideoPaths.firstIndex(of: currentPath)
        {
            currentVideoIndex = index
        } else {
            currentVideoPath = registeredVideoPaths.first
            currentVideoIndex = currentVideoPath.flatMap { registeredVideoPaths.firstIndex(of: $0) }
        }

        pruneDisplayNamesForExistingPaths()
        persistPlaylistState()
    }

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
        if selectedPlaylistID == nil {
            selectedPlaylistID = playlist.id
            syncActivePlaylistPaths()
        }
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
        if !playlists[index].videoPaths.contains(trimmed) {
            playlists[index].videoPaths.append(trimmed)
        }
        if selectedPlaylistID == playlistID {
            syncActivePlaylistPaths()
            if let currentPath = currentVideoPath {
                currentVideoIndex = registeredVideoPaths.firstIndex(of: currentPath)
            }
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

    func removePlaylist(_ playlistID: UUID) {
        guard let removeIndex = playlists.firstIndex(where: { $0.id == playlistID }) else {
            return
        }
        let removedPaths = Set(playlists[removeIndex].videoPaths)
        let removedCurrent = removedPaths.contains(currentVideoPath ?? "")

        playlists.remove(at: removeIndex)
        ensureSelectedPlaylist()
        syncActivePlaylistPaths()

        if removedCurrent {
            if let firstPath = registeredVideoPaths.first {
                selectRegisteredVideo(path: firstPath)
            } else {
                stopAllPlayers()
                currentVideoPath = nil
                currentVideoIndex = nil
                UserDefaults.standard.removeObject(forKey: "videoPath")
            }
        } else if let currentPath = currentVideoPath,
                  let existingIndex = registeredVideoPaths.firstIndex(of: currentPath)
        {
            currentVideoIndex = existingIndex
        } else {
            currentVideoPath = registeredVideoPaths.first
            currentVideoIndex = currentVideoPath.flatMap { registeredVideoPaths.firstIndex(of: $0) }
        }

        pruneDisplayNamesForExistingPaths()
        persistPlaylistState()
    }

    func selectPlaylist(_ playlistID: UUID) {
        guard playlists.contains(where: { $0.id == playlistID }) else {
            return
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
                playVideo(url: URL(fileURLWithPath: currentPath))
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
                playVideo(url: URL(fileURLWithPath: currentPath))
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

    func setVideo(path: String) async {
        let trimmed: String = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        let sourceURL = URL(fileURLWithPath: trimmed)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return
        }

        ensureSelectedPlaylist()

        if registeredVideoPaths.contains(sourceURL.path) {
            selectRegisteredVideo(path: sourceURL.path)
            return
        }

        if let cacheDirectory = cacheDirectoryURL(), sourceURL.path.hasPrefix(cacheDirectory.path) {
            addVideoPathToSelectedPlaylist(sourceURL.path)
            selectRegisteredVideo(path: sourceURL.path)
            return
        }

        guard let localURL: URL = await importVideoToAppSupport(from: sourceURL) else {
            return
        }

        addVideoPathToSelectedPlaylist(
            localURL.path,
            preferredDisplayName: sourceURL.lastPathComponent
        )
        selectRegisteredVideo(path: localURL.path)
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
        guard registeredVideoPaths.contains(trimmedPath) else {
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
        let previousPath = currentVideoPath
        if clearsPin, pinCurrentVideo, previousPath != trimmed {
            clearPinCurrentVideo()
        }
        addVideoPathToSelectedPlaylist(trimmed)
        syncActivePlaylistPaths()
        currentVideoPath = trimmed
        currentVideoIndex = registeredVideoPaths.firstIndex(of: trimmed)
        UserDefaults.standard.set(trimmed, forKey: "videoPath")
        refreshPlayerPresentations()
        playVideo(url: URL(fileURLWithPath: trimmed))
        persistPlaylistState()
    }

    func removeRegisteredVideo(path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let selectedIndex = selectedPlaylistIndex() else {
            return
        }
        guard let index = playlists[selectedIndex].videoPaths.firstIndex(of: trimmed) else {
            return
        }
        let wasCurrent = currentVideoPath == trimmed
        playlists[selectedIndex].videoPaths.remove(at: index)
        syncActivePlaylistPaths()
        registeredVideoDisplayNames.removeValue(forKey: trimmed)
        UserDefaults.standard.set(
            registeredVideoDisplayNames,
            forKey: "registeredVideoDisplayNames"
        )

        if playlists[selectedIndex].videoPaths.isEmpty {
            playlists.remove(at: selectedIndex)
            ensureSelectedPlaylist()
            syncActivePlaylistPaths()
        }

        if wasCurrent {
            if !registeredVideoPaths.isEmpty {
                let nextIndex = min(index, registeredVideoPaths.count - 1)
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

        if let currentPath = currentVideoPath,
           let existingIndex = registeredVideoPaths.firstIndex(of: currentPath)
        {
            currentVideoIndex = existingIndex
        } else {
            currentVideoIndex = nil
        }
        persistPlaylistState()
    }

    private func addVideoPathToSelectedPlaylist(
        _ path: String,
        preferredDisplayName: String? = nil
    ) {
        guard !path.isEmpty else {
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return
        }

        if playlists.isEmpty {
            playlists = [WallpaperPlaylist(id: UUID(), name: "プレイリスト1", videoPaths: [])]
            selectedPlaylistID = playlists.first?.id
        }
        ensureSelectedPlaylist()
        guard let index = selectedPlaylistIndex() else {
            return
        }

        if !playlists[index].videoPaths.contains(path) {
            playlists[index].videoPaths.append(path)
        }

        if let preferredDisplayName,
           !preferredDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           registeredVideoDisplayNames[path] == nil
        {
            registeredVideoDisplayNames[path] = preferredDisplayName
            UserDefaults.standard.set(
                registeredVideoDisplayNames,
                forKey: "registeredVideoDisplayNames"
            )
        }

        syncActivePlaylistPaths()
        persistPlaylistState()
    }

    private func selectedPlaylistIndex() -> Int? {
        guard let selectedPlaylistID else {
            return nil
        }
        return playlists.firstIndex(where: { $0.id == selectedPlaylistID })
    }

    func ensureSelectedPlaylist() {
        if let selectedPlaylistID,
           playlists.contains(where: { $0.id == selectedPlaylistID })
        {
            return
        }
        selectedPlaylistID = playlists.first?.id
    }

    func syncActivePlaylistPaths() {
        ensureSelectedPlaylist()
        if let index = selectedPlaylistIndex() {
            registeredVideoPaths = playlists[index].videoPaths
        } else {
            registeredVideoPaths = []
        }
        pruneWallpaperPresentationsForExistingPaths()
        normalizePlaybackConstraints()
    }
}

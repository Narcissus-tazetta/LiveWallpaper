import Foundation

@MainActor
extension WallpaperModel {
    var activeWebWallpaperSource: WebWallpaperSource? {
        if let external = activeExternalWallpaper { return external.webSource }
        guard let id = currentWebWallpaperID else {
            return nil
        }
        return webWallpaperSources.first { $0.id == id }
    }

    var isWebWallpaperActive: Bool {
        if let external = activeExternalWallpaper { return external.webSource != nil }
        return wallpaperKind == .web && activeWebWallpaperSource != nil
    }

    @discardableResult
    func addWebWallpaper(urlString: String) throws -> WebWallpaperSource {
        let url = try WebWallpaperURLResolver.normalizeURLString(urlString)
        let canonicalKey = WebWallpaperURLResolver.canonicalKey(for: url)
        if let existing = webWallpaperSources.first(where: {
            WebWallpaperURLResolver.canonicalKey(for: $0.url) == canonicalKey
        }) {
            selectWebWallpaper(id: existing.id)
            webWallpaperErrorMessage = nil
            return existing
        }

        var source = WebWallpaperSource(url: url)
        if let videoID = WebWallpaperURLResolver.youtubeVideoID(from: url) {
            source.displayName = "YouTube (\(videoID))"
        } else if let videoID = WebWallpaperURLResolver.vimeoVideoID(from: url) {
            source.displayName = "Vimeo (\(videoID))"
        }
        webWallpaperSources.append(source)
        webWallpaperErrorMessage = nil
        if selectedPlaylistID == nil {
            syncActivePlaylistPaths()
        }
        selectWebWallpaper(id: source.id)
        persistWebWallpaperState()
        return source
    }

    func selectWebWallpaper(id: UUID, clearsPin: Bool = true) {
        guard webWallpaperSources.contains(where: { $0.id == id }) else {
            return
        }
        if clearsPin, currentPlaybackEntry != .web(id) {
            clearPinCurrentVideo()
        }
        performSharedWallpaperTransition(to: .web(id)) {
            applyWebWallpaperSelection(id: id)
        }
    }

    private func applyWebWallpaperSelection(id: UUID) {
        stopExternalWallpaper()
        wallpaperKind = .web
        currentWebWallpaperID = id
        webWallpaperLoadState = .loading
        webWallpaperErrorMessage = nil
        stopAllPlayers()
        UserDefaults.standard.set(WallpaperKind.web.rawValue, forKey: PrefsKey.wallpaperKind)
        UserDefaults.standard.set(id.uuidString, forKey: PrefsKey.currentWebWallpaperID)
        scheduleWindowRebuild(delay: 0.05)
        webWallpaperLoadState = .loading
        persistWebWallpaperState()
        evaluateForegroundCoverageState()
    }

    func removeWebWallpaper(id: UUID) {
        guard let index = webWallpaperSources.firstIndex(where: { $0.id == id }) else {
            return
        }
        if let folder = webWallpaperSources[index].localFolderPath,
           LocalWebWallpaperPackage.owns(URL(fileURLWithPath: folder)),
           FileManager.default.fileExists(atPath: folder) {
            localWebWallpaperServer.remove(folder: URL(fileURLWithPath: folder))
            do { try FileManager.default.removeItem(atPath: folder) }
            catch {
                webWallpaperErrorMessage = error.localizedDescription
                return
            }
        }
        let wasActive = currentWebWallpaperID == id
        webWallpaperSources.remove(at: index)
        pruneWebWallpaperIDsFromPlaylists()
        pruneScheduleRules(referencingWebWallpaperID: id)
        syncActivePlaylistPaths()

        if wasActive {
            if let next = webWallpaperSources.first {
                selectWebWallpaper(id: next.id)
            } else {
                stopWebWallpaper()
                wallpaperKind = .video
                currentWebWallpaperID = nil
                webWallpaperLoadState = .idle
                UserDefaults.standard.set(WallpaperKind.video.rawValue, forKey: PrefsKey.wallpaperKind)
                UserDefaults.standard.removeObject(forKey: PrefsKey.currentWebWallpaperID)
                scheduleWindowRebuild(delay: 0.05)
                if let currentPath = currentVideoPath,
                   FileManager.default.fileExists(atPath: currentPath)
                {
                    playRegisteredVideo(path: currentPath)
                }
            }
        }
        persistWebWallpaperState()
    }

    func setWebWallpaperDisplayName(_ displayName: String, for id: UUID) {
        guard let index = webWallpaperSources.firstIndex(where: { $0.id == id }) else {
            return
        }
        let cleaned = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = cleaned.isEmpty
            ? (webWallpaperSources[index].url.host ?? webWallpaperSources[index].url.absoluteString)
            : cleaned
        guard webWallpaperSources[index].displayName != finalName else {
            return
        }
        webWallpaperSources[index].displayName = finalName
        persistWebWallpaperState()
    }

    func stopWebWallpaper() {
        localWebLoadTask?.cancel()
        localWebLoadTask = nil
        cancelWebDeepSuspend()
        for view in webPlayerViews {
            view.stopLoading()
            view.onLoadStateChanged = nil
        }
    }

    func loadWebWallpaper(source: WebWallpaperSource) {
        guard !webPlayerViews.isEmpty else {
            webWallpaperLoadState = .loading
            return
        }

        localWebLoadTask?.cancel()
        if let folder = source.localFolderPath {
            localWebLoadTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let url = try await localWebWallpaperServer.url(folder: URL(fileURLWithPath: folder))
                    try Task.checkCancellation()
                    guard isWebWallpaperActive, activeWebWallpaperSource?.id == source.id else { return }
                    applyWebRequest(WebWallpaperPlaybackRequest(
                        loadContent: .url(url), layoutMode: .generic,
                        canonicalKey: "local:\(source.id)", isLocalPackage: true
                    ))
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, activeWebWallpaperSource?.id == source.id else { return }
                    webWallpaperLoadState = .failed
                    webWallpaperErrorMessage = error.localizedDescription
                    AppLog.externalWallpapers.error("local web load failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } else {
            applyWebRequest(WebWallpaperURLResolver.resolve(originalURL: source.url, audioEnabled: audioEnabled))
        }
    }

    private func applyWebRequest(_ request: WebWallpaperPlaybackRequest) {
        let reportLoadState: (WebWallpaperLoadState) -> Void = { [weak self] state in
            self?.webWallpaperLoadState = state
        }
        for (index, view) in webPlayerViews.enumerated() {
            view.onLoadStateChanged = index == 0 ? reportLoadState : nil
            configureLocalWebEnvironment(view)
            view.load(request: request, audioEnabled: audioEnabled)
        }
    }

    private func configureLocalWebEnvironment(_ view: WebPlayerView) {
        let fps: Double
        switch frameRateLimit {
        case .fps30: fps = 30
        case .fps60: fps = 60
        case .off: fps = Double(view.window?.screen?.maximumFramesPerSecond ?? 60)
        }
        view.setHostEnvironment(volume: audioVolume, fps: fps, language: appLocale.identifier)
        configureLocalWebProperties(view)
    }

    func refreshLocalWebEnvironment() {
        for view in webPlayerViews { configureLocalWebEnvironment(view) }
    }

    func refreshWebWallpaperState() {
        guard isWebWallpaperActive else {
            return
        }
        scheduleWindowRebuild(delay: 0.05)
    }

    func applyWebAudioSettings() {
        guard isWebWallpaperActive, let source = activeWebWallpaperSource else {
            return
        }
        if WebWallpaperURLResolver.requiresReloadForAudioChange(source.url) {
            loadWebWallpaper(source: source)
            return
        }
        for view in webPlayerViews {
            view.setAudioEnabled(audioEnabled)
        }
    }

    func applyWebSuspensionState() {
        guard !webPlayerViews.isEmpty else {
            cancelWebDeepSuspend()
            return
        }
        let displayIDs = (0 ..< webPlayerViews.count).map { displayIDForWindow(at: $0) }
        let allSuspended = displayIDs.allSatisfy { suspendedDisplayIDs.contains($0) }
        for (index, view) in webPlayerViews.enumerated() {
            view.setSuspended(allSuspended || suspendedDisplayIDs.contains(displayIDs[index]))
        }

        // Freeing the page only pays off once every display is covered — a page
        // still visible somewhere has to stay loaded regardless. Mirrors the
        // shared video player's deep suspend, just on a longer fuse: rebuilding a
        // web page costs a network round trip, so it must not fire on the brief
        // coverage of an app switch.
        if allSuspended {
            scheduleWebDeepSuspend()
        } else {
            cancelWebDeepSuspend()
        }
    }

    func restoreWebWallpaperState() {
        if let kindValue = UserDefaults.standard.string(forKey: PrefsKey.wallpaperKind),
           let restoredKind = WallpaperKind(rawValue: kindValue)
        {
            wallpaperKind = restoredKind
        }

        if let decoded = UserDefaults.standard.decodedJSON(
            [WebWallpaperSource].self, forKey: PrefsKey.webWallpaperSourcesData
        ) {
            webWallpaperSources = decoded.filter { source in
                if let folder = source.localFolderPath {
                    return LocalWebWallpaperPackage.owns(URL(fileURLWithPath: folder))
                        && (try? LocalWebWallpaperPackage.load(folder: URL(fileURLWithPath: folder))) != nil
                }
                return (try? WebWallpaperURLResolver.validateURL(source.url)) != nil
            }
        }

        // 不変条件: プレイリストが参照するWeb壁紙は必ず webWallpaperSources に存在する
        pruneWebWallpaperIDsFromPlaylists()
        // registeredWebWallpaperIDs の再同期(syncActivePlaylistPaths)は呼び出し元の
        // restore() に任せる。ここではまだ webWallpaperFeatureEnabled が
        // UserDefaults から復元されていない(デフォルト値のまま)ため、
        // ここで呼ぶと再生キューへWeb壁紙が反映されないまま固定されてしまう。

        if let savedID = UserDefaults.standard.string(forKey: PrefsKey.currentWebWallpaperID),
           let uuid = UUID(uuidString: savedID),
           webWallpaperSources.contains(where: { $0.id == uuid })
        {
            currentWebWallpaperID = uuid
        } else {
            currentWebWallpaperID = nil
            if wallpaperKind == .web {
                wallpaperKind = .video
            }
        }
    }

    func persistWebWallpaperState() {
        schedulePersistedStateFlush()
    }

    /// 不変条件の維持: プレイリストが参照するWeb壁紙は必ず webWallpaperSources に存在する。
    /// 変更があった場合のみ persistPlaylistState() を呼ぶため、呼び出し側の実行順序に依存しない。
    private func pruneWebWallpaperIDsFromPlaylists() {
        let validIDs = Set(webWallpaperSources.map(\.id))
        var didPrune = false
        for index in playlists.indices {
            let originalCount = playlists[index].webWallpaperIDs.count
            playlists[index].webWallpaperIDs.removeAll { !validIDs.contains($0) }
            if playlists[index].webWallpaperIDs.count != originalCount {
                didPrune = true
            }
        }
        if didPrune {
            persistPlaylistState()
        }
    }

    func clearWebWallpaperState() {
        stopWebWallpaper()
        let folders = webWallpaperSources.compactMap(\.localFolderPath).map { URL(fileURLWithPath: $0) }
            .filter { LocalWebWallpaperPackage.owns($0) }
        for folder in folders { localWebWallpaperServer.remove(folder: folder) }
        removeLeftovers(of: folders)
        webWallpaperSources.removeAll()
        pruneWebWallpaperIDsFromPlaylists()
        currentWebWallpaperID = nil
        wallpaperKind = .video
        webWallpaperLoadState = .idle
        webWallpaperErrorMessage = nil
        UserDefaults.standard.set(WallpaperKind.video.rawValue, forKey: PrefsKey.wallpaperKind)
        UserDefaults.standard.removeObject(forKey: PrefsKey.currentWebWallpaperID)
        UserDefaults.standard.removeObject(forKey: PrefsKey.webWallpaperSourcesData)
        scheduleWindowRebuild(delay: 0.05)
    }
}

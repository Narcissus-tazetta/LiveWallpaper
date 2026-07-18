import Foundation

enum WebWallpaperURLError: LocalizedError {
    case emptyInput
    case invalidURL
    case unsupportedScheme

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "URLを入力してください"
        case .invalidURL:
            return "有効なURLを入力してください"
        case .unsupportedScheme:
            return "http または https のURLのみ対応しています"
        }
    }
}

@MainActor
extension WallpaperModel {
    var activeWebWallpaperSource: WebWallpaperSource? {
        guard let id = currentWebWallpaperID else {
            return nil
        }
        return webWallpaperSources.first { $0.id == id }
    }

    var isWebWallpaperActive: Bool {
        wallpaperKind == .web && activeWebWallpaperSource != nil
    }

    static func normalizeWebWallpaperURLString(_ input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WebWallpaperURLError.emptyInput
        }

        let candidate: URL? =
            if let direct = URL(string: trimmed), direct.scheme != nil {
                direct
            } else {
                URL(string: "https://\(trimmed)")
            }

        guard let url = candidate else {
            throw WebWallpaperURLError.invalidURL
        }
        try validateWebWallpaperURL(url)
        return url
    }

    static func validateWebWallpaperURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw WebWallpaperURLError.unsupportedScheme
        }
        guard let host = url.host, !host.isEmpty else {
            throw WebWallpaperURLError.invalidURL
        }
    }

    @discardableResult
    func addWebWallpaper(urlString: String) throws -> WebWallpaperSource {
        let url = try Self.normalizeWebWallpaperURLString(urlString)
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

    func selectWebWallpaper(id: UUID) {
        guard webWallpaperSources.contains(where: { $0.id == id }) else {
            return
        }
        wallpaperKind = .web
        currentWebWallpaperID = id
        webWallpaperLoadState = .loading
        webWallpaperErrorMessage = nil
        stopAllPlayers()
        UserDefaults.standard.set(WallpaperKind.web.rawValue, forKey: "wallpaperKind")
        UserDefaults.standard.set(id.uuidString, forKey: "currentWebWallpaperID")
        scheduleWindowRebuild(delay: 0.05)
        webWallpaperLoadState = .loading
        persistWebWallpaperState()
        evaluateForegroundCoverageState()
    }

    func removeWebWallpaper(id: UUID) {
        guard let index = webWallpaperSources.firstIndex(where: { $0.id == id }) else {
            return
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
                UserDefaults.standard.set(WallpaperKind.video.rawValue, forKey: "wallpaperKind")
                UserDefaults.standard.removeObject(forKey: "currentWebWallpaperID")
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

        let request = WebWallpaperURLResolver.resolve(
            originalURL: source.url,
            audioEnabled: audioEnabled
        )
        let reportLoadState: (WebWallpaperLoadState) -> Void = { [weak self] state in
            self?.webWallpaperLoadState = state
        }
        for (index, view) in webPlayerViews.enumerated() {
            view.onLoadStateChanged = index == 0 ? reportLoadState : nil
            view.load(request: request, audioEnabled: audioEnabled)
        }
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
        if let kindValue = UserDefaults.standard.string(forKey: "wallpaperKind"),
           let restoredKind = WallpaperKind(rawValue: kindValue)
        {
            wallpaperKind = restoredKind
        }

        if let data = UserDefaults.standard.data(forKey: "webWallpaperSourcesData"),
           let decoded = try? JSONDecoder().decode([WebWallpaperSource].self, from: data)
        {
            webWallpaperSources = decoded.filter { source in
                (try? Self.validateWebWallpaperURL(source.url)) != nil
            }
        }

        // 不変条件: プレイリストが参照するWeb壁紙は必ず webWallpaperSources に存在する
        pruneWebWallpaperIDsFromPlaylists()
        // registeredWebWallpaperIDs の再同期(syncActivePlaylistPaths)は呼び出し元の
        // restore() に任せる。ここではまだ webWallpaperFeatureEnabled が
        // UserDefaults から復元されていない(デフォルト値のまま)ため、
        // ここで呼ぶと再生キューへWeb壁紙が反映されないまま固定されてしまう。

        if let savedID = UserDefaults.standard.string(forKey: "currentWebWallpaperID"),
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
        webWallpaperSources.removeAll()
        pruneWebWallpaperIDsFromPlaylists()
        currentWebWallpaperID = nil
        wallpaperKind = .video
        webWallpaperLoadState = .idle
        webWallpaperErrorMessage = nil
        UserDefaults.standard.set(WallpaperKind.video.rawValue, forKey: "wallpaperKind")
        UserDefaults.standard.removeObject(forKey: "currentWebWallpaperID")
        UserDefaults.standard.removeObject(forKey: "webWallpaperSourcesData")
        scheduleWindowRebuild(delay: 0.05)
    }
}

import Foundation

@MainActor
extension WallpaperModel {
    func restoreState() {
        clickThrough = UserDefaults.standard.object(forKey: "clickThrough") as? Bool ?? true
        if let modeValue: String = UserDefaults.standard.string(forKey: "displayMode"),
           let restoredMode = DisplayMode(rawValue: modeValue)
        {
            displayMode = restoredMode
        }
        if let fitValue: String = UserDefaults.standard.string(forKey: "fitMode"),
           let restoredFit = VideoFitMode(rawValue: fitValue)
        {
            fitMode = restoredFit
        }
        playlistPlaybackEnabled =
            UserDefaults.standard.object(forKey: "playlistPlaybackEnabled") as? Bool ?? false
        shufflePlaybackEnabled =
            UserDefaults.standard.object(forKey: "shufflePlaybackEnabled") as? Bool ?? false
        if !playlistPlaybackEnabled {
            shufflePlaybackEnabled = false
        }
        lightweightMode = UserDefaults.standard.object(forKey: "lightweightMode") as? Bool ?? false
        audioEnabled = UserDefaults.standard.object(forKey: "audioEnabled") as? Bool ?? false
        restorePlaybackSettingState()
        if let qualityValue = UserDefaults.standard.string(forKey: "qualityPreset"),
           let restoredQuality = QualityPreset(rawValue: qualityValue)
        {
            qualityPreset = restoredQuality
        }
        autoFrameRateEnabled =
            UserDefaults.standard.object(forKey: "autoFrameRateEnabled") as? Bool ?? true
        let savedAudioVolume: Float = UserDefaults.standard.float(forKey: "audioVolume")
        audioVolume = savedAudioVolume == 0 ? 1.0 : min(max(savedAudioVolume, 0), 1)
        if UserDefaults.standard.object(forKey: "audioVolume") is NSNumber {
            audioVolume = min(max(savedAudioVolume, 0), 1)
        }
        if let appLanguageValue = UserDefaults.standard.string(forKey: "appLanguage"),
           let restoredAppLanguage = AppLanguage(rawValue: appLanguageValue)
        {
            appLanguage = restoredAppLanguage
        }
        applyAudioSettings()
        applyLightweightSettings()
        suspendWhenOtherAppFullScreen =
            UserDefaults.standard.object(forKey: "suspendWhenOtherAppFullScreen") as? Bool ?? false
        if let savedExclusions = UserDefaults.standard.stringArray(
            forKey: "suspendExclusionBundleIDs"
        ) {
            suspendExclusionBundleIDs = Array(
                Set(savedExclusions.map(normalizeBundleID).filter { !$0.isEmpty })
            )
            .sorted()
        }
        suspendWhenOtherAppStatusMessage = nil

        if let playlistData = UserDefaults.standard.data(forKey: "playlistsData"),
           let decoded = try? JSONDecoder().decode([WallpaperPlaylist].self, from: playlistData)
        {
            playlists = decoded.map { playlist in
                var cleaned = playlist
                cleaned.videoPaths = cleaned.videoPaths.filter {
                    FileManager.default.fileExists(atPath: $0)
                }
                return cleaned
            }
            .filter { !$0.videoPaths.isEmpty }
        } else {
            let savedPaths = UserDefaults.standard.stringArray(forKey: "registeredVideoPaths") ?? []
            let cleaned = savedPaths.filter { FileManager.default.fileExists(atPath: $0) }
            if !cleaned.isEmpty {
                playlists = [
                    WallpaperPlaylist(
                        id: UUID(),
                        name: "\(localizedString("プレイリスト"))1",
                        videoPaths: cleaned
                    )
                ]
            }
        }

        if let savedPlaylistID = UserDefaults.standard.string(forKey: "selectedPlaylistID"),
           let uuid = UUID(uuidString: savedPlaylistID),
           playlists.contains(where: { $0.id == uuid })
        {
            selectedPlaylistID = uuid
        } else {
            selectedPlaylistID = playlists.first?.id
        }

        syncActivePlaylistPaths()

        let allPaths = Set(playlists.flatMap(\.videoPaths))
        if let savedDisplayNames = UserDefaults.standard.dictionary(
            forKey: "registeredVideoDisplayNames"
        )
            as? [String: String]
        {
            registeredVideoDisplayNames = savedDisplayNames.filter {
                allPaths.contains($0.key)
            }
        }
        if let savedPath: String = UserDefaults.standard.string(forKey: "videoPath"),
           FileManager.default.fileExists(atPath: savedPath),
           let playlistContainingPath =
           playlists
               .first(where: { $0.videoPaths.contains(savedPath) })
        {
            selectedPlaylistID = playlistContainingPath.id
            syncActivePlaylistPaths()
            currentVideoPath = savedPath
        } else {
            currentVideoPath = registeredVideoPaths.first
        }
        if let currentPath = currentVideoPath,
           let restoredIndex = registeredVideoPaths.firstIndex(of: currentPath)
        {
            currentVideoIndex = restoredIndex
        } else {
            currentVideoIndex = nil
        }
        if let data = UserDefaults.standard.data(forKey: wallpaperPresentationStorageKey),
           let decoded = try? JSONDecoder().decode(
               [String: [String: WallpaperPresentation]].self,
               from: data
           )
        {
            wallpaperPresentationByPath = decoded.filter { allPaths.contains($0.key) }
        }
        persistPlaylistState()
    }

    private func restorePlaybackSettingState() {
        if let frameRateValue = UserDefaults.standard.string(forKey: "frameRateLimit"),
           let restoredFrameRate = FrameRateLimit(rawValue: frameRateValue)
        {
            frameRateLimit = restoredFrameRate
        }
        if let decodeValue = UserDefaults.standard.string(forKey: "decodeMode"),
           let restoredDecodeMode = DecodeMode(rawValue: decodeValue)
        {
            decodeMode = restoredDecodeMode
        }
        if let workProfileValue = UserDefaults.standard.string(forKey: "workProfile"),
           let restoredWorkProfile = WorkProfile(rawValue: workProfileValue)
        {
            workProfile = restoredWorkProfile
        }
    }

    func pruneDisplayNamesForExistingPaths() {
        let validPaths = Set(playlists.flatMap(\.videoPaths))
        registeredVideoDisplayNames =
            registeredVideoDisplayNames
                .filter { validPaths.contains($0.key) }
        UserDefaults.standard.set(
            registeredVideoDisplayNames,
            forKey: "registeredVideoDisplayNames"
        )
    }

    func pruneWallpaperPresentationsForExistingPaths() {
        let validPaths = Set(playlists.flatMap(\.videoPaths))
        let pruned = wallpaperPresentationByPath.filter { validPaths.contains($0.key) }
        if pruned != wallpaperPresentationByPath {
            wallpaperPresentationByPath = pruned
            persistWallpaperPresentationState()
        }
    }

    func persistWallpaperPresentationState() {
        if let data = try? JSONEncoder().encode(wallpaperPresentationByPath) {
            UserDefaults.standard.set(data, forKey: wallpaperPresentationStorageKey)
        }
    }

    func persistPlaylistState() {
        if let data = try? JSONEncoder().encode(playlists) {
            UserDefaults.standard.set(data, forKey: "playlistsData")
        }
        UserDefaults.standard.set(registeredVideoPaths, forKey: "registeredVideoPaths")
        UserDefaults.standard.set(selectedPlaylistID?.uuidString, forKey: "selectedPlaylistID")
        persistWallpaperPresentationState()
    }

    func resetSettingsToDefaults() {
        setClickThrough(true)
        setDisplayMode(.mainOnly)
        setFitMode(.fill)
        setLightweightMode(false)
        setAudioEnabled(false)
        setAudioVolume(1.0)
        setFrameRateLimit(.off)
        setDecodeMode(.automatic)
        setWorkProfile(.normal)
        setQualityPreset(.auto)
        setPlaylistPlaybackEnabled(false)
        setShufflePlaybackEnabled(false)
        autoFrameRateEnabled = true
        UserDefaults.standard.set(true, forKey: "autoFrameRateEnabled")
        setDesktopLevelOffset(.zero)
        setFullScreenAuxiliary(false)
        _ = setSuspendWhenOtherAppFullScreen(false)
        suspendExclusionBundleIDs = []
        UserDefaults.standard.removeObject(forKey: "suspendExclusionBundleIDs")
        suspendWhenOtherAppStatusMessage = nil
        startAutoFrameRateMonitoring()
    }
}

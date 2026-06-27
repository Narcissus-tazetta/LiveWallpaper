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
        if let offsetValue = UserDefaults.standard.object(forKey: "desktopLevelOffset") as? Int,
           let restoredOffset = DesktopLevelOffset(rawValue: offsetValue)
        {
            desktopLevelOffset = restoredOffset
        }
        useFullScreenAuxiliary =
            UserDefaults.standard.object(forKey: "useFullScreenAuxiliary") as? Bool ?? false
        playlistPlaybackEnabled =
            UserDefaults.standard.object(forKey: "playlistPlaybackEnabled") as? Bool ?? false
        shufflePlaybackEnabled =
            UserDefaults.standard.object(forKey: "shufflePlaybackEnabled") as? Bool ?? false
        videoLoopEnabled =
            UserDefaults.standard.object(forKey: "videoLoopEnabled") as? Bool ?? true
        if !playlistPlaybackEnabled {
            shufflePlaybackEnabled = false
        }
        pinCurrentVideo = false
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
        if UserDefaults.standard.object(forKey: "audioVolume") != nil {
            audioVolume = min(max(UserDefaults.standard.float(forKey: "audioVolume"), 0), 1)
        } else {
            audioVolume = 1.0
        }
        if let appLanguageValue = UserDefaults.standard.string(forKey: "appLanguage"),
           let restoredAppLanguage = AppLanguage(rawValue: appLanguageValue)
        {
            appLanguage = restoredAppLanguage
        }
        advancedSharingEnabled =
            UserDefaults.standard.object(forKey: "advancedSharingEnabled") as? Bool ?? false
        applyAudioSettings()
        applyLightweightSettings()
        suspendWhenOtherAppFullScreen =
            UserDefaults.standard.object(forKey: "suspendWhenOtherAppFullScreen") as? Bool ?? false
        if let detectionModeValue = UserDefaults.standard.string(
            forKey: "suspendDetectionMode"
        ),
            let restoredDetectionMode = SuspendDetectionMode(rawValue: detectionModeValue)
        {
            suspendDetectionMode = restoredDetectionMode
        }
        if let savedExclusions = UserDefaults.standard.stringArray(
            forKey: "suspendExclusionBundleIDs"
        ) {
            suspendExclusionBundleIDs = Array(
                Set(savedExclusions.map(normalizeBundleID).filter { !$0.isEmpty })
            )
            .sorted()
        }
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
        persistPlaylistStateImmediately()
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
            if restoredDecodeMode == .gpuAdaptive {
                decodeMode = .automatic
                UserDefaults.standard.set(DecodeMode.automatic.rawValue, forKey: "decodeMode")
            } else {
                decodeMode = restoredDecodeMode
            }
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
        schedulePersistedStateFlush()
    }

    func persistPlaylistState() {
        schedulePersistedStateFlush()
    }

    func setAdvancedSharingEnabled(_ enabled: Bool) {
        guard advancedSharingEnabled != enabled else {
            return
        }
        advancedSharingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "advancedSharingEnabled")
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
        setVideoLoopEnabled(true)
        clearPinCurrentVideo()
        setAutoFrameRateEnabled(true)
        setDesktopLevelOffset(.zero)
        setFullScreenAuxiliary(false)
        setAdvancedSharingEnabled(false)
        _ = setSuspendWhenOtherAppFullScreen(false)
        setSuspendDetectionMode(.frontmostAppPresence)
        suspendExclusionBundleIDs = []
        UserDefaults.standard.removeObject(forKey: "suspendExclusionBundleIDs")
        startAutoFrameRateMonitoring()
    }
}

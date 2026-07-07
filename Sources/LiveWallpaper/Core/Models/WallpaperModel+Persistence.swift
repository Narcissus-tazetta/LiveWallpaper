import AppKit
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
        refreshDesktopIconsVisibility()
        useFullScreenAuxiliary =
            UserDefaults.standard.object(forKey: "useFullScreenAuxiliary") as? Bool ?? false
        menuBarOpaqueEnabled =
            UserDefaults.standard.object(forKey: "menuBarOpaqueEnabled") as? Bool ?? false
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
        lockScreenSyncEnabled =
            UserDefaults.standard.object(forKey: "lockScreenSyncEnabled") as? Bool ?? false
        lockScreenSyncStatus = lockScreenSyncEnabled
            ? (lockScreenSyncService.isSupported ? .idle : .unsupported)
            : .disabled
        applyAudioSettings()
        applyLightweightSettings()
        suspendWhenOtherAppFullScreen =
            UserDefaults.standard.object(forKey: "suspendWhenOtherAppFullScreen") as? Bool ?? false
        suspendHighSensitivityEnabled =
            UserDefaults.standard.object(forKey: "suspendHighSensitivityEnabled") as? Bool ?? false
        suspendWhenOtherAppFrontmost =
            UserDefaults.standard.object(forKey: "suspendWhenOtherAppFrontmost") as? Bool ?? false
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
        restoreLockScreenVideoPath()
        restoreWebWallpaperState()
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

    func setLockScreenSyncEnabled(_ enabled: Bool) {
        if !enabled {
            guard lockScreenSyncEnabled || lockScreenSyncService.hasActiveLease else {
                lockScreenSyncStatus = .disabled
                UserDefaults.standard.set(false, forKey: "lockScreenSyncEnabled")
                return
            }
            lockScreenSyncEnabled = false
            UserDefaults.standard.set(false, forKey: "lockScreenSyncEnabled")
            removeLockScreenSync()
            return
        }

        guard lockScreenSyncEnabled != enabled else {
            return
        }

        lockScreenSyncEnabled = true
        UserDefaults.standard.set(true, forKey: "lockScreenSyncEnabled")
        lockScreenSyncStatus = lockScreenSyncService.isSupported ? .idle : .unsupported
        syncCurrentVideoToLockScreen()
    }

    func syncCurrentVideoToLockScreen() {
        guard lockScreenSyncEnabled else {
            lockScreenSyncStatus = .disabled
            return
        }
        guard lockScreenSyncService.isSupported else {
            lockScreenSyncStatus = .unsupported
            return
        }
        guard let lockScreenPath = effectiveLockScreenVideoPath else {
            releaseLockScreenBorrowIfNeeded()
            return
        }

        let videoURL = URL(fileURLWithPath: lockScreenPath)
        let service = lockScreenSyncService

        lockScreenSyncTask?.cancel()
        lockScreenSyncStatus = .syncing
        lockScreenSyncTask = Task { [weak self] in
            do {
                let borrowedAsset = try await service.sync(videoURL: videoURL)
                await MainActor.run {
                    guard let self, !Task.isCancelled else {
                        return
                    }
                    self.lockScreenSyncStatus = .borrowed(borrowedAsset.name)
                }
            } catch LockScreenSyncError.noDownloadedAerials {
                await MainActor.run {
                    guard let self, !Task.isCancelled else {
                        return
                    }
                    self.lockScreenSyncStatus = .noAerialDownloaded
                }
            } catch {
                await MainActor.run {
                    guard let self, !Task.isCancelled else {
                        return
                    }
                    self.lockScreenSyncStatus = .failed(error.localizedDescription)
                }
            }
        }
    }

    func releaseLockScreenBorrowIfNeeded() {
        lockScreenSyncTask?.cancel()
        lockScreenUnlockResetWorkItem?.cancel()
        lockScreenUnlockResetWorkItem = nil

        guard lockScreenSyncService.hasActiveLease else {
            lockScreenSyncStatus = lockScreenSyncEnabled ? .idle : .disabled
            return
        }

        lockScreenSyncStatus = .removing
        do {
            try lockScreenSyncService.restoreOriginalAerialAndWallpaperStore()
            lockScreenSyncStatus = lockScreenSyncEnabled ? .idle : .disabled
        } catch {
            lockScreenSyncStatus = .failed(error.localizedDescription)
            NSLog(
                "[LockScreenSync] Failed to release borrow: \(error.localizedDescription)"
            )
        }
    }

    func removeLockScreenSync() {
        let service = lockScreenSyncService

        lockScreenSyncTask?.cancel()
        lockScreenUnlockResetWorkItem?.cancel()
        lockScreenUnlockResetWorkItem = nil
        lockScreenSyncStatus = .removing
        lockScreenSyncTask = Task { [weak self] in
            do {
                try service.restoreOriginalAerialAndWallpaperStore()
                await MainActor.run {
                    guard let self, !Task.isCancelled else {
                        return
                    }
                    self.lockScreenSyncEnabled = false
                    UserDefaults.standard.set(false, forKey: "lockScreenSyncEnabled")
                    self.lockScreenSyncStatus = .restored
                }
            } catch {
                await MainActor.run {
                    guard let self, !Task.isCancelled else {
                        return
                    }
                    self.lockScreenSyncStatus = .failed(error.localizedDescription)
                }
            }
        }
    }

    func restoreLockScreenWallpaperSettings() {
        let service = lockScreenSyncService
        lockScreenSyncTask?.cancel()
        lockScreenUnlockResetWorkItem?.cancel()
        lockScreenUnlockResetWorkItem = nil
        lockScreenSyncStatus = .restoring
        lockScreenSyncTask = Task { [weak self] in
            do {
                try service.restoreWallpaperStoreBackup()
                await MainActor.run {
                    guard let self, !Task.isCancelled else {
                        return
                    }
                    self.lockScreenSyncEnabled = false
                    UserDefaults.standard.set(false, forKey: "lockScreenSyncEnabled")
                    self.lockScreenSyncStatus = .restored
                }
            } catch {
                await MainActor.run {
                    guard let self, !Task.isCancelled else {
                        return
                    }
                    self.lockScreenSyncStatus = .failed(error.localizedDescription)
                }
            }
        }
    }

    func openLockScreenWallpaperSettings() {
        lockScreenSyncService.openWallpaperSettings()
    }

    func handleScreenUnlockedForLockScreenSync(delay: TimeInterval = 1.5) {
        guard shouldResetAerialExtensionAfterUnlock else {
            return
        }

        lockScreenUnlockResetWorkItem?.cancel()
        let initialSignature = displayReadySignature()
        let deadline = Date().addingTimeInterval(max(delay, 1.5) + 3.0)
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.waitForDisplaysThenResetAerialExtension(
                    previousSignature: initialSignature,
                    deadline: deadline
                )
            }
        }
        lockScreenUnlockResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func waitForDisplaysThenResetAerialExtension(
        previousSignature: String,
        deadline: Date
    ) {
        guard shouldResetAerialExtensionAfterUnlock else {
            return
        }

        let currentSignature = displayReadySignature()
        if currentSignature == previousSignature || Date() >= deadline {
            lockScreenSyncService.resetAerialExtensionAfterUnlock()
            lockScreenUnlockResetWorkItem = nil
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                self.waitForDisplaysThenResetAerialExtension(
                    previousSignature: currentSignature,
                    deadline: deadline
                )
            }
        }
        lockScreenUnlockResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func displayReadySignature() -> String {
        NSScreen.screens
            .map { screen in
                let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? ""
                return "\(id):\(screen.frame.integral)"
            }
            .sorted()
            .joined(separator: "|")
    }

    var shouldResetAerialExtensionAfterUnlock: Bool {
        lockScreenSyncEnabled
            && lockScreenSyncService.isSupported
            && lockScreenSyncService.hasActiveLease
    }

    func recoverStaleLockScreenSyncOnLaunchIfNeeded() {
        guard lockScreenSyncService.hasActiveLease else {
            return
        }

        lockScreenSyncStatus = .recovering
        do {
            try lockScreenSyncService.restoreOriginalAerialAndWallpaperStore()
            lockScreenSyncEnabled = false
            UserDefaults.standard.set(false, forKey: "lockScreenSyncEnabled")
            lockScreenSyncStatus = .recovered
        } catch {
            lockScreenSyncEnabled = false
            UserDefaults.standard.set(false, forKey: "lockScreenSyncEnabled")
            lockScreenSyncStatus = .failed(error.localizedDescription)
        }
    }

    func restoreLockScreenSyncBeforeExit() {
        lockScreenSyncTask?.cancel()
        lockScreenUnlockResetWorkItem?.cancel()
        lockScreenUnlockResetWorkItem = nil
        guard lockScreenSyncService.hasActiveLease else {
            return
        }

        do {
            try lockScreenSyncService.restoreOriginalAerialAndWallpaperStore()
            lockScreenSyncEnabled = false
            UserDefaults.standard.set(false, forKey: "lockScreenSyncEnabled")
            lockScreenSyncStatus = .restored
        } catch {
            lockScreenSyncStatus = .failed(error.localizedDescription)
            NSLog("[LockScreenSync] Failed to restore before exit: \(error.localizedDescription)")
        }
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
        setLockScreenSyncEnabled(false)
        _ = setSuspendWhenOtherAppFullScreen(false)
        _ = setSuspendHighSensitivityEnabled(false)
        _ = setSuspendWhenOtherAppFrontmost(false)
        suspendExclusionBundleIDs = []
        UserDefaults.standard.removeObject(forKey: "suspendExclusionBundleIDs")
        startAutoFrameRateMonitoring()
    }
}

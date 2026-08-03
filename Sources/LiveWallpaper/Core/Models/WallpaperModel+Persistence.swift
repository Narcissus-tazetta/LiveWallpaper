import AppKit
import Foundation

@MainActor
extension WallpaperModel {
    /// 保存済みの設定を復元する。ここでは動画ファイルの存在確認を一切しない:
    /// stat はローカルSSDなら一瞬だが、外付け・ネットワークボリュームや未ダウンロード
    /// のiCloudファイルでは1件で数秒ブロックしうる。それを登録本数ぶん直列に、
    /// しかもウィンドウを出す前のメインスレッドでやると起動がそのまま止まる。
    /// 参照はいったん全部復元し、実在確認と間引きは verifyRestoredVideoPaths() が
    /// 起動直後にバックグラウンドでまとめて行う。
    func restoreState() {
        restoreDisplayAndWindowPrefs()
        restorePlaybackTogglePrefs()
        restoreQualityAndPerformancePrefs()
        restoreMiscFeatureTogglePrefs()
        restoreDependentSubsystemState()
        restoreSuspendPrefs()
        restoreLibraryAndPlaylistState()
        restoreLockScreenAndWebWallpaperState()
        restorePresentationAndEditState()
        persistPlaylistStateImmediately()
    }

    private func restoreDisplayAndWindowPrefs() {
        clickThrough = UserDefaults.standard.object(forKey: PrefsKey.clickThrough) as? Bool ?? true
        if let modeValue: String = UserDefaults.standard.string(forKey: PrefsKey.displayMode),
           let restoredMode = DisplayMode(rawValue: modeValue)
        {
            displayMode = restoredMode
        }
        if let fitValue: String = UserDefaults.standard.string(forKey: PrefsKey.fitMode),
           let restoredFit = VideoFitMode(rawValue: fitValue)
        {
            fitMode = restoredFit
        }
        if let offsetValue = UserDefaults.standard.object(forKey: PrefsKey.desktopLevelOffset) as? Int,
           let restoredOffset = DesktopLevelOffset(rawValue: offsetValue)
        {
            desktopLevelOffset = restoredOffset
        }
        refreshDesktopIconsVisibility()
        useFullScreenAuxiliary =
            UserDefaults.standard.object(forKey: PrefsKey.useFullScreenAuxiliary) as? Bool ?? false
        menuBarOpaqueEnabled =
            UserDefaults.standard.object(forKey: PrefsKey.menuBarOpaqueEnabled) as? Bool ?? false
    }

    private func restorePlaybackTogglePrefs() {
        playlistPlaybackEnabled =
            UserDefaults.standard.object(forKey: PrefsKey.playlistPlaybackEnabled) as? Bool ?? false
        shufflePlaybackEnabled =
            UserDefaults.standard.object(forKey: PrefsKey.shufflePlaybackEnabled) as? Bool ?? false
        videoLoopEnabled =
            UserDefaults.standard.object(forKey: PrefsKey.videoLoopEnabled) as? Bool ?? true
        if !playlistPlaybackEnabled {
            shufflePlaybackEnabled = false
        }
        pinCurrentVideo = false
        lightweightMode = UserDefaults.standard.object(forKey: PrefsKey.lightweightMode) as? Bool ?? false
        respectReduceMotionEnabled =
            UserDefaults.standard.object(forKey: PrefsKey.respectReduceMotionEnabled) as? Bool ?? true
        restoreHotKeysState()
        audioEnabled = UserDefaults.standard.object(forKey: PrefsKey.audioEnabled) as? Bool ?? false
        restorePlaybackSettingState()
    }

    private func restoreQualityAndPerformancePrefs() {
        if let qualityValue = UserDefaults.standard.string(forKey: PrefsKey.qualityPreset),
           let restoredQuality = QualityPreset(rawValue: qualityValue)
        {
            qualityPreset = restoredQuality
        }
        autoFrameRateEnabled =
            UserDefaults.standard.object(forKey: PrefsKey.autoFrameRateEnabled) as? Bool ?? true
        batteryAwareQualityEnabled =
            UserDefaults.standard.object(forKey: PrefsKey.batteryAwareQualityEnabled) as? Bool ?? true
        if UserDefaults.standard.object(forKey: PrefsKey.audioVolume) != nil {
            audioVolume = min(max(UserDefaults.standard.float(forKey: PrefsKey.audioVolume), 0), 1)
        } else {
            audioVolume = 1.0
        }
        if let storedDimOpacity = UserDefaults.standard.object(forKey: PrefsKey.desktopReadabilityDimOpacity) as? Double {
            desktopReadabilityDimOpacity = min(max(storedDimOpacity, 0), 1)
        }
    }

    private func restoreMiscFeatureTogglePrefs() {
        if let appLanguageValue = UserDefaults.standard.string(forKey: PrefsKey.appLanguage),
           let restoredAppLanguage = AppLanguage(rawValue: appLanguageValue)
        {
            appLanguage = restoredAppLanguage
        }
        advancedSharingEnabled =
            UserDefaults.standard.object(forKey: PrefsKey.advancedSharingEnabled) as? Bool ?? false
        dedicatedPlaybackContinuityEnabled =
            UserDefaults.standard.object(forKey: PrefsKey.dedicatedPlaybackContinuityEnabled) as? Bool ?? true
        lockScreenSyncEnabled =
            UserDefaults.standard.object(forKey: PrefsKey.lockScreenSyncEnabled) as? Bool ?? false
        lockScreenSyncStatus = lockScreenSyncEnabled
            ? (lockScreenSyncService.isSupported ? .idle : .unsupported)
            : .disabled
    }

    /// 上で復元した値をもとに、他のモデル拡張が持つ状態を初期化する。
    private func restoreDependentSubsystemState() {
        applyAudioSettings()
        applyLightweightSettings()
        restoreAutoSwitchInterval()
        restoreVideoOverrides()
        restoreScreenPlaylists()
        restoreSpaceWallpaperState()
        restoreScheduleState()
    }

    private func restoreSuspendPrefs() {
        if let savedSuspendDisabled = UserDefaults.standard.stringArray(
            forKey: PrefsKey.suspendDisabledDisplayIDs
        ) {
            // UIでは割り当て済み画面だけがトグル対象なので、対応するオーバーライドが
            // 残っているエントリだけを引き継ぐ。
            suspendDisabledDisplayIDs = Set(savedSuspendDisabled)
                .intersection(videoOverrideByScreenID.keys)
        }
        suspendWhenOtherAppFullScreen =
            UserDefaults.standard.object(forKey: PrefsKey.suspendWhenOtherAppFullScreen) as? Bool ?? false
        suspendHighSensitivityEnabled =
            UserDefaults.standard.object(forKey: PrefsKey.suspendHighSensitivityEnabled) as? Bool ?? false
        suspendWhenOtherAppFrontmost =
            UserDefaults.standard.object(forKey: PrefsKey.suspendWhenOtherAppFrontmost) as? Bool ?? false
        if let savedExclusions = UserDefaults.standard.stringArray(
            forKey: PrefsKey.suspendExclusionBundleIDs
        ) {
            suspendExclusionBundleIDs = Array(
                Set(savedExclusions.map(normalizeBundleID).filter { !$0.isEmpty })
            )
            .sorted()
        }
    }

    private func restoreLibraryAndPlaylistState() {
        // 存在しないパスの間引きは verifyRestoredVideoPaths() が起動後に行う
        // (restoreState() 全体の注記を参照)。
        if let playlistData = UserDefaults.standard.data(forKey: PrefsKey.playlistsData),
           let decoded = try? JSONDecoder().decode([WallpaperPlaylist].self, from: playlistData)
        {
            playlists = decoded
        }

        restoreLibraryVideoPaths()

        if let savedPlaylistID = UserDefaults.standard.string(forKey: PrefsKey.selectedPlaylistID),
           let uuid = UUID(uuidString: savedPlaylistID),
           playlists.contains(where: { $0.id == uuid })
        {
            selectedPlaylistID = uuid
        } else {
            selectedPlaylistID = nil
        }

        syncActivePlaylistPaths()

        let allPaths = Set(libraryVideoPaths)
        if let savedDisplayNames = UserDefaults.standard.dictionary(
            forKey: PrefsKey.registeredVideoDisplayNames
        )
            as? [String: String]
        {
            registeredVideoDisplayNames = savedDisplayNames.filter {
                allPaths.contains($0.key)
            }
        }
        if let savedPath: String = UserDefaults.standard.string(forKey: PrefsKey.videoPath),
           libraryVideoPaths.contains(savedPath)
        {
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
    }

    private func restoreLockScreenAndWebWallpaperState() {
        restoreLockScreenVideoPath()
        restoreWebWallpaperState()
        if let storedWebFeature =
            UserDefaults.standard.object(forKey: PrefsKey.webWallpaperFeatureEnabled) as? Bool
        {
            webWallpaperFeatureEnabled = storedWebFeature
        } else {
            // 初回移行: 既にWeb壁紙を使っているユーザーから機能が消えて見えないよう、
            // 登録済みソースがある場合のみ自動でONにする。
            webWallpaperFeatureEnabled = !webWallpaperSources.isEmpty
            UserDefaults.standard.set(
                webWallpaperFeatureEnabled, forKey: PrefsKey.webWallpaperFeatureEnabled
            )
        }
        // webWallpaperFeatureEnabled が確定した後に再同期する。syncActivePlaylistPaths()は
        // これより前(restoreWebWallpaperState()内)でも呼べるが、その時点ではまだ
        // webWallpaperFeatureEnabledがデフォルト値(false)のままで、Web壁紙が
        // 再生キュー(registeredWebWallpaperIDs)に反映されずに固定されてしまう。
        syncActivePlaylistPaths()
    }

    private func restorePresentationAndEditState() {
        let allPaths = Set(libraryVideoPaths)
        if let data = UserDefaults.standard.data(forKey: wallpaperPresentationStorageKey),
           let decoded = try? JSONDecoder().decode(
               [String: [String: WallpaperPresentation]].self,
               from: data
           )
        {
            wallpaperPresentationByPath = decoded.filter { allPaths.contains($0.key) }
        }
        if let editData = UserDefaults.standard.data(forKey: wallpaperEditStorageKey),
           let decodedEdits = try? JSONDecoder().decode(
               [String: WallpaperEditMetadata].self,
               from: editData
           )
        {
            wallpaperEditByPath = decodedEdits.filter { allPaths.contains($0.key) }
        }
    }

    /// ライブラリを復元する。旧バージョン(ライブラリ未分離)のデータは
    /// プレイリストの合算 + 旧 registeredVideoPaths キーから移行する。
    private func restoreLibraryVideoPaths() {
        var restored: [String]
        if let savedLibrary = UserDefaults.standard.stringArray(forKey: PrefsKey.libraryVideoPaths) {
            restored = savedLibrary
        } else {
            let legacyPaths =
                UserDefaults.standard.stringArray(forKey: PrefsKey.registeredVideoPaths) ?? []
            restored = []
            var seen = Set<String>()
            for path in playlists.flatMap(\.videoPaths) + legacyPaths where !seen.contains(path) {
                seen.insert(path)
                restored.append(path)
            }
        }

        // 不変条件: プレイリストが参照するパスは必ずライブラリに含まれる
        var known = Set(restored)
        for path in playlists.flatMap(\.videoPaths) where !known.contains(path) {
            known.insert(path)
            restored.append(path)
        }
        libraryVideoPaths = restored
    }

    private func restorePlaybackSettingState() {
        if let frameRateValue = UserDefaults.standard.string(forKey: PrefsKey.frameRateLimit),
           let restoredFrameRate = FrameRateLimit(rawValue: frameRateValue)
        {
            frameRateLimit = restoredFrameRate
        }
        if let decodeValue = UserDefaults.standard.string(forKey: PrefsKey.decodeMode),
           let restoredDecodeMode = DecodeMode(rawValue: decodeValue)
        {
            if restoredDecodeMode == .gpuAdaptive {
                decodeMode = .automatic
                UserDefaults.standard.set(DecodeMode.automatic.rawValue, forKey: PrefsKey.decodeMode)
            } else {
                decodeMode = restoredDecodeMode
            }
        }
        if let workProfileValue = UserDefaults.standard.string(forKey: PrefsKey.workProfile),
           let restoredWorkProfile = WorkProfile(rawValue: workProfileValue)
        {
            workProfile = restoredWorkProfile
        }
    }

    func pruneDisplayNamesForExistingPaths() {
        let validPaths = Set(libraryVideoPaths)
        registeredVideoDisplayNames =
            registeredVideoDisplayNames
                .filter { validPaths.contains($0.key) }
        UserDefaults.standard.set(
            registeredVideoDisplayNames,
            forKey: PrefsKey.registeredVideoDisplayNames
        )
    }

    func pruneWallpaperPresentationsForExistingPaths() {
        let validPaths = Set(libraryVideoPaths)
        let pruned = wallpaperPresentationByPath.filter { validPaths.contains($0.key) }
        if pruned != wallpaperPresentationByPath {
            wallpaperPresentationByPath = pruned
            persistWallpaperPresentationState()
        }
    }

    func persistWallpaperPresentationState() {
        schedulePersistedStateFlush()
    }

    func pruneWallpaperEditsForExistingPaths() {
        let validPaths = Set(libraryVideoPaths)
        let pruned = wallpaperEditByPath.filter { validPaths.contains($0.key) }
        if pruned != wallpaperEditByPath {
            wallpaperEditByPath = pruned
            persistWallpaperEditState()
        }
    }

    func persistWallpaperEditState() {
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
        UserDefaults.standard.set(enabled, forKey: PrefsKey.advancedSharingEnabled)
    }

    func setWebWallpaperFeatureEnabled(_ enabled: Bool) {
        guard webWallpaperFeatureEnabled != enabled else {
            return
        }
        webWallpaperFeatureEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: PrefsKey.webWallpaperFeatureEnabled)
        syncActivePlaylistPaths()

        // 機能を隠すとWeb壁紙を切り替える手段がなくなるため、表示中なら動画へ戻す。
        // 戻せる動画が1本もない場合だけ再生を維持する。
        if !enabled, isWebWallpaperActive {
            if let fallback = currentVideoPath ?? registeredVideoPaths.first
                ?? libraryVideoPaths.first
            {
                selectRegisteredVideo(path: fallback)
            }
        }
    }

    func setLockScreenSyncEnabled(_ enabled: Bool) {
        if !enabled {
            guard lockScreenSyncEnabled || lockScreenSyncService.hasActiveLease else {
                lockScreenSyncStatus = .disabled
                UserDefaults.standard.set(false, forKey: PrefsKey.lockScreenSyncEnabled)
                return
            }
            lockScreenSyncEnabled = false
            UserDefaults.standard.set(false, forKey: PrefsKey.lockScreenSyncEnabled)
            removeLockScreenSync()
            return
        }

        guard lockScreenSyncEnabled != enabled else {
            return
        }

        lockScreenSyncEnabled = true
        UserDefaults.standard.set(true, forKey: PrefsKey.lockScreenSyncEnabled)
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
            AppLog.lockScreenSync.error(
                "Failed to release borrow: \(error.localizedDescription, privacy: .public)"
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
                    UserDefaults.standard.set(false, forKey: PrefsKey.lockScreenSyncEnabled)
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
                    UserDefaults.standard.set(false, forKey: PrefsKey.lockScreenSyncEnabled)
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
            UserDefaults.standard.set(false, forKey: PrefsKey.lockScreenSyncEnabled)
            lockScreenSyncStatus = .recovered
        } catch {
            lockScreenSyncEnabled = false
            UserDefaults.standard.set(false, forKey: PrefsKey.lockScreenSyncEnabled)
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
            UserDefaults.standard.set(false, forKey: PrefsKey.lockScreenSyncEnabled)
            lockScreenSyncStatus = .restored
        } catch {
            lockScreenSyncStatus = .failed(error.localizedDescription)
            AppLog.lockScreenSync.error(
                "Failed to restore before exit: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func resetSettingsToDefaults() {
        setClickThrough(true)
        setDisplayMode(.mainOnly)
        setFitMode(.fill)
        setLightweightMode(false)
        setAudioEnabled(false)
        setAudioVolume(1.0)
        setDesktopReadabilityDimOpacity(0)
        setFrameRateLimit(.off)
        setDecodeMode(.automatic)
        setWorkProfile(.normal)
        setQualityPreset(.auto)
        setPlaylistPlaybackEnabled(false)
        setShufflePlaybackEnabled(false)
        setVideoLoopEnabled(true)
        clearPinCurrentVideo()
        setAutoFrameRateEnabled(true)
        setBatteryAwareQualityEnabled(true)
        setDesktopLevelOffset(.zero)
        setFullScreenAuxiliary(false)
        setAdvancedSharingEnabled(false)
        setLockScreenSyncEnabled(false)
        _ = setSuspendWhenOtherAppFullScreen(false)
        _ = setSuspendHighSensitivityEnabled(false)
        _ = setSuspendWhenOtherAppFrontmost(false)
        suspendExclusionBundleIDs = []
        UserDefaults.standard.removeObject(forKey: PrefsKey.suspendExclusionBundleIDs)
        // Space別壁紙は機能トグルのみ既定(OFF)へ戻す。割り当て自体は
        // ディスプレイ別オーバーライドと同様、リセット対象にしない。
        setSpaceWallpaperFeatureEnabled(false)
        setMenuBarSpaceNumberEnabled(false)
        // スケジュール(簡易UI/曜日ルール)は全て消し、評価タイマー停止と各スコープの
        // オーバーライド解除まで行う。残すとリセット直後の外観変化や時刻境界で壁紙が
        // 勝手に切り替わり、リセットが効いていないように見える。
        resetScheduleState()
        startAutoFrameRateMonitoring()
    }
}

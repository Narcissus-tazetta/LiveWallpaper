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
        respectReduceMotionEnabled =
            UserDefaults.standard.object(forKey: "respectReduceMotionEnabled") as? Bool ?? true
        restoreHotKeysState()
        audioEnabled = UserDefaults.standard.object(forKey: "audioEnabled") as? Bool ?? false
        restorePlaybackSettingState()
        if let qualityValue = UserDefaults.standard.string(forKey: "qualityPreset"),
           let restoredQuality = QualityPreset(rawValue: qualityValue)
        {
            qualityPreset = restoredQuality
        }
        autoFrameRateEnabled =
            UserDefaults.standard.object(forKey: "autoFrameRateEnabled") as? Bool ?? true
        batteryAwareQualityEnabled =
            UserDefaults.standard.object(forKey: "batteryAwareQualityEnabled") as? Bool ?? true
        if UserDefaults.standard.object(forKey: "audioVolume") != nil {
            audioVolume = min(max(UserDefaults.standard.float(forKey: "audioVolume"), 0), 1)
        } else {
            audioVolume = 1.0
        }
        if let storedDimOpacity = UserDefaults.standard.object(forKey: "desktopReadabilityDimOpacity") as? Double {
            desktopReadabilityDimOpacity = min(max(storedDimOpacity, 0), 1)
        }
        if let appLanguageValue = UserDefaults.standard.string(forKey: "appLanguage"),
           let restoredAppLanguage = AppLanguage(rawValue: appLanguageValue)
        {
            appLanguage = restoredAppLanguage
        }
        advancedSharingEnabled =
            UserDefaults.standard.object(forKey: "advancedSharingEnabled") as? Bool ?? false
        dedicatedPlaybackContinuityEnabled =
            UserDefaults.standard.object(forKey: "dedicatedPlaybackContinuityEnabled") as? Bool ?? true
        lockScreenSyncEnabled =
            UserDefaults.standard.object(forKey: "lockScreenSyncEnabled") as? Bool ?? false
        lockScreenSyncStatus = lockScreenSyncEnabled
            ? (lockScreenSyncService.isSupported ? .idle : .unsupported)
            : .disabled
        applyAudioSettings()
        applyLightweightSettings()
        restoreAutoSwitchInterval()
        restoreVideoOverrides()
        restoreScreenPlaylists()
        restoreSpaceWallpaperState()
        restoreScheduleState()
        if let savedSuspendDisabled = UserDefaults.standard.stringArray(
            forKey: "suspendDisabledDisplayIDs"
        ) {
            // UIでは割り当て済み画面だけがトグル対象なので、対応するオーバーライドが
            // 残っているエントリだけを引き継ぐ。
            suspendDisabledDisplayIDs = Set(savedSuspendDisabled)
                .intersection(videoOverrideByScreenID.keys)
        }
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
        // 存在しないパスの間引きは verifyRestoredVideoPaths() が起動後に行う
        // (このメソッド全体の注記を参照)。
        if let playlistData = UserDefaults.standard.data(forKey: "playlistsData"),
           let decoded = try? JSONDecoder().decode([WallpaperPlaylist].self, from: playlistData)
        {
            playlists = decoded
        }

        restoreLibraryVideoPaths()

        if let savedPlaylistID = UserDefaults.standard.string(forKey: "selectedPlaylistID"),
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
            forKey: "registeredVideoDisplayNames"
        )
            as? [String: String]
        {
            registeredVideoDisplayNames = savedDisplayNames.filter {
                allPaths.contains($0.key)
            }
        }
        if let savedPath: String = UserDefaults.standard.string(forKey: "videoPath"),
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
        restoreLockScreenVideoPath()
        restoreWebWallpaperState()
        if let storedWebFeature =
            UserDefaults.standard.object(forKey: "webWallpaperFeatureEnabled") as? Bool
        {
            webWallpaperFeatureEnabled = storedWebFeature
        } else {
            // 初回移行: 既にWeb壁紙を使っているユーザーから機能が消えて見えないよう、
            // 登録済みソースがある場合のみ自動でONにする。
            webWallpaperFeatureEnabled = !webWallpaperSources.isEmpty
            UserDefaults.standard.set(
                webWallpaperFeatureEnabled, forKey: "webWallpaperFeatureEnabled"
            )
        }
        // webWallpaperFeatureEnabled が確定した後に再同期する。syncActivePlaylistPaths()は
        // これより前(restoreWebWallpaperState()内)でも呼べるが、その時点ではまだ
        // webWallpaperFeatureEnabledがデフォルト値(false)のままで、Web壁紙が
        // 再生キュー(registeredWebWallpaperIDs)に反映されずに固定されてしまう。
        syncActivePlaylistPaths()
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
        persistPlaylistStateImmediately()
    }

    /// ライブラリを復元する。旧バージョン(ライブラリ未分離)のデータは
    /// プレイリストの合算 + 旧 registeredVideoPaths キーから移行する。
    private func restoreLibraryVideoPaths() {
        var restored: [String]
        if let savedLibrary = UserDefaults.standard.stringArray(forKey: "libraryVideoPaths") {
            restored = savedLibrary
        } else {
            let legacyPaths =
                UserDefaults.standard.stringArray(forKey: "registeredVideoPaths") ?? []
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
        let validPaths = Set(libraryVideoPaths)
        registeredVideoDisplayNames =
            registeredVideoDisplayNames
                .filter { validPaths.contains($0.key) }
        UserDefaults.standard.set(
            registeredVideoDisplayNames,
            forKey: "registeredVideoDisplayNames"
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
        UserDefaults.standard.set(enabled, forKey: "advancedSharingEnabled")
    }

    func setWebWallpaperFeatureEnabled(_ enabled: Bool) {
        guard webWallpaperFeatureEnabled != enabled else {
            return
        }
        webWallpaperFeatureEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "webWallpaperFeatureEnabled")
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
        UserDefaults.standard.removeObject(forKey: "suspendExclusionBundleIDs")
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

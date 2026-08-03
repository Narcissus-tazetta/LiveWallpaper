import AVFoundation
import Foundation
import IOKit.ps

@MainActor
extension WallpaperModel {
    func setLightweightMode(_ enabled: Bool) {
        guard lightweightMode != enabled else {
            return
        }
        lightweightMode = enabled
        UserDefaults.standard.set(enabled, forKey: PrefsKey.lightweightMode)
        applyLightweightSettings()
        requestPlaybackReconfiguration()
    }

    func setAudioEnabled(_ enabled: Bool) {
        guard audioEnabled != enabled else {
            return
        }
        audioEnabled = enabled
        applyAudioSettings()
        applyWebAudioSettings()
        UserDefaults.standard.set(enabled, forKey: PrefsKey.audioEnabled)
    }

    func setAudioVolume(_ volume: Float) {
        let clampedVolume: Float = min(max(volume, 0), 1)
        guard abs(audioVolume - clampedVolume) > 0.001 else {
            return
        }
        audioVolume = clampedVolume
        applyAudioSettings()
        UserDefaults.standard.set(clampedVolume, forKey: PrefsKey.audioVolume)
    }

    func setFrameRateLimit(_ limit: FrameRateLimit) {
        guard frameRateLimit != limit else {
            return
        }
        frameRateLimit = limit
        UserDefaults.standard.set(limit.rawValue, forKey: PrefsKey.frameRateLimit)
        applyDynamicPlaybackProfile()
    }

    func setDecodeMode(_ mode: DecodeMode) {
        guard decodeMode != mode else {
            return
        }
        decodeMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: PrefsKey.decodeMode)
        requestPlaybackReconfiguration()
    }

    func setWorkProfile(_ profile: WorkProfile) {
        guard workProfile != profile else {
            return
        }
        workProfile = profile
        UserDefaults.standard.set(profile.rawValue, forKey: PrefsKey.workProfile)
        applyDynamicPlaybackProfile()
    }

    func setQualityPreset(_ preset: QualityPreset) {
        guard qualityPreset != preset else {
            return
        }
        qualityPreset = preset
        UserDefaults.standard.set(preset.rawValue, forKey: PrefsKey.qualityPreset)
        applyDynamicPlaybackProfile()
    }

    func setAutoFrameRateEnabled(_ enabled: Bool) {
        guard autoFrameRateEnabled != enabled else {
            return
        }
        autoFrameRateEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: PrefsKey.autoFrameRateEnabled)
        startAutoFrameRateMonitoring()
    }

    func setBatteryAwareQualityEnabled(_ enabled: Bool) {
        guard batteryAwareQualityEnabled != enabled else {
            return
        }
        batteryAwareQualityEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: PrefsKey.batteryAwareQualityEnabled)
        startAutoFrameRateMonitoring()
    }

    func setPlaylistPlaybackEnabled(_ enabled: Bool) {
        guard playlistPlaybackEnabled != enabled else {
            return
        }
        playlistPlaybackEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: PrefsKey.playlistPlaybackEnabled)
        if !enabled {
            setShufflePlaybackEnabled(false)
            clearPinCurrentVideo()
        }
        normalizePlaybackConstraints()
        requestPlaybackReconfiguration()
    }

    func setShufflePlaybackEnabled(_ enabled: Bool) {
        let normalized = playlistPlaybackEnabled && !pinCurrentVideo ? enabled : false
        guard shufflePlaybackEnabled != normalized else {
            return
        }
        shufflePlaybackEnabled = normalized
        UserDefaults.standard.set(normalized, forKey: PrefsKey.shufflePlaybackEnabled)
    }

    func setVideoLoopEnabled(_ enabled: Bool) {
        guard videoLoopEnabled != enabled else {
            return
        }
        videoLoopEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: PrefsKey.videoLoopEnabled)
        requestPlaybackReconfiguration()
    }

    func setPinCurrentVideo(_ enabled: Bool) {
        guard pinCurrentVideo != enabled else {
            return
        }
        if enabled {
            guard canPinCurrentVideo else {
                return
            }
            pinCurrentVideo = true
            setShufflePlaybackEnabled(false)
        } else {
            pinCurrentVideo = false
        }
        requestPlaybackReconfiguration()
        if !enabled {
            // pin解除で共有スコープのスケジュールガードが外れる。境界を跨いだまま
            // 保留されていたルールをここで即時反映する(次のタイマーtickを待たない)。
            evaluateSchedule(trigger: .playbackConstraintChanged)
        }
    }

    func refreshPlaybackState() {
        scheduleWindowRebuild(delay: 0.05)
        if isWebWallpaperActive {
            webWallpaperLoadState = .loading
            evaluateForegroundCoverageState()
            return
        }
        if let currentPath = currentVideoPath,
           FileManager.default.fileExists(atPath: currentPath)
        {
            playRegisteredVideo(path: currentPath)
            return
        }
        stopAllPlayers()
        evaluateForegroundCoverageState()
    }

    func configurePlayer() {
        configurePlaybackEndObserver()
    }

    private func configurePlaybackEndObserver() {
        if let observer = playerItemEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        playerItemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                guard let finishedItem = note.object as? AVPlayerItem,
                      let player = self.sharedPlayer,
                      player.currentItem === finishedItem
                else {
                    return
                }
                switch self.playbackEndBehavior() {
                case .loopCurrent:
                    break
                case .advancePlaylist:
                    self.playNextVideo(advancingPlaylist: true)
                case .playOnce:
                    player.pause()
                }
            }
        }
    }

    /// AVQueuePlayer の基本設定。共有プレイヤーとディスプレイ固定の専用プレイヤー
    /// の両方から使う(専用プレイヤーは常に `muted: true` で呼ぶ)。
    func createConfiguredPlayer(muted: Bool) -> AVQueuePlayer {
        let player = AVQueuePlayer()
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = lightweightMode
        player.isMuted = muted
        return player
    }

    func ensureSharedPlayer() -> AVQueuePlayer {
        if let existing = sharedPlayer {
            return existing
        }
        let player = createConfiguredPlayer(muted: !audioEnabled)
        player.volume = audioVolume
        sharedPlayer = player
        return player
    }

    private func attachSharedPlayerToAllViews() {
        let player = sharedPlayer
        for index in playerViews.indices {
            // オーバーライド画面は専用プレイヤーを使うため共有プレイヤーを付けない。
            guard isSharedPlayerDisplay(displayIDForWindow(at: index)) else {
                continue
            }
            let layer = playerViews[index].playerLayer
            if layer.player !== player {
                layer.player = player
            }
        }
    }

    func stopAllPlayers() {
        if let player = sharedPlayer {
            player.pause()
            player.removeAllItems()
        }
        // AVPlayerLooper must be explicitly disabled before its last strong
        // reference is dropped — otherwise it can leave the shared AVQueuePlayer
        // in an inconsistent state where the old (still-looping) item lingers
        // alongside whatever gets inserted next, so a subsequent video swap
        // (e.g. lightweight-mode proxy <-> original) can silently keep playing
        // the previous item instead of the new one.
        sharedLooper?.disableLooping()
        sharedLooper = nil
        // Any real teardown/rebuild resets deep-suspend bookkeeping. The deep-
        // suspend timer itself calls stopAllPlayers() and then re-sets
        // isDeepSuspended = true afterward, so clearing it here is correct.
        deepSuspendWorkItem?.cancel()
        deepSuspendWorkItem = nil
        isDeepSuspended = false
        // A rebuild supersedes any in-flight deep-resume: the stale resume's
        // readiness/seek callbacks must not act on the newly-built item.
        isDeepResuming = false
    }

    func applyLightweightSettings() {
        sharedPlayer?.automaticallyWaitsToMinimizeStalling = lightweightMode
        for entry in allDedicatedSlotEntries() {
            entry.slot.player.automaticallyWaitsToMinimizeStalling = lightweightMode
        }
    }

    func applyAudioSettings() {
        guard let player = sharedPlayer else {
            return
        }
        player.isMuted = !audioEnabled
        player.volume = audioVolume
    }

    private func targetMaxPixelWidth() -> Double {
        let screens = targetScreens()
        let widths = screens.map { screen -> Double in
            let scale = max(screen.backingScaleFactor, 1)
            return Double(max(screen.frame.width, screen.frame.height) * scale)
        }
        return widths.max() ?? 1920
    }

    static func detectPlaybackEnvironment() -> PlaybackEnvironment {
        var isArm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &isArm64, &size, nil, 0) == 0, isArm64 == 1 {
            return PlaybackEnvironment(
                chipClass: .appleSilicon,
                logicalCores: ProcessInfo.processInfo.activeProcessorCount
            )
        }
        return PlaybackEnvironment(
            chipClass: .intel,
            logicalCores: ProcessInfo.processInfo.activeProcessorCount
        )
    }

    private func playbackProfileInputs() -> PlaybackProfileResolver.Inputs {
        PlaybackProfileResolver.Inputs(
            workProfile: workProfile,
            lightweightMode: lightweightMode,
            targetMaxPixelWidth: targetMaxPixelWidth(),
            qualityPreset: qualityPreset,
            decodeMode: decodeMode,
            chipClass: playbackEnvironment.chipClass,
            logicalCores: playbackEnvironment.logicalCores,
            frameRateLimit: frameRateLimit,
            autoFrameRateBitRateFactor: autoFrameRateBitRateFactor,
            autoFrameRateBufferAdjustment: autoFrameRateBufferAdjustment
        )
    }

    private func resolvedWorkProfile() -> WorkProfile {
        PlaybackProfileResolver.resolvedWorkProfile(playbackProfileInputs())
    }

    private func resolvedDecodeMode() -> DecodeMode {
        PlaybackProfileResolver.resolvedDecodeMode(playbackProfileInputs())
    }

    func resolvePlaybackProfile(
        role: DedicatedPlayerRole = .active
    ) -> (bitRate: Double, buffer: TimeInterval) {
        PlaybackProfileResolver.resolve(playbackProfileInputs(), role: role)
    }

    func playVideo(url: URL) {
        installPlayerItem(url: url, attach: true)
    }

    /// 直前の再生位置を復元する呼び出し(deep suspend からの復帰・軽量プロキシ
    /// 差し替え)専用の入り口。「途中からループする」のイントロは *再生の開始* の
    /// 演出なので、続きから戻すときは出さない。両方が readyToPlay 待ちで seek を
    /// 投げると、どちらが後に着地するかで再生位置が揺れる。
    func reinstallPlayerItemContinuingPlayback(url: URL, attach: Bool) {
        installPlayerItem(url: url, attach: attach, playsIntro: false)
    }

    /// Builds and installs a fresh AVPlayerItem for `url` on the shared player.
    ///
    /// With `attach: true` (the normal path) this reproduces the original
    /// `playVideo` behavior exactly: the shared player is attached to every
    /// layer and suspension/coverage state is re-applied. With `attach: false`
    /// (used by deep-suspend resume) the item is built in the background without
    /// touching the layers, so the freeze frame stays visible until the caller
    /// decides the item is ready and performs the attach itself.
    func installPlayerItem(url: URL, attach: Bool, playsIntro: Bool = true) {
        let effectiveDecode = resolvedDecodeMode()
        let asset = AVURLAsset(
            url: url,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: effectiveDecode == .balanced
            ]
        )
        let profile = resolvePlaybackProfile()
        stopAllPlayers()

        let player = ensureSharedPlayer()
        if attach {
            attachSharedPlayerToAllViews()
        }

        let item = AVPlayerItem(asset: asset)
        item.preferredPeakBitRate = profile.bitRate
        item.preferredForwardBufferDuration = profile.buffer
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        item.videoComposition = nil

        let edit = currentVideoPath.flatMap { wallpaperEditByPath[$0] }
        if shouldUsePlaybackLooper() {
            // AVPlayerLooper がテンプレートのコピー挿入まで行うため、ここでは
            // insert しない。
            sharedLooper = makeWallpaperLooper(
                player: player, templateItem: item, path: currentVideoPath,
                playsIntro: playsIntro
            )
        } else {
            if let edit, !edit.isNoOp, let trimEnd = edit.trimEnd {
                item.forwardPlaybackEndTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
            }
            player.insert(item, after: nil)
            sharedLooper = nil
            if let edit, !edit.isNoOp, edit.trimStart > 0 {
                player.seek(to: CMTime(seconds: edit.trimStart, preferredTimescale: 600))
            }
        }
        applyAudioSettings()
        if attach {
            applySuspensionStateToPlayers()
            evaluateForegroundCoverageState()
        }
    }

    @discardableResult
    private func applyDynamicPlaybackProfile() -> Bool {
        var didApply = false
        if let item = sharedPlayer?.currentItem {
            let profile = resolvePlaybackProfile()
            item.preferredPeakBitRate = profile.bitRate
            item.preferredForwardBufferDuration = profile.buffer
            didApply = true
        }
        for entry in allDedicatedSlotEntries() {
            guard let item = entry.slot.player.currentItem else {
                continue
            }
            let profile = resolvePlaybackProfile(role: entry.isActive ? .active : .warmStandby)
            item.preferredPeakBitRate = profile.bitRate
            item.preferredForwardBufferDuration = profile.buffer
            didApply = true
        }
        return didApply
    }

    private func requestPlaybackReconfiguration() {
        guard !pendingPlaybackReconfiguration else {
            return
        }
        pendingPlaybackReconfiguration = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            pendingPlaybackReconfiguration = false
            if isWebWallpaperActive {
                return
            }
            if let currentPath = currentVideoPath {
                playRegisteredVideo(path: currentPath)
            }
        }
    }

    func startAutoFrameRateMonitoring() {
        autoFrameRateTimer?.invalidate()
        autoFrameRateTimer = nil
        if let observer = autoFrameRateThermalObserver {
            NotificationCenter.default.removeObserver(observer)
            autoFrameRateThermalObserver = nil
        }
        if let observer = autoFrameRatePowerStateObserver {
            NotificationCenter.default.removeObserver(observer)
            autoFrameRatePowerStateObserver = nil
        }
        evaluateAutoFrameRatePolicy()
        guard autoFrameRateEnabled || batteryAwareQualityEnabled else {
            return
        }

        // Thermal state and low-power-mode both post their own change
        // notifications, so those two signals react instantly instead of
        // waiting on a poll. The timer below only remains as a coarse
        // fallback to pick up battery-percentage drift and multi-display
        // changes between notifications, so it can be far less frequent
        // (and coalesced via `tolerance`) than the old fixed 12s poll.
        autoFrameRateThermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluateAutoFrameRatePolicy()
            }
        }
        autoFrameRatePowerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluateAutoFrameRatePolicy()
            }
        }

        let timer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluateAutoFrameRatePolicy()
            }
        }
        timer.tolerance = 15.0
        autoFrameRateTimer = timer
    }

    private func evaluateAutoFrameRatePolicy() {
        if resolvedWorkProfile() != .normal {
            if autoFrameRateBitRateFactor != 1.0 || autoFrameRateBufferAdjustment != 0 {
                autoFrameRateBitRateFactor = 1.0
                autoFrameRateBufferAdjustment = 0
                applyDynamicPlaybackProfile()
            }
            return
        }

        guard autoFrameRateEnabled || batteryAwareQualityEnabled else {
            if autoFrameRateBitRateFactor != 1.0 || autoFrameRateBufferAdjustment != 0 {
                autoFrameRateBitRateFactor = 1.0
                autoFrameRateBufferAdjustment = 0
                applyDynamicPlaybackProfile()
            }
            return
        }

        let (nextBitRateFactor, nextBufferAdjustment) = AutoFrameRatePolicy.resolve(
            AutoFrameRatePolicy.Inputs(
                autoFrameRateEnabled: autoFrameRateEnabled,
                batteryAwareQualityEnabled: batteryAwareQualityEnabled,
                thermalState: ProcessInfo.processInfo.thermalState,
                isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
                displayCount: max(targetScreens().count, 1),
                batteryInfo: Self.currentBatteryInfo()
            )
        )

        let bitRateChanged = abs(nextBitRateFactor - autoFrameRateBitRateFactor) > 0.02
        let bufferChanged = abs(nextBufferAdjustment - autoFrameRateBufferAdjustment) > 0.02
        guard bitRateChanged || bufferChanged else {
            return
        }

        autoFrameRateBitRateFactor = nextBitRateFactor
        autoFrameRateBufferAdjustment = nextBufferAdjustment
        applyDynamicPlaybackProfile()
    }

    private static func currentBatteryInfo() -> (percentage: Int, onBatteryPower: Bool)? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return nil
        }
        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any],
                let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int,
                let maxCapacity = description[kIOPSMaxCapacityKey] as? Int,
                maxCapacity > 0
            else {
                continue
            }
            let percentage = Int((Double(currentCapacity) / Double(maxCapacity)) * 100)
            let onBattery = description[kIOPSPowerSourceStateKey] as? String ==
                kIOPSBatteryPowerValue
            return (percentage, onBattery)
        }
        return nil
    }
}

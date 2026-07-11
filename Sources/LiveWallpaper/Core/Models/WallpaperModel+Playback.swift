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
        UserDefaults.standard.set(enabled, forKey: "lightweightMode")
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
        UserDefaults.standard.set(enabled, forKey: "audioEnabled")
    }

    func setAudioVolume(_ volume: Float) {
        let clampedVolume: Float = min(max(volume, 0), 1)
        guard abs(audioVolume - clampedVolume) > 0.001 else {
            return
        }
        audioVolume = clampedVolume
        applyAudioSettings()
        UserDefaults.standard.set(clampedVolume, forKey: "audioVolume")
    }

    func setFrameRateLimit(_ limit: FrameRateLimit) {
        guard frameRateLimit != limit else {
            return
        }
        frameRateLimit = limit
        UserDefaults.standard.set(limit.rawValue, forKey: "frameRateLimit")
        applyDynamicPlaybackProfile()
    }

    func setDecodeMode(_ mode: DecodeMode) {
        guard decodeMode != mode else {
            return
        }
        decodeMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "decodeMode")
        requestPlaybackReconfiguration()
    }

    func setWorkProfile(_ profile: WorkProfile) {
        guard workProfile != profile else {
            return
        }
        workProfile = profile
        UserDefaults.standard.set(profile.rawValue, forKey: "workProfile")
        applyDynamicPlaybackProfile()
    }

    func setQualityPreset(_ preset: QualityPreset) {
        guard qualityPreset != preset else {
            return
        }
        qualityPreset = preset
        UserDefaults.standard.set(preset.rawValue, forKey: "qualityPreset")
        applyDynamicPlaybackProfile()
    }

    func setAutoFrameRateEnabled(_ enabled: Bool) {
        guard autoFrameRateEnabled != enabled else {
            return
        }
        autoFrameRateEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "autoFrameRateEnabled")
        startAutoFrameRateMonitoring()
    }

    func setBatteryAwareQualityEnabled(_ enabled: Bool) {
        guard batteryAwareQualityEnabled != enabled else {
            return
        }
        batteryAwareQualityEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "batteryAwareQualityEnabled")
        startAutoFrameRateMonitoring()
    }

    func setPlaylistPlaybackEnabled(_ enabled: Bool) {
        guard playlistPlaybackEnabled != enabled else {
            return
        }
        playlistPlaybackEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "playlistPlaybackEnabled")
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
        UserDefaults.standard.set(normalized, forKey: "shufflePlaybackEnabled")
    }

    func setVideoLoopEnabled(_ enabled: Bool) {
        guard videoLoopEnabled != enabled else {
            return
        }
        videoLoopEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "videoLoopEnabled")
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
        for player in dedicatedPlayersByScreenID.values {
            player.automaticallyWaitsToMinimizeStalling = lightweightMode
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

    private func baseBitRate(for width: Double, preset: QualityPreset) -> Double {
        if width < 2560 {
            switch preset {
            case .auto:
                return 2_200_000
            case .efficiency:
                return 1_500_000
            case .quality:
                return 3_000_000
            }
        }

        if width < 3840 {
            switch preset {
            case .auto:
                return 6_000_000
            case .efficiency:
                return 4_000_000
            case .quality:
                return 8_000_000
            }
        }

        switch preset {
        case .auto:
            return 12_000_000
        case .efficiency:
            return 8_000_000
        case .quality:
            return 16_000_000
        }
    }

    private func frameRateBitRateFactor() -> Double {
        switch frameRateLimit {
        case .off:
            return 1.0
        case .fps30:
            return 0.85
        case .fps60:
            return 1.3
        }
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

    private func resolvedDecodeMode() -> DecodeMode {
        switch decodeMode {
        case .automatic, .gpuAdaptive:
            switch playbackEnvironment.chipClass {
            case .appleSilicon:
                return .balanced
            case .intel:
                return playbackEnvironment.logicalCores >= 8 ? .balanced : .efficiency
            }
        default:
            return decodeMode
        }
    }

    private func resolvedWorkProfile() -> WorkProfile {
        if lightweightMode {
            return .ultraLight
        }
        if workProfile != .normal {
            return workProfile
        }
        if targetMaxPixelWidth() <= 1920, qualityPreset != .quality, frameRateLimit != .fps60 {
            return .lowPower
        }
        return .normal
    }

    private func decodeBitRateFactor() -> Double {
        switch resolvedDecodeMode() {
        case .automatic, .gpuAdaptive:
            return 1.0
        case .balanced:
            return 1.05
        case .efficiency:
            return 0.75
        }
    }

    private func baseBufferDuration() -> TimeInterval {
        switch resolvedDecodeMode() {
        case .automatic, .gpuAdaptive:
            return 1.0
        case .balanced:
            return 1.5
        case .efficiency:
            return 0.25
        }
    }

    private func qualityAdjustedBuffer(_ base: TimeInterval) -> TimeInterval {
        switch qualityPreset {
        case .auto:
            return base
        case .efficiency:
            return max(0, base - 0.5)
        case .quality:
            return base + 0.5
        }
    }

    func resolvePlaybackProfile() -> (bitRate: Double, buffer: TimeInterval) {
        switch resolvedWorkProfile() {
        case .ultraLight:
            return (bitRate: 900_000, buffer: 0.08)
        case .lowPower:
            return (bitRate: 1_350_000, buffer: 0.15)
        case .normal:
            break
        }

        let width = targetMaxPixelWidth()
        let baseRate = baseBitRate(for: width, preset: qualityPreset)
        var bitRate =
            baseRate * decodeBitRateFactor() * frameRateBitRateFactor()
                * autoFrameRateBitRateFactor
        var buffer = qualityAdjustedBuffer(baseBufferDuration())
        buffer += autoFrameRateBufferAdjustment

        if lightweightMode {
            bitRate = min(bitRate, 1_500_000)
            buffer = min(buffer, 0.25)
        }

        return (bitRate: max(bitRate, 500_000), buffer: max(buffer, 0))
    }

    func playVideo(url: URL) {
        installPlayerItem(url: url, attach: true)
    }

    /// Builds and installs a fresh AVPlayerItem for `url` on the shared player.
    ///
    /// With `attach: true` (the normal path) this reproduces the original
    /// `playVideo` behavior exactly: the shared player is attached to every
    /// layer and suspension/coverage state is re-applied. With `attach: false`
    /// (used by deep-suspend resume) the item is built in the background without
    /// touching the layers, so the freeze frame stays visible until the caller
    /// decides the item is ready and performs the attach itself.
    func installPlayerItem(url: URL, attach: Bool) {
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
        if shouldUsePlaybackLooper() {
            sharedLooper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            player.insert(item, after: nil)
            sharedLooper = nil
        }
        applyAudioSettings()
        if attach {
            applySuspensionStateToPlayers()
            evaluateForegroundCoverageState()
        }
    }

    @discardableResult
    private func applyDynamicPlaybackProfile() -> Bool {
        var targetItems: [AVPlayerItem] = []
        if let item = sharedPlayer?.currentItem {
            targetItems.append(item)
        }
        targetItems.append(
            contentsOf: dedicatedPlayersByScreenID.values.compactMap(\.currentItem)
        )
        guard !targetItems.isEmpty else {
            return false
        }
        let profile = resolvePlaybackProfile()
        for item in targetItems {
            item.preferredPeakBitRate = profile.bitRate
            item.preferredForwardBufferDuration = profile.buffer
        }
        return true
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

        var nextBitRateFactor = 1.0
        var nextBufferAdjustment: TimeInterval = 0

        if autoFrameRateEnabled {
            let processInfo = ProcessInfo.processInfo
            let thermalState = processInfo.thermalState
            let lowPower = processInfo.isLowPowerModeEnabled
            let displayCount = max(targetScreens().count, 1)

            if lowPower {
                nextBitRateFactor *= 0.82
                nextBufferAdjustment -= 0.25
            }

            if displayCount >= 2 {
                nextBitRateFactor *= 0.88
                nextBufferAdjustment -= 0.15
            }

            switch thermalState {
            case .serious:
                nextBitRateFactor *= 0.8
                nextBufferAdjustment -= 0.2
            case .critical:
                nextBitRateFactor *= 0.65
                nextBufferAdjustment -= 0.3
            default:
                break
            }
        }

        if batteryAwareQualityEnabled,
            let battery = Self.currentBatteryInfo(), battery.onBatteryPower, battery.percentage <= 10
        {
            nextBitRateFactor *= 0.6
            nextBufferAdjustment -= 0.3
        }

        nextBitRateFactor = min(max(nextBitRateFactor, 0.55), 1.0)
        nextBufferAdjustment = min(max(nextBufferAdjustment, -0.5), 0)

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
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            return (percentage, onBattery)
        }
        return nil
    }
}

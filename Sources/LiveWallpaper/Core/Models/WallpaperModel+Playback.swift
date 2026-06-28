import AVFoundation
import Foundation

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
        reapplyPlaybackForCurrentVideoIfNeeded()
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
        reapplyPlaybackForCurrentVideoIfNeeded()
    }

    func setQualityPreset(_ preset: QualityPreset) {
        guard qualityPreset != preset else {
            return
        }
        qualityPreset = preset
        UserDefaults.standard.set(preset.rawValue, forKey: "qualityPreset")
        requestPlaybackReconfiguration()
    }

    func setAutoFrameRateEnabled(_ enabled: Bool) {
        guard autoFrameRateEnabled != enabled else {
            return
        }
        autoFrameRateEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "autoFrameRateEnabled")
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
        if let currentPath = currentVideoPath,
           FileManager.default.fileExists(atPath: currentPath)
        {
            playVideo(url: URL(fileURLWithPath: currentPath))
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

    private func createConfiguredPlayer() -> AVQueuePlayer {
        let player = AVQueuePlayer()
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = lightweightMode
        player.isMuted = !audioEnabled
        player.volume = audioVolume
        return player
    }

    func ensureSharedPlayer() -> AVQueuePlayer {
        if let existing = sharedPlayer {
            return existing
        }
        let player = createConfiguredPlayer()
        sharedPlayer = player
        return player
    }

    private func attachSharedPlayerToAllViews() {
        let player = sharedPlayer
        for view in playerViews where view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    func stopAllPlayers() {
        if let player = sharedPlayer {
            player.pause()
            player.removeAllItems()
        }
        sharedLooper = nil
    }

    private func reapplyPlaybackForCurrentVideoIfNeeded() {
        requestPlaybackReconfiguration()
    }

    func applyLightweightSettings() {
        sharedPlayer?.automaticallyWaitsToMinimizeStalling = lightweightMode
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

    private func resolvePlaybackProfile() -> (bitRate: Double, buffer: TimeInterval) {
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
        attachSharedPlayerToAllViews()

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
        applySuspensionStateToPlayers()
        syncCurrentVideoToLockScreen()
        evaluateForegroundCoverageState()
    }

    @discardableResult
    private func applyDynamicPlaybackProfile() -> Bool {
        guard let player = sharedPlayer,
              let item = player.currentItem
        else {
            return false
        }
        let profile = resolvePlaybackProfile()
        item.preferredPeakBitRate = profile.bitRate
        item.preferredForwardBufferDuration = profile.buffer
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
            if let currentPath = currentVideoPath {
                playVideo(url: URL(fileURLWithPath: currentPath))
            }
        }
    }

    func startAutoFrameRateMonitoring() {
        autoFrameRateTimer?.invalidate()
        autoFrameRateTimer = nil
        evaluateAutoFrameRatePolicy()
        guard autoFrameRateEnabled else {
            return
        }
        autoFrameRateTimer = Timer.scheduledTimer(withTimeInterval: 12.0, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluateAutoFrameRatePolicy()
            }
        }
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

        guard autoFrameRateEnabled else {
            if autoFrameRateBitRateFactor != 1.0 || autoFrameRateBufferAdjustment != 0 {
                autoFrameRateBitRateFactor = 1.0
                autoFrameRateBufferAdjustment = 0
                applyDynamicPlaybackProfile()
            }
            return
        }

        let processInfo = ProcessInfo.processInfo
        let thermalState = processInfo.thermalState
        let lowPower = processInfo.isLowPowerModeEnabled
        let displayCount = max(targetScreens().count, 1)

        var nextBitRateFactor = 1.0
        var nextBufferAdjustment: TimeInterval = 0

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
}

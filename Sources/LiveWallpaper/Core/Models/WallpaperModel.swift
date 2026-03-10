import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Darwin

struct WallpaperPlaylist: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var videoPaths: [String]
}

@MainActor
final class WallpaperModel: ObservableObject {
    private let maxPlaylistCount: Int = 10
    private let wallpaperPresentationStorageKey: String = "wallpaperPresentationByPath"

    private struct ScreenSignature: Equatable {
        let displayID: UInt32
        let frame: CGRect
    }

    private struct PresentationCacheKey: Equatable {
        let screenID: String
        let boundsWidth: Double
        let boundsHeight: Double
        let fitMode: VideoFitMode
        let zoom: Double
        let offsetX: Double
        let offsetY: Double
        let videoAspectRatio: Double
    }

    private enum ChipClass {
        case appleSilicon
        case intel
    }

    private struct PlaybackEnvironment {
        let chipClass: ChipClass
        let logicalCores: Int
    }

    struct DisplayScreenInfo: Identifiable, Equatable {
        let id: String
        let name: String
        let frame: CGRect
    }

    struct WallpaperPresentation: Codable, Equatable {
        var fitMode: VideoFitMode
        var zoom: Double
        var offsetX: Double
        var offsetY: Double
    }

    private var windows: [NSWindow] = []
    private var playerViews: [PlayerView] = []
    private var players: [AVQueuePlayer] = []
    private var playerLoopers: [AVPlayerLooper?] = []
    private var screenChangeObserver: NSObjectProtocol?
    private var screenChangeWorkItem: DispatchWorkItem?
    private var windowRebuildWorkItem: DispatchWorkItem?
    private var windowOptionsWorkItem: DispatchWorkItem?
    private var windowRetireWorkItem: DispatchWorkItem?
    private var retiredWindows: [NSWindow] = []
    private var lastScreenSignatures: [ScreenSignature] = []
    private var frontmostAppObserver: NSObjectProtocol?
    private var activeSpaceObserver: NSObjectProtocol?
    private var playerItemEndObserver: NSObjectProtocol?
    private var axObserver: AXObserver?
    private var observedAppElement: AXUIElement?
    private var observedAppPID: pid_t?
    private var suspendedDisplayIDs: Set<String> = []
    private var autoFrameRateTimer: Timer?
    private var autoFrameRateBitRateFactor: Double = 1.0
    private var autoFrameRateBufferAdjustment: TimeInterval = 0
    private var coverageEvaluationWorkItem: DispatchWorkItem?
    private var playbackStartupValidationWorkItem: DispatchWorkItem?
    private var lastPlaybackFallbackPath: String?
    private var lastCoverageEvaluationAt: CFAbsoluteTime = 0
    private let playbackEnvironment: PlaybackEnvironment
    private var videoAspectRatioByPath: [String: Double] = [:]
    private var loadingVideoAspectRatioPaths: Set<String> = []
    private var presentationCacheByPlayerView: [ObjectIdentifier: PresentationCacheKey] = [:]

    @Published private(set) var clickThrough: Bool = true
    @Published private(set) var displayMode: DisplayMode = .mainOnly
    @Published private(set) var fitMode: VideoFitMode = .fill
    @Published private(set) var lightweightMode: Bool = false
    @Published private(set) var audioEnabled: Bool = false
    @Published private(set) var audioVolume: Float = 1.0
    @Published private(set) var frameRateLimit: FrameRateLimit = .off
    @Published private(set) var decodeMode: DecodeMode = .automatic
    @Published private(set) var qualityPreset: QualityPreset = .auto
    @Published private(set) var workProfile: WorkProfile = .normal
    @Published private(set) var autoFrameRateEnabled: Bool = true
    @Published private(set) var playlistPlaybackEnabled: Bool = false
    @Published private(set) var shufflePlaybackEnabled: Bool = false
    @Published private(set) var currentVideoIndex: Int?
    @Published private(set) var desktopLevelOffset: DesktopLevelOffset = .zero
    @Published private(set) var useFullScreenAuxiliary: Bool = false
    @Published private(set) var suspendWhenOtherAppFullScreen: Bool = false
    @Published private(set) var suspendExclusionBundleIDs: [String] = []

    @Published private(set) var playlists: [WallpaperPlaylist] = []
    @Published private(set) var selectedPlaylistID: UUID?
    @Published private(set) var currentVideoPath: String?
    @Published private(set) var registeredVideoPaths: [String] = []
    @Published private(set) var registeredVideoDisplayNames: [String: String] = [:]
    @Published private(set) var wallpaperPresentationByPath:
        [String: [String: WallpaperPresentation]] = [:]

    var visiblePlaylists: [WallpaperPlaylist] {
        playlists.filter { !$0.videoPaths.isEmpty }
    }

    var canAddPlaylist: Bool {
        playlists.count < maxPlaylistCount
    }

    var playlistCapacityText: String {
        "\(playlists.count)/\(maxPlaylistCount)"
    }

    var selectedPlaylistName: String {
        guard let selectedID = selectedPlaylistID,
              let playlist = playlists.first(where: { $0.id == selectedID })
        else {
            return "プレイリスト"
        }
        return playlist.name
    }

    var allRegisteredVideoPaths: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for playlist in playlists {
            for path in playlist.videoPaths where !seen.contains(path) {
                seen.insert(path)
                result.append(path)
            }
        }
        return result
    }

    init() {
        playbackEnvironment = Self.detectPlaybackEnvironment()
        configurePlayer()
        restoreState()
        rebuildWindows()
        if let savedPath: String = currentVideoPath {
            playVideo(url: URL(fileURLWithPath: savedPath))
        }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleScreenSync()
            }
        }
        configureForegroundCoverageMonitoring()
        evaluateForegroundCoverageState()
        startAutoFrameRateMonitoring()
    }

    deinit {
        screenChangeWorkItem?.cancel()
        windowRebuildWorkItem?.cancel()
        windowOptionsWorkItem?.cancel()
        windowRetireWorkItem?.cancel()
        coverageEvaluationWorkItem?.cancel()
        playbackStartupValidationWorkItem?.cancel()
        retiredWindows.removeAll()
        if let observer: any NSObjectProtocol = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = frontmostAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer: any NSObjectProtocol = playerItemEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        autoFrameRateTimer?.invalidate()
        autoFrameRateTimer = nil
        MainActor.assumeIsolated {
            removeAXObserver()
        }
    }

    private func configurePlayer() {
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
                guard self.playlistPlaybackEnabled else {
                    return
                }
                guard let finishedItem = note.object as? AVPlayerItem,
                      self.players.contains(where: { $0.currentItem === finishedItem })
                else {
                    return
                }
                guard self.registeredVideoPaths.count > 1 else {
                    for player in self.players {
                        player.seek(to: .zero)
                        player.play()
                    }
                    return
                }
                self.playNextVideo()
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

    private func ensurePlayerExists(at index: Int) {
        while players.count <= index {
            players.append(createConfiguredPlayer())
            playerLoopers.append(nil)
        }
    }

    private func trimPlaybackArrays(to count: Int) {
        if players.count <= count {
            return
        }
        for index in count ..< players.count {
            players[index].pause()
            players[index].removeAllItems()
        }
        players.removeLast(players.count - count)
        playerLoopers.removeLast(playerLoopers.count - count)
    }

    private func stopAllPlayers() {
        for player in players {
            player.pause()
            player.removeAllItems()
        }
        playerLoopers = Array(repeating: nil, count: players.count)
        suspendedDisplayIDs.removeAll()
    }

    private func displayIDForPlayer(at index: Int) -> String {
        if index < windows.count, let screen = windows[index].screen {
            return displayIDString(for: screen)
        }
        let screens = targetScreens()
        if index < screens.count {
            return displayIDString(for: screens[index])
        }
        return "main"
    }

    private func applySuspensionStateToPlayers() {
        for index in players.indices {
            let player = players[index]
            let displayID = displayIDForPlayer(at: index)
            if suspendedDisplayIDs.contains(displayID) {
                player.pause()
            } else {
                player.play()
            }
        }
    }

    private func targetPlaybackFrameRate() -> Int? {
        // NOTE:
        // Some movie files become black (audio only) when AVPlayerItem.videoComposition
        // is used for frame throttling. Keep compatibility by avoiding this path and
        // controlling load through bitrate/buffer tuning instead.
        nil
    }

    private func configureFrameRateComposition(
        item: AVPlayerItem,
        asset: AVURLAsset,
        targetFPS: Int?
    ) {
        guard let fps = targetFPS else {
            item.videoComposition = nil
            return
        }

        let composition = AVMutableVideoComposition(propertiesOf: asset)
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
        item.videoComposition = composition
    }

    private func reapplyPlaybackForCurrentVideoIfNeeded() {
        if let currentPath: String = currentVideoPath {
            playVideo(url: URL(fileURLWithPath: currentPath))
        }
    }

    private func schedulePlaybackStartupValidation(
        url: URL,
        usedFrameRateComposition: Bool
    ) {
        playbackStartupValidationWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            guard currentVideoPath == url.path else {
                return
            }
            guard !players.isEmpty else {
                return
            }

            let screens = targetScreens()
            if !screens.isEmpty,
               suspendedDisplayIDs.count >= screens.count
            {
                return
            }

            let hasFailedItem = players.contains { player in
                player.currentItem?.status == .failed
            }
            let isPlayingOrWaiting = players.contains { player in
                if player.rate > 0.01 {
                    return true
                }
                return player.timeControlStatus == .playing
                    || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }

            guard usedFrameRateComposition else {
                if !isPlayingOrWaiting {
                    NSLog("[Playback] startup stalled for \(url.lastPathComponent) even in fallback mode")
                }
                return
            }

            guard hasFailedItem || !isPlayingOrWaiting else {
                return
            }

            guard targetPlaybackFrameRate() != nil else {
                return
            }

            guard lastPlaybackFallbackPath != url.path else {
                return
            }

            lastPlaybackFallbackPath = url.path
            NSLog("[Playback] retry without frame-rate composition: \(url.lastPathComponent)")
            playVideo(url: url, bypassFrameRateComposition: true)
        }

        playbackStartupValidationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: workItem)
    }

    private func targetScreens() -> [NSScreen] {
        switch displayMode {
        case .allScreens:
            return NSScreen.screens
        case .mainOnly:
            if let main = NSScreen.main {
                return [main]
            }
            if let first = NSScreen.screens.first {
                return [first]
            }
            return []
        }
    }

    private func rebuildWindows() {
        let screens: [NSScreen] = targetScreens()

        if windows.count > screens.count {
            let extras = Array(windows[screens.count...])
            for window in extras {
                prepareWindowForRetire(window)
                window.orderOut(nil)
            }
            windows.removeLast(windows.count - screens.count)
            playerViews.removeLast(playerViews.count - screens.count)
            trimPlaybackArrays(to: screens.count)
            retireWindows(extras)
        }

        for (index, screen) in screens.enumerated() {
            ensurePlayerExists(at: index)
            if index < windows.count {
                let window = windows[index]
                let playerView = playerViews[index]

                applyWindowOptions(window)
                window.ignoresMouseEvents = clickThrough
                if window.frame != screen.frame {
                    window.setFrame(screen.frame, display: true)
                }
                applyPlayerPresentation(to: playerView, screen: screen)
                if playerView.playerLayer.player !== players[index] {
                    playerView.playerLayer.player = players[index]
                }
                if window.contentView !== playerView {
                    window.contentView = playerView
                }
                window.orderBack(nil)
                window.orderFront(nil)
                continue
            }

            let frame: NSRect = screen.frame
            let window = NSWindow(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )

            applyWindowOptions(window)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = clickThrough
            window.setFrame(frame, display: true)

            let playerView = PlayerView(frame: CGRect(origin: .zero, size: frame.size))
            playerView.autoresizingMask = [.width, .height]
            applyPlayerPresentation(to: playerView, screen: screen)
            playerView.playerLayer.player = players[index]
            window.contentView = playerView
            window.orderBack(nil)
            window.orderFront(nil)

            windows.append(window)
            playerViews.append(playerView)
        }

        trimPlaybackArrays(to: screens.count)

        let validDisplayIDs = Set(screens.map { displayIDString(for: $0) })
        suspendedDisplayIDs = suspendedDisplayIDs.intersection(validDisplayIDs)
        applySuspensionStateToPlayers()

        lastScreenSignatures = screenSignatures(for: screens)
    }

    private func prepareWindowForRetire(_ window: NSWindow) {
        if let playerView = window.contentView as? PlayerView {
            presentationCacheByPlayerView.removeValue(forKey: ObjectIdentifier(playerView))
            playerView.playerLayer.player = nil
        }
        window.contentView = nil
    }

    private func retireWindows(_ windowsToRetire: [NSWindow]) {
        guard !windowsToRetire.isEmpty else {
            return
        }

        retiredWindows.append(contentsOf: windowsToRetire)
        windowRetireWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }

            let targets = retiredWindows
            retiredWindows.removeAll()
            for window in targets {
                prepareWindowForRetire(window)
                window.close()
            }
        }

        windowRetireWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    private func applyWindowOptions(_ window: NSWindow) {
        let baseLevel = Int(CGWindowLevelForKey(.desktopWindow))
        let levelValue: Int = baseLevel + desktopLevelOffset.rawValue
        window.level = NSWindow.Level(rawValue: levelValue)

        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if useFullScreenAuxiliary {
            behavior.insert(.fullScreenAuxiliary)
        }
        window.collectionBehavior = behavior
    }

    private func applyPlayerPresentation(to playerView: PlayerView, screen: NSScreen?) {
        let presentation = resolvedPresentation(for: currentVideoPath, screen: screen)
        let isFitMode: Bool = presentation.fitMode == .fit
        let screenID = displayIDString(for: screen)
        let videoAspect = resolvedVideoAspectRatio(for: currentVideoPath, screenID: screenID)
        let roundedZoom = (presentation.zoom * 10_000).rounded() / 10_000
        let roundedOffsetX = (presentation.offsetX * 10_000).rounded() / 10_000
        let roundedOffsetY = (presentation.offsetY * 10_000).rounded() / 10_000
        let roundedAspect = (videoAspect * 10_000).rounded() / 10_000
        let key = PresentationCacheKey(
            screenID: screenID,
            boundsWidth: playerView.bounds.width,
            boundsHeight: playerView.bounds.height,
            fitMode: presentation.fitMode,
            zoom: roundedZoom,
            offsetX: roundedOffsetX,
            offsetY: roundedOffsetY,
            videoAspectRatio: roundedAspect
        )
        let playerID = ObjectIdentifier(playerView)
        if presentationCacheByPlayerView[playerID] == key {
            return
        }

        let geometry = WallpaperGeometry.resolve(
            containerSize: playerView.bounds.size,
            videoAspectRatio: videoAspect,
            fitMode: presentation.fitMode,
            zoom: presentation.zoom,
            offsetX: presentation.offsetX,
            offsetY: presentation.offsetY
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerView.playerLayer.videoGravity = isFitMode ? .resizeAspect : .resizeAspectFill
        playerView.playerLayer.backgroundColor = NSColor.black.cgColor
        playerView.playerLayer.setAffineTransform(.identity)

        let containerWidth = max(playerView.bounds.width, 1)
        let containerHeight = max(playerView.bounds.height, 1)
        let renderedWidth = max(CGFloat(geometry.renderedSize.width), 1)
        let renderedHeight = max(CGFloat(geometry.renderedSize.height), 1)
        let tx = CGFloat(geometry.translation.width)
        let ty = CGFloat(geometry.translation.height)
        let originX = ((containerWidth - renderedWidth) * 0.5) + tx
        let originY = ((containerHeight - renderedHeight) * 0.5) + ty

        playerView.playerLayer.frame = CGRect(
            x: originX,
            y: originY,
            width: renderedWidth,
            height: renderedHeight
        )
        CATransaction.commit()
        presentationCacheByPlayerView[playerID] = key
    }

    private func scheduleScreenSync() {
        screenChangeWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            syncWindowsToCurrentScreens()
        }

        screenChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func syncWindowsToCurrentScreens() {
        let screens = targetScreens()
        let signatures = screenSignatures(for: screens)

        guard signatures != lastScreenSignatures else {
            return
        }

        if screens.count == windows.count {
            for (index, screen) in screens.enumerated() {
                if windows[index].frame != screen.frame {
                    windows[index].setFrame(screen.frame, display: true)
                }
                applyPlayerPresentation(to: playerViews[index], screen: screen)
            }
            lastScreenSignatures = signatures
            return
        }

        rebuildWindows()
    }

    private func scheduleWindowRebuild(delay: TimeInterval = 0.2) {
        windowRebuildWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            rebuildWindows()
        }

        windowRebuildWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + min(max(delay, 0.2), 0.5), execute: workItem)
    }

    private func scheduleWindowOptionsApply(delay: TimeInterval = 0.02) {
        windowOptionsWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            for window in windows {
                applyWindowOptions(window)
            }
        }

        windowOptionsWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func screenSignatures(for screens: [NSScreen]) -> [ScreenSignature] {
        screens.map { screen in
            let displayID: UInt32 =
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                    .uint32Value ?? 0
            return ScreenSignature(displayID: displayID, frame: screen.frame)
        }
    }

    private func displayIDString(for screen: NSScreen?) -> String {
        guard let screen else {
            return "main"
        }
        let value =
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value ?? 0
        return String(value)
    }

    private func defaultPresentation() -> WallpaperPresentation {
        WallpaperPresentation(fitMode: fitMode, zoom: 1.0, offsetX: 0.0, offsetY: 0.0)
    }

    private func resolvedPresentation(
        for path: String?,
        screen: NSScreen?
    ) -> WallpaperPresentation {
        guard let path else {
            return defaultPresentation()
        }
        let screenID = displayIDString(for: screen)
        if let presentation = wallpaperPresentationByPath[path]?[screenID] {
            return presentation
        }
        return defaultPresentation()
    }

    func availableDisplayScreens() -> [DisplayScreenInfo] {
        let screens = NSScreen.screens
        return screens.enumerated().map { index, screen in
            let screenID = displayIDString(for: screen)
            let isMain = (NSScreen.main == screen)
            let name = isMain ? "画面\(index + 1) (メイン)" : "画面\(index + 1)"
            return DisplayScreenInfo(id: screenID, name: name, frame: screen.frame)
        }
    }

    private func screenForID(_ screenID: String) -> NSScreen? {
        NSScreen.screens.first { displayIDString(for: $0) == screenID }
    }

    private func presentation(for path: String, screenID: String) -> WallpaperPresentation {
        if let presentation = wallpaperPresentationByPath[path]?[screenID] {
            return presentation
        }
        return defaultPresentation()
    }

    private func updatePresentation(
        _ presentation: WallpaperPresentation, for path: String, screenID: String
    ) {
        var pathMap = wallpaperPresentationByPath[path] ?? [:]
        pathMap[screenID] = presentation
        wallpaperPresentationByPath[path] = pathMap
        persistWallpaperPresentationState()
        refreshPlayerPresentations()
    }

    private func screenAspectRatio(for screenID: String) -> Double {
        guard let screen = screenForID(screenID) else {
            return 16.0 / 9.0
        }
        let width = Double(max(screen.frame.width, 1))
        let height = Double(max(screen.frame.height, 1))
        return width / height
    }

    private func videoAspectRatio(for path: String) -> Double {
        if let cached = videoAspectRatioByPath[path] {
            return cached
        }

        ensureVideoAspectRatioLoaded(for: path)
        return 16.0 / 9.0
    }

    private func resolvedVideoAspectRatio(for path: String?, screenID: String) -> Double {
        guard let path else {
            return screenAspectRatio(for: screenID)
        }
        return videoAspectRatio(for: path)
    }

    private func ensureVideoAspectRatioLoaded(for path: String) {
        guard videoAspectRatioByPath[path] == nil else {
            return
        }
        guard !loadingVideoAspectRatioPaths.contains(path) else {
            return
        }
        loadingVideoAspectRatioPaths.insert(path)

        let url = URL(fileURLWithPath: path)
        Task { [weak self] in
            guard let self else {
                return
            }

            let ratio: Double
            do {
                let asset = AVURLAsset(url: url)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                if let track = tracks.first {
                    let naturalSize = try await track.load(.naturalSize)
                    let preferredTransform = try await track.load(.preferredTransform)
                    let transformed = naturalSize.applying(preferredTransform)
                    let width = Double(max(abs(transformed.width), 1))
                    let height = Double(max(abs(transformed.height), 1))
                    ratio = width / height
                } else {
                    ratio = 16.0 / 9.0
                }
            } catch {
                ratio = 16.0 / 9.0
            }

            videoAspectRatioByPath[path] = ratio
            loadingVideoAspectRatioPaths.remove(path)
            refreshPlayerPresentations()
        }
    }

    private func clampedOffset(
        x: Double,
        y: Double,
        for _: WallpaperPresentation,
        path _: String,
        screenID _: String
    ) -> (x: Double, y: Double) {
        let clampedX = WallpaperGeometry.clampOffset(x)
        let clampedY = WallpaperGeometry.clampOffset(y)
        return (x: clampedX, y: clampedY)
    }

    func wallpaperFitMode(path: String, screenID: String) -> VideoFitMode {
        presentation(for: path, screenID: screenID).fitMode
    }

    func wallpaperZoom(path: String, screenID: String) -> Double {
        presentation(for: path, screenID: screenID).zoom
    }

    func wallpaperOffsetX(path: String, screenID: String) -> Double {
        presentation(for: path, screenID: screenID).offsetX
    }

    func wallpaperOffsetY(path: String, screenID: String) -> Double {
        presentation(for: path, screenID: screenID).offsetY
    }

    func wallpaperOffsetLimitX(path: String, screenID: String) -> Double {
        let current = presentation(for: path, screenID: screenID)
        let geometry = WallpaperGeometry.resolve(
            containerSize: screenForID(screenID)?.frame.size ?? CGSize(width: 1920, height: 1080),
            videoAspectRatio: videoAspectRatio(for: path),
            fitMode: current.fitMode,
            zoom: current.zoom,
            offsetX: current.offsetX,
            offsetY: current.offsetY
        )
        return geometry.maxPan.width
    }

    func wallpaperOffsetLimitY(path: String, screenID: String) -> Double {
        let current = presentation(for: path, screenID: screenID)
        let geometry = WallpaperGeometry.resolve(
            containerSize: screenForID(screenID)?.frame.size ?? CGSize(width: 1920, height: 1080),
            videoAspectRatio: videoAspectRatio(for: path),
            fitMode: current.fitMode,
            zoom: current.zoom,
            offsetX: current.offsetX,
            offsetY: current.offsetY
        )
        return geometry.maxPan.height
    }

    func wallpaperRenderGeometry(path: String, screenID: String, containerSize: CGSize)
        -> WallpaperRenderGeometry
    {
        let current = presentation(for: path, screenID: screenID)
        return WallpaperGeometry.resolve(
            containerSize: containerSize,
            videoAspectRatio: videoAspectRatio(for: path),
            fitMode: current.fitMode,
            zoom: current.zoom,
            offsetX: current.offsetX,
            offsetY: current.offsetY
        )
    }

    func wallpaperRenderGeometry(
        path: String,
        screenID _: String,
        containerSize: CGSize,
        fitMode: VideoFitMode,
        zoom: Double,
        offsetX: Double,
        offsetY: Double
    ) -> WallpaperRenderGeometry {
        WallpaperGeometry.resolve(
            containerSize: containerSize,
            videoAspectRatio: videoAspectRatio(for: path),
            fitMode: fitMode,
            zoom: zoom,
            offsetX: offsetX,
            offsetY: offsetY
        )
    }

    func setWallpaperPresentation(
        fitMode: VideoFitMode,
        zoom: Double,
        offsetX: Double,
        offsetY: Double,
        path: String,
        screenID: String
    ) {
        var current = presentation(for: path, screenID: screenID)
        current.fitMode = fitMode
        current.zoom = min(max(zoom, 1.0), 3.0)
        let clamped = clampedOffset(
            x: offsetX,
            y: offsetY,
            for: current,
            path: path,
            screenID: screenID
        )
        current.offsetX = clamped.x
        current.offsetY = clamped.y
        updatePresentation(current, for: path, screenID: screenID)
    }

    func setWallpaperFitMode(_ mode: VideoFitMode, path: String, screenID: String) {
        var current = presentation(for: path, screenID: screenID)
        current.fitMode = mode
        let clamped = clampedOffset(
            x: current.offsetX,
            y: current.offsetY,
            for: current,
            path: path,
            screenID: screenID
        )
        current.offsetX = clamped.x
        current.offsetY = clamped.y
        updatePresentation(current, for: path, screenID: screenID)
    }

    func setWallpaperZoom(_ zoom: Double, path: String, screenID: String) {
        var current = presentation(for: path, screenID: screenID)
        current.zoom = min(max(zoom, 1.0), 3.0)
        let clamped = clampedOffset(
            x: current.offsetX,
            y: current.offsetY,
            for: current,
            path: path,
            screenID: screenID
        )
        current.offsetX = clamped.x
        current.offsetY = clamped.y
        updatePresentation(current, for: path, screenID: screenID)
    }

    func setWallpaperOffset(x: Double, y: Double, path: String, screenID: String) {
        var current = presentation(for: path, screenID: screenID)
        let clamped = clampedOffset(
            x: x,
            y: y,
            for: current,
            path: path,
            screenID: screenID
        )
        current.offsetX = clamped.x
        current.offsetY = clamped.y
        updatePresentation(current, for: path, screenID: screenID)
    }

    func moveWallpaperOffset(dx: Double, dy: Double, path: String, screenID: String) {
        let current = presentation(for: path, screenID: screenID)
        setWallpaperOffset(
            x: current.offsetX + dx,
            y: current.offsetY + dy,
            path: path,
            screenID: screenID
        )
    }

    func resetWallpaperPresentation(path: String, screenID: String) {
        updatePresentation(defaultPresentation(), for: path, screenID: screenID)
    }

    func commitWallpaperPresentation(path: String, screenID: String) {
        let current = presentation(for: path, screenID: screenID)
        updatePresentation(current, for: path, screenID: screenID)
    }

    private func refreshPlayerPresentations() {
        let screens = targetScreens()
        for index in playerViews.indices {
            let screen = index < screens.count ? screens[index] : nil
            applyPlayerPresentation(to: playerViews[index], screen: screen)
        }
    }

    func setClickThrough(_ enabled: Bool) {
        guard clickThrough != enabled else {
            return
        }
        clickThrough = enabled
        for window in windows {
            window.ignoresMouseEvents = enabled
        }
        UserDefaults.standard.set(enabled, forKey: "clickThrough")
    }

    func setDisplayMode(_ mode: DisplayMode) {
        guard displayMode != mode else {
            return
        }
        displayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "displayMode")
        scheduleWindowRebuild()
    }

    func setFitMode(_ mode: VideoFitMode) {
        guard fitMode != mode else {
            return
        }
        fitMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "fitMode")
        refreshPlayerPresentations()
    }

    func setLightweightMode(_ enabled: Bool) {
        guard lightweightMode != enabled else {
            return
        }
        lightweightMode = enabled
        UserDefaults.standard.set(enabled, forKey: "lightweightMode")
        applyLightweightSettings()
        if let currentPath: String = currentVideoPath {
            playVideo(url: URL(fileURLWithPath: currentPath))
        }
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
        if let currentPath: String = currentVideoPath {
            playVideo(url: URL(fileURLWithPath: currentPath))
        }
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
        if let currentPath: String = currentVideoPath {
            playVideo(url: URL(fileURLWithPath: currentPath))
        }
    }

    func setPlaylistPlaybackEnabled(_ enabled: Bool) {
        guard playlistPlaybackEnabled != enabled else {
            return
        }
        playlistPlaybackEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "playlistPlaybackEnabled")
        if !enabled {
            setShufflePlaybackEnabled(false)
        }
        if let currentPath: String = currentVideoPath {
            playVideo(url: URL(fileURLWithPath: currentPath))
        }
    }

    func setShufflePlaybackEnabled(_ enabled: Bool) {
        let normalized = playlistPlaybackEnabled ? enabled : false
        guard shufflePlaybackEnabled != normalized else {
            return
        }
        shufflePlaybackEnabled = normalized
        UserDefaults.standard.set(normalized, forKey: "shufflePlaybackEnabled")
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
        setDesktopLevelOffset(.zero)
        setFullScreenAuxiliary(false)
        _ = setSuspendWhenOtherAppFullScreen(false)
        if !suspendExclusionBundleIDs.isEmpty {
            suspendExclusionBundleIDs.removeAll()
            UserDefaults.standard.set([], forKey: "suspendExclusionBundleIDs")
            evaluateForegroundCoverageState()
        }
    }

    func removeEmptyPlaylists() {
        let nonEmpty = playlists.filter { !$0.videoPaths.isEmpty }
        guard nonEmpty.count != playlists.count else {
            return
        }

        playlists = nonEmpty
        ensureSelectedPlaylist()
        syncActivePlaylistPaths()

        let validPaths = Set(playlists.flatMap(\.videoPaths))
        if let currentPath = currentVideoPath,
           !validPaths.contains(currentPath)
        {
            if let firstPath = registeredVideoPaths.first {
                selectRegisteredVideo(path: firstPath)
                return
            }
            stopAllPlayers()
            currentVideoPath = nil
            currentVideoIndex = nil
            UserDefaults.standard.removeObject(forKey: "videoPath")
        } else if let currentPath = currentVideoPath,
                  let index = registeredVideoPaths.firstIndex(of: currentPath)
        {
            currentVideoIndex = index
        } else {
            currentVideoPath = registeredVideoPaths.first
            currentVideoIndex = currentVideoPath.flatMap { registeredVideoPaths.firstIndex(of: $0) }
        }

        pruneDisplayNamesForExistingPaths()
        persistPlaylistState()
    }

    func isSelectedPlaylist(_ playlistID: UUID) -> Bool {
        selectedPlaylistID == playlistID
    }

    func playlistName(for playlistID: UUID) -> String {
        playlists.first(where: { $0.id == playlistID })?.name ?? "プレイリスト"
    }

    func setPlaylistName(_ name: String, for playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else {
            return
        }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return
        }
        guard playlists[index].name != cleaned else {
            return
        }
        playlists[index].name = cleaned
        persistPlaylistState()
    }

    @discardableResult
    func createPlaylist(named name: String? = nil) -> UUID? {
        guard canAddPlaylist else {
            return nil
        }
        let cleaned = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let playlistName = cleaned.isEmpty ? "プレイリスト\(playlists.count + 1)" : cleaned
        let playlist = WallpaperPlaylist(id: UUID(), name: playlistName, videoPaths: [])
        playlists.append(playlist)
        if selectedPlaylistID == nil {
            selectedPlaylistID = playlist.id
            syncActivePlaylistPaths()
        }
        persistPlaylistState()
        return playlist.id
    }

    func playlistContainsVideo(_ playlistID: UUID, path: String) -> Bool {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else {
            return false
        }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return playlists[index].videoPaths.contains(trimmed)
    }

    @discardableResult
    func addRegisteredVideo(path: String, to playlistID: UUID) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        guard FileManager.default.fileExists(atPath: trimmed) else {
            return false
        }
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else {
            return false
        }
        if !playlists[index].videoPaths.contains(trimmed) {
            playlists[index].videoPaths.append(trimmed)
        }
        if selectedPlaylistID == playlistID {
            syncActivePlaylistPaths()
            if let currentPath = currentVideoPath {
                currentVideoIndex = registeredVideoPaths.firstIndex(of: currentPath)
            }
        }
        persistPlaylistState()
        return true
    }

    @discardableResult
    func addVideo(path: String, to playlistID: UUID, activateAfterAdding: Bool = true) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        let sourceURL = URL(fileURLWithPath: trimmed)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return false
        }
        guard playlists.contains(where: { $0.id == playlistID }) else {
            return false
        }

        let destinationPath: String
        if let cacheDirectory = cacheDirectoryURL(), sourceURL.path.hasPrefix(cacheDirectory.path) {
            destinationPath = sourceURL.path
        } else {
            guard let localURL = importVideoToAppSupport(from: sourceURL) else {
                return false
            }
            destinationPath = localURL.path
            if registeredVideoDisplayNames[destinationPath] == nil {
                registeredVideoDisplayNames[destinationPath] = sourceURL.lastPathComponent
                UserDefaults.standard.set(
                    registeredVideoDisplayNames, forKey: "registeredVideoDisplayNames"
                )
            }
        }

        _ = addRegisteredVideo(path: destinationPath, to: playlistID)

        guard activateAfterAdding else {
            return true
        }

        selectPlaylist(playlistID)
        selectRegisteredVideo(path: destinationPath)
        return true
    }

    func removePlaylist(_ playlistID: UUID) {
        guard let removeIndex = playlists.firstIndex(where: { $0.id == playlistID }) else {
            return
        }
        let removedPaths = Set(playlists[removeIndex].videoPaths)
        let removedCurrent = removedPaths.contains(currentVideoPath ?? "")

        playlists.remove(at: removeIndex)
        ensureSelectedPlaylist()
        syncActivePlaylistPaths()

        if removedCurrent {
            if let firstPath = registeredVideoPaths.first {
                selectRegisteredVideo(path: firstPath)
            } else {
                stopAllPlayers()
                currentVideoPath = nil
                currentVideoIndex = nil
                UserDefaults.standard.removeObject(forKey: "videoPath")
            }
        } else if let currentPath = currentVideoPath,
                  let existingIndex = registeredVideoPaths.firstIndex(of: currentPath)
        {
            currentVideoIndex = existingIndex
        } else {
            currentVideoPath = registeredVideoPaths.first
            currentVideoIndex = currentVideoPath.flatMap { registeredVideoPaths.firstIndex(of: $0) }
        }

        pruneDisplayNamesForExistingPaths()
        persistPlaylistState()
    }

    func selectPlaylist(_ playlistID: UUID) {
        guard playlists.contains(where: { $0.id == playlistID }) else {
            return
        }
        selectedPlaylistID = playlistID
        syncActivePlaylistPaths()

        if let currentPath = currentVideoPath,
           registeredVideoPaths.contains(currentPath)
        {
            currentVideoIndex = registeredVideoPaths.firstIndex(of: currentPath)
            persistPlaylistState()
            return
        }

        if let firstPath = registeredVideoPaths.first {
            selectRegisteredVideo(path: firstPath)
        } else {
            stopAllPlayers()
            currentVideoPath = nil
            currentVideoIndex = nil
            UserDefaults.standard.removeObject(forKey: "videoPath")
            persistPlaylistState()
        }
    }

    @discardableResult
    func createPlaylistAndSetVideo(path: String) -> Bool {
        guard canAddPlaylist else {
            return false
        }

        let originalSelectedID = selectedPlaylistID
        guard let newPlaylistID = createPlaylist() else {
            return false
        }
        selectedPlaylistID = newPlaylistID
        syncActivePlaylistPaths()
        persistPlaylistState()

        let beforeCount = registeredVideoPaths.count
        setVideo(path: path)
        let didAdd = registeredVideoPaths.count > beforeCount
        if didAdd {
            return true
        }

        if let index = playlists.firstIndex(where: { $0.id == newPlaylistID }) {
            playlists.remove(at: index)
        }
        selectedPlaylistID = originalSelectedID
        ensureSelectedPlaylist()
        syncActivePlaylistPaths()
        persistPlaylistState()
        return false
    }

    func playNextVideo() {
        guard !registeredVideoPaths.isEmpty else {
            return
        }
        guard registeredVideoPaths.count > 1 else {
            if let currentPath = currentVideoPath {
                playVideo(url: URL(fileURLWithPath: currentPath))
            }
            return
        }
        let nextIndex = resolvedNextIndex(forward: true)
        selectRegisteredVideo(path: registeredVideoPaths[nextIndex])
    }

    func playPreviousVideo() {
        guard !registeredVideoPaths.isEmpty else {
            return
        }
        guard registeredVideoPaths.count > 1 else {
            if let currentPath = currentVideoPath {
                playVideo(url: URL(fileURLWithPath: currentPath))
            }
            return
        }
        let previousIndex = resolvedNextIndex(forward: false)
        selectRegisteredVideo(path: registeredVideoPaths[previousIndex])
    }

    private func resolvedNextIndex(forward: Bool) -> Int {
        guard !registeredVideoPaths.isEmpty else {
            return 0
        }
        let baseIndex = currentVideoIndex ?? 0
        let maxIndex = registeredVideoPaths.count - 1
        if shufflePlaybackEnabled, registeredVideoPaths.count > 2 {
            var candidate = Int.random(in: 0 ... maxIndex)
            while candidate == baseIndex {
                candidate = Int.random(in: 0 ... maxIndex)
            }
            return candidate
        }
        if forward {
            return (baseIndex + 1) % registeredVideoPaths.count
        }
        return (baseIndex - 1 + registeredVideoPaths.count) % registeredVideoPaths.count
    }

    func setDesktopLevelOffset(_ offset: DesktopLevelOffset) {
        guard desktopLevelOffset != offset else {
            return
        }
        desktopLevelOffset = offset
        scheduleWindowOptionsApply()
    }

    func setFullScreenAuxiliary(_ enabled: Bool) {
        guard useFullScreenAuxiliary != enabled else {
            return
        }
        useFullScreenAuxiliary = enabled
        scheduleWindowOptionsApply()
    }

    @discardableResult
    func setSuspendWhenOtherAppFullScreen(_ enabled: Bool) -> Bool {
        guard suspendWhenOtherAppFullScreen != enabled else {
            if enabled {
                evaluateForegroundCoverageState()
            } else {
                applyCoveringAppSuspension(false)
            }
            return true
        }

        suspendWhenOtherAppFullScreen = enabled
        UserDefaults.standard.set(enabled, forKey: "suspendWhenOtherAppFullScreen")
        configureForegroundCoverageMonitoring()
        evaluateForegroundCoverageState()
        return true
    }

    func addSuspendExclusionBundleID(_ bundleID: String) {
        let normalized = normalizeBundleID(bundleID)
        guard !normalized.isEmpty else {
            return
        }
        guard !suspendExclusionBundleIDs.contains(normalized) else {
            return
        }
        suspendExclusionBundleIDs.append(normalized)
        suspendExclusionBundleIDs.sort()
        UserDefaults.standard.set(suspendExclusionBundleIDs, forKey: "suspendExclusionBundleIDs")
        evaluateForegroundCoverageState()
    }

    func removeSuspendExclusionBundleID(_ bundleID: String) {
        let normalized = normalizeBundleID(bundleID)
        guard let index = suspendExclusionBundleIDs.firstIndex(of: normalized) else {
            return
        }
        suspendExclusionBundleIDs.remove(at: index)
        UserDefaults.standard.set(suspendExclusionBundleIDs, forKey: "suspendExclusionBundleIDs")
        evaluateForegroundCoverageState()
    }

    @discardableResult
    func addFrontmostAppToSuspendExclusions() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        guard let bundleID = app.bundleIdentifier else {
            return false
        }
        addSuspendExclusionBundleID(bundleID)
        return true
    }

    @discardableResult
    func addSuspendExclusionFromAppURL(_ appURL: URL) -> Bool {
        let resolvedURL = appURL.resolvingSymlinksInPath()
        guard resolvedURL.pathExtension.lowercased() == "app" else {
            return false
        }
        guard let bundle = Bundle(url: resolvedURL),
              let bundleID = bundle.bundleIdentifier
        else {
            return false
        }
        addSuspendExclusionBundleID(bundleID)
        return true
    }

    func setVideo(path: String) {
        let trimmed: String = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        let sourceURL = URL(fileURLWithPath: trimmed)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return
        }

        ensureSelectedPlaylist()

        if registeredVideoPaths.contains(sourceURL.path) {
            selectRegisteredVideo(path: sourceURL.path)
            return
        }

        if let cacheDirectory = cacheDirectoryURL(), sourceURL.path.hasPrefix(cacheDirectory.path) {
            addVideoPathToSelectedPlaylist(sourceURL.path)
            selectRegisteredVideo(path: sourceURL.path)
            return
        }

        guard let localURL: URL = importVideoToAppSupport(from: sourceURL) else {
            return
        }

        addVideoPathToSelectedPlaylist(
            localURL.path,
            preferredDisplayName: sourceURL.lastPathComponent
        )
        selectRegisteredVideo(path: localURL.path)
    }

    func registeredVideoDisplayName(for path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored = registeredVideoDisplayNames[trimmed], !stored.isEmpty {
            return stored
        }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    func setRegisteredVideoDisplayName(_ displayName: String, for path: String) {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard registeredVideoPaths.contains(trimmedPath) else {
            return
        }

        let cleaned = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName =
            cleaned.isEmpty
                ? URL(fileURLWithPath: trimmedPath).lastPathComponent
                : cleaned

        guard registeredVideoDisplayNames[trimmedPath] != finalName else {
            return
        }

        registeredVideoDisplayNames[trimmedPath] = finalName
        UserDefaults.standard.set(
            registeredVideoDisplayNames,
            forKey: "registeredVideoDisplayNames"
        )
    }

    func selectRegisteredVideo(path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        guard FileManager.default.fileExists(atPath: trimmed) else {
            removeRegisteredVideo(path: trimmed)
            return
        }
        addVideoPathToSelectedPlaylist(trimmed)
        syncActivePlaylistPaths()
        currentVideoPath = trimmed
        currentVideoIndex = registeredVideoPaths.firstIndex(of: trimmed)
        UserDefaults.standard.set(trimmed, forKey: "videoPath")
        refreshPlayerPresentations()
        playVideo(url: URL(fileURLWithPath: trimmed))
        persistPlaylistState()
    }

    func removeRegisteredVideo(path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let selectedIndex = selectedPlaylistIndex() else {
            return
        }
        guard let index = playlists[selectedIndex].videoPaths.firstIndex(of: trimmed) else {
            return
        }
        let wasCurrent = currentVideoPath == trimmed
        playlists[selectedIndex].videoPaths.remove(at: index)
        syncActivePlaylistPaths()
        registeredVideoDisplayNames.removeValue(forKey: trimmed)
        UserDefaults.standard.set(
            registeredVideoDisplayNames,
            forKey: "registeredVideoDisplayNames"
        )

        if playlists[selectedIndex].videoPaths.isEmpty {
            playlists.remove(at: selectedIndex)
            ensureSelectedPlaylist()
            syncActivePlaylistPaths()
        }

        if wasCurrent {
            if !registeredVideoPaths.isEmpty {
                let nextIndex = min(index, registeredVideoPaths.count - 1)
                selectRegisteredVideo(path: registeredVideoPaths[nextIndex])
            } else {
                stopAllPlayers()
                currentVideoPath = nil
                currentVideoIndex = nil
                UserDefaults.standard.removeObject(forKey: "videoPath")
                persistPlaylistState()
            }
            return
        }

        if let currentPath = currentVideoPath,
           let existingIndex = registeredVideoPaths.firstIndex(of: currentPath)
        {
            currentVideoIndex = existingIndex
        } else {
            currentVideoIndex = nil
        }
        persistPlaylistState()
    }

    func openCacheFolder() {
        guard let directory: URL = cacheDirectoryURL() else {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            NSWorkspace.shared.open(directory)
        } catch {
            return
        }
    }

    func clearCache() -> Bool {
        guard let directory = cacheDirectoryURL() else {
            return false
        }

        let thumbnailDirectory = thumbnailCacheDirectoryURL()

        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            if let thumbnailDirectory,
               FileManager.default.fileExists(atPath: thumbnailDirectory.path)
            {
                try FileManager.default.removeItem(at: thumbnailDirectory)
            }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            if let thumbnailDirectory {
                try FileManager.default.createDirectory(
                    at: thumbnailDirectory,
                    withIntermediateDirectories: true
                )
            }
            playlists.removeAll()
            selectedPlaylistID = nil
            registeredVideoPaths.removeAll()
            UserDefaults.standard.removeObject(forKey: "registeredVideoPaths")
            registeredVideoDisplayNames.removeAll()
            UserDefaults.standard.set(
                registeredVideoDisplayNames,
                forKey: "registeredVideoDisplayNames"
            )
            wallpaperPresentationByPath.removeAll()
            UserDefaults.standard.removeObject(forKey: wallpaperPresentationStorageKey)
            stopAllPlayers()
            currentVideoPath = nil
            currentVideoIndex = nil
            UserDefaults.standard.removeObject(forKey: "videoPath")
            persistPlaylistState()
            return true
        } catch {
            return false
        }
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

    private func applyLightweightSettings() {
        for player in players {
            player.automaticallyWaitsToMinimizeStalling = lightweightMode
        }
    }

    private func applyAudioSettings() {
        for player in players {
            player.isMuted = !audioEnabled
            player.volume = audioVolume
        }
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

    private static func detectPlaybackEnvironment() -> PlaybackEnvironment {
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
        case .automatic:
            switch playbackEnvironment.chipClass {
            case .appleSilicon:
                return .balanced
            case .intel:
                return playbackEnvironment.logicalCores >= 8 ? .balanced : .efficiency
            }
        case .gpuAdaptive:
            switch playbackEnvironment.chipClass {
            case .appleSilicon:
                return .balanced
            case .intel:
                if playbackEnvironment.logicalCores >= 8 {
                    return .balanced
                }
                return .efficiency
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
        case .automatic:
            return 1.0
        case .gpuAdaptive:
            return 1.0
        case .balanced:
            return 1.05
        case .efficiency:
            return 0.75
        }
    }

    private func baseBufferDuration() -> TimeInterval {
        switch resolvedDecodeMode() {
        case .automatic:
            return 1.0
        case .gpuAdaptive:
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

    private func playVideo(
        url: URL,
        bypassFrameRateComposition: Bool = false
    ) {
        let effectiveDecode = resolvedDecodeMode()
        let asset = AVURLAsset(
            url: url,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: effectiveDecode == .balanced
            ]
        )
        let profile = resolvePlaybackProfile()
        let targetFPS = bypassFrameRateComposition ? nil : targetPlaybackFrameRate()
        stopAllPlayers()

        if !bypassFrameRateComposition {
            lastPlaybackFallbackPath = nil
        }

        if players.isEmpty {
            evaluateForegroundCoverageState()
            return
        }

        for index in players.indices {
            let player = players[index]
            let item = AVPlayerItem(asset: asset)
            item.preferredPeakBitRate = bypassFrameRateComposition
                ? max(profile.bitRate, 2_000_000)
                : profile.bitRate
            item.preferredForwardBufferDuration = bypassFrameRateComposition
                ? max(profile.buffer, 0.3)
                : profile.buffer
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
            configureFrameRateComposition(item: item, asset: asset, targetFPS: targetFPS)
            if playlistPlaybackEnabled {
                player.insert(item, after: nil)
                playerLoopers[index] = nil
            } else {
                playerLoopers[index] = AVPlayerLooper(player: player, templateItem: item)
            }
        }
        applyAudioSettings()
        applySuspensionStateToPlayers()
        evaluateForegroundCoverageState()
        schedulePlaybackStartupValidation(
            url: url,
            usedFrameRateComposition: !bypassFrameRateComposition && targetFPS != nil
        )
    }

    private func cacheDirectoryURL() -> URL? {
        guard
            let appSupportURL: URL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            return nil
        }

        return
            appSupportURL
                .appendingPathComponent("LiveWallpaper", isDirectory: true)
                .appendingPathComponent("Videos", isDirectory: true)
    }

    private func thumbnailCacheDirectoryURL() -> URL? {
        guard
            let appSupportURL: URL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            return nil
        }

        return
            appSupportURL
                .appendingPathComponent("LiveWallpaper", isDirectory: true)
                .appendingPathComponent("ThumbnailCache", isDirectory: true)
    }

    private func importVideoToAppSupport(from sourceURL: URL) -> URL? {
        let fileManager = FileManager.default
        guard let targetDirectory: URL = cacheDirectoryURL() else {
            return nil
        }

        do {
            try fileManager.createDirectory(
                at: targetDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }

        let ext: String = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
        let targetURL: URL = targetDirectory.appendingPathComponent(
            "wallpaper-\(UUID().uuidString).\(ext)"
        )

        do {
            try fileManager.copyItem(at: sourceURL, to: targetURL)
            return targetURL
        } catch {
            return nil
        }
    }

    private func restoreState() {
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
                    WallpaperPlaylist(id: UUID(), name: "プレイリスト1", videoPaths: cleaned)
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
           let playlistContainingPath = playlists
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

    private func addVideoPathToSelectedPlaylist(
        _ path: String,
        preferredDisplayName: String? = nil
    ) {
        guard !path.isEmpty else {
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return
        }

        if playlists.isEmpty {
            playlists = [WallpaperPlaylist(id: UUID(), name: "プレイリスト1", videoPaths: [])]
            selectedPlaylistID = playlists.first?.id
        }
        ensureSelectedPlaylist()
        guard let index = selectedPlaylistIndex() else {
            return
        }

        if !playlists[index].videoPaths.contains(path) {
            playlists[index].videoPaths.append(path)
        }

        if let preferredDisplayName,
           !preferredDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           registeredVideoDisplayNames[path] == nil
        {
            registeredVideoDisplayNames[path] = preferredDisplayName
            UserDefaults.standard.set(
                registeredVideoDisplayNames,
                forKey: "registeredVideoDisplayNames"
            )
        }

        syncActivePlaylistPaths()
        persistPlaylistState()
    }

    private func selectedPlaylistIndex() -> Int? {
        guard let selectedPlaylistID else {
            return nil
        }
        return playlists.firstIndex(where: { $0.id == selectedPlaylistID })
    }

    private func ensureSelectedPlaylist() {
        if let selectedPlaylistID,
           playlists.contains(where: { $0.id == selectedPlaylistID })
        {
            return
        }
        selectedPlaylistID = playlists.first?.id
    }

    private func syncActivePlaylistPaths() {
        ensureSelectedPlaylist()
        if let index = selectedPlaylistIndex() {
            registeredVideoPaths = playlists[index].videoPaths
        } else {
            registeredVideoPaths = []
        }
        pruneWallpaperPresentationsForExistingPaths()
    }

    private func pruneDisplayNamesForExistingPaths() {
        let validPaths = Set(playlists.flatMap(\.videoPaths))
        registeredVideoDisplayNames = registeredVideoDisplayNames
            .filter { validPaths.contains($0.key) }
        UserDefaults.standard.set(
            registeredVideoDisplayNames,
            forKey: "registeredVideoDisplayNames"
        )
    }

    private func pruneWallpaperPresentationsForExistingPaths() {
        let validPaths = Set(playlists.flatMap(\.videoPaths))
        let pruned = wallpaperPresentationByPath.filter { validPaths.contains($0.key) }
        if pruned != wallpaperPresentationByPath {
            wallpaperPresentationByPath = pruned
            persistWallpaperPresentationState()
        }
    }

    private func persistWallpaperPresentationState() {
        if let data = try? JSONEncoder().encode(wallpaperPresentationByPath) {
            UserDefaults.standard.set(data, forKey: wallpaperPresentationStorageKey)
        }
    }

    private func persistPlaylistState() {
        if let data = try? JSONEncoder().encode(playlists) {
            UserDefaults.standard.set(data, forKey: "playlistsData")
        }
        UserDefaults.standard.set(registeredVideoPaths, forKey: "registeredVideoPaths")
        UserDefaults.standard.set(selectedPlaylistID?.uuidString, forKey: "selectedPlaylistID")
        persistWallpaperPresentationState()
    }

    private func configureForegroundCoverageMonitoring() {
        if let observer = frontmostAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            frontmostAppObserver = nil
        }
        if let observer = activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activeSpaceObserver = nil
        }

        guard suspendWhenOtherAppFullScreen else {
            coverageEvaluationWorkItem?.cancel()
            removeAXObserver()
            applyCoveringAppSuspension(false)
            return
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        frontmostAppObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateAXObserverForFrontmostApplication()
                self?.scheduleForegroundCoverageEvaluation()
            }
        }

        activeSpaceObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleForegroundCoverageEvaluation()
            }
        }

        updateAXObserverForFrontmostApplication()
    }

    private func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    private func updateAXObserverForFrontmostApplication() {
        guard suspendWhenOtherAppFullScreen, isAccessibilityTrusted() else {
            removeAXObserver()
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            removeAXObserver()
            return
        }

        let pid = app.processIdentifier
        if observedAppPID == pid, axObserver != nil {
            return
        }

        removeAXObserver()

        let appElement = AXUIElementCreateApplication(pid)
        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else {
                return
            }
            let model = Unmanaged<WallpaperModel>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in
                model.scheduleForegroundCoverageEvaluation()
            }
        }

        let result = AXObserverCreate(pid, callback, &newObserver)
        guard result == .success, let observer = newObserver else {
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        _ = AXObserverAddNotification(
            observer,
            appElement,
            kAXFocusedWindowChangedNotification as CFString,
            refcon
        )
        _ = AXObserverAddNotification(
            observer,
            appElement,
            kAXWindowMovedNotification as CFString,
            refcon
        )
        _ = AXObserverAddNotification(
            observer,
            appElement,
            kAXWindowResizedNotification as CFString,
            refcon
        )
        _ = AXObserverAddNotification(
            observer,
            appElement,
            kAXMainWindowChangedNotification as CFString,
            refcon
        )

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )

        axObserver = observer
        observedAppElement = appElement
        observedAppPID = pid
    }

    private func removeAXObserver() {
        guard let observer = axObserver else {
            observedAppElement = nil
            observedAppPID = nil
            return
        }

        if let appElement = observedAppElement {
            _ = AXObserverRemoveNotification(
                observer,
                appElement,
                kAXFocusedWindowChangedNotification as CFString
            )
            _ = AXObserverRemoveNotification(
                observer,
                appElement,
                kAXWindowMovedNotification as CFString
            )
            _ = AXObserverRemoveNotification(
                observer,
                appElement,
                kAXWindowResizedNotification as CFString
            )
            _ = AXObserverRemoveNotification(
                observer,
                appElement,
                kAXMainWindowChangedNotification as CFString
            )
        }

        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )

        axObserver = nil
        observedAppElement = nil
        observedAppPID = nil
    }

    private func scheduleForegroundCoverageEvaluation() {
        guard suspendWhenOtherAppFullScreen else {
            evaluateForegroundCoverageState()
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastCoverageEvaluationAt
        if elapsed >= 0.2 {
            lastCoverageEvaluationAt = now
            evaluateForegroundCoverageState()
            return
        }

        coverageEvaluationWorkItem?.cancel()
        let delay = max(0.2 - elapsed, 0.05)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            lastCoverageEvaluationAt = CFAbsoluteTimeGetCurrent()
            evaluateForegroundCoverageState()
        }
        coverageEvaluationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func evaluateForegroundCoverageState() {
        guard suspendWhenOtherAppFullScreen else {
            applyCoveringAppSuspension(false)
            return
        }
        guard currentVideoPath != nil else {
            applyCoveringAppSuspension(false)
            return
        }
        updateAXObserverForFrontmostApplication()
        let coveredDisplayIDs = coveredDisplayIDsByFrontmostApp()
        applyCoveringAppSuspension(coveredDisplayIDs)
    }

    private func applyCoveringAppSuspension(_ shouldSuspend: Bool) {
        if shouldSuspend {
            applyCoveringAppSuspension(Set(targetScreens().map { displayIDString(for: $0) }))
        } else {
            applyCoveringAppSuspension([])
        }
    }

    private func applyCoveringAppSuspension(_ displayIDs: Set<String>) {
        let targetIDs: Set<String>
        targetIDs = displayIDs
        guard suspendedDisplayIDs != targetIDs else {
            return
        }
        suspendedDisplayIDs = targetIDs
        applySuspensionStateToPlayers()
    }

    private func startAutoFrameRateMonitoring() {
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
                if let currentPath = currentVideoPath {
                    playVideo(url: URL(fileURLWithPath: currentPath))
                }
            }
            return
        }

        guard autoFrameRateEnabled else {
            if autoFrameRateBitRateFactor != 1.0 || autoFrameRateBufferAdjustment != 0 {
                autoFrameRateBitRateFactor = 1.0
                autoFrameRateBufferAdjustment = 0
                if let currentPath = currentVideoPath {
                    playVideo(url: URL(fileURLWithPath: currentPath))
                }
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
        if let currentPath = currentVideoPath {
            playVideo(url: URL(fileURLWithPath: currentPath))
        }
    }

    private func coveredDisplayIDsByFrontmostApp() -> Set<String> {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return []
        }

        if let bundleID = frontmostApp.bundleIdentifier,
           suspendExclusionBundleIDs.contains(normalizeBundleID(bundleID))
        {
            return []
        }

        if frontmostApp.bundleIdentifier == "com.apple.finder" {
            return []
        }

        let frontmostPID = frontmostApp.processIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard frontmostPID != ownPID else {
            return []
        }

        guard
            let windowInfo = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return []
        }

        let screenInfos = targetScreens().map { screen in
            (
                id: displayIDString(for: screen),
                frame: screen.frame,
                area: max(screen.frame.width * screen.frame.height, 1)
            )
        }
        guard !screenInfos.isEmpty else {
            return []
        }

        var covered: Set<String> = []

        for info in windowInfo {
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            guard ownerPID == frontmostPID else {
                continue
            }

            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            if alpha <= 0.01 {
                continue
            }

            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            if layer < 0 {
                continue
            }

            guard
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else {
                continue
            }

            guard bounds.width >= 120, bounds.height >= 120 else {
                continue
            }

            for screen in screenInfos {
                let intersection = bounds.intersection(screen.frame)
                guard !intersection.isNull, !intersection.isEmpty else {
                    continue
                }
                let intersectionArea = intersection.width * intersection.height
                let coveredRatio = intersectionArea / screen.area
                if coveredRatio >= 0.9 {
                    covered.insert(screen.id)
                }
            }
        }

        return covered
    }

    private func normalizeBundleID(_ bundleID: String) -> String {
        bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func currentAppVersion() -> String {
        if let version: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        )
            as? String,
            !version.isEmpty
        {
            return version
        }
        return AppConfig.defaultVersion
    }
}

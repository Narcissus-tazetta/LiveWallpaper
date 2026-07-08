import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Darwin

@MainActor
final class WallpaperModel: ObservableObject {
    private let maxPlaylistCount: Int = 10
    let wallpaperPresentationStorageKey: String = "wallpaperPresentationByPath"

    struct ScreenSignature: Equatable {
        let displayID: UInt32
        let frame: CGRect
    }

    struct PresentationCacheKey: Equatable {
        let screenID: String
        let boundsWidth: Double
        let boundsHeight: Double
        let fitMode: VideoFitMode
        let zoom: Double
        let offsetX: Double
        let offsetY: Double
        let videoAspectRatio: Double
    }

    enum ChipClass {
        case appleSilicon
        case intel
    }

    struct PlaybackEnvironment {
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

    var windows: [NSWindow] = []
    var playerViews: [PlayerView] = []
    var webPlayerViews: [WebPlayerView] = []
    var sharedPlayer: AVQueuePlayer?
    var sharedLooper: AVPlayerLooper?
    var pendingPlaybackReconfiguration: Bool = false
    var screenChangeObserver: NSObjectProtocol?
    var finderLaunchObserver: NSObjectProtocol?
    var screenChangeWorkItem: DispatchWorkItem?
    var windowRebuildWorkItem: DispatchWorkItem?
    var windowOptionsWorkItem: DispatchWorkItem?
    var windowRetireWorkItem: DispatchWorkItem?
    var retiredWindows: [NSWindow] = []
    var displayIDByWindow: [ObjectIdentifier: String] = [:]
    var activeSpaceWindowRefreshWorkItems: [DispatchWorkItem] = []
    var lastScreenSignatures: [ScreenSignature] = []
    var cachedDisplayScreens: [DisplayScreenInfo]?
    var frontmostAppObserver: NSObjectProtocol?
    var windowOcclusionObserver: NSObjectProtocol?
    var spaceTransitionGuardObserver: NSObjectProtocol?
    var playerItemEndObserver: NSObjectProtocol?
    var suspendedDisplayIDs: Set<String> = []
    var lastCapturedFreezeFrameVideoPath: String?
    var lastCapturedFreezeFrameTime: CMTime?
    var lastCapturedFreezeFrameImage: CGImage?
    var deepSuspendWorkItem: DispatchWorkItem?
    var isDeepSuspended: Bool = false
    var isDeepResuming: Bool = false
    let deepSuspendDelay: TimeInterval = 10
    var autoFrameRateTimer: Timer?
    var autoFrameRateBitRateFactor: Double = 1.0
    var autoFrameRateBufferAdjustment: TimeInterval = 0
    var coverageEvaluationWorkItem: DispatchWorkItem?
    var pendingSuspendConfirmationWorkItem: DispatchWorkItem?
    var isActiveSpaceTransitioning: Bool = false
    var activeSpaceTransitionLockWorkItem: DispatchWorkItem?
    var statePersistWorkItem: DispatchWorkItem?
    var lockScreenUnlockResetWorkItem: DispatchWorkItem?
    var persistenceFailureCount: Int = 0
    let playbackEnvironment: PlaybackEnvironment
    let lockScreenSyncService: LockScreenSyncService = .init()
    let desktopIconsService: DesktopIconsService = .init()
    let lightweightProxyCache: LightweightProxyCache = .init()
    var lockScreenSyncTask: Task<Void, Never>?
    var videoAspectRatioByPath: [String: Double] = [:]
    var loadingVideoAspectRatioPaths: Set<String> = []
    var presentationCacheByPlayerView: [ObjectIdentifier: PresentationCacheKey] = [:]

    @Published var clickThrough: Bool = true
    @Published var displayMode: DisplayMode = .mainOnly
    @Published var fitMode: VideoFitMode = .fill
    @Published var lightweightMode: Bool = false
    @Published var lightweightProxyState: LightweightProxyCache.ProxyGenerationState = .idle
    @Published var audioEnabled: Bool = false
    @Published var audioVolume: Float = 1.0
    @Published var frameRateLimit: FrameRateLimit = .off
    @Published var decodeMode: DecodeMode = .automatic
    @Published var qualityPreset: QualityPreset = .auto
    @Published var workProfile: WorkProfile = .normal
    @Published var autoFrameRateEnabled: Bool = true
    @Published var batteryAwareQualityEnabled: Bool = true
    @Published var playlistPlaybackEnabled: Bool = false
    @Published var shufflePlaybackEnabled: Bool = false
    @Published var videoLoopEnabled: Bool = true
    @Published var pinCurrentVideo: Bool = false
    @Published var currentVideoIndex: Int?
    @Published var desktopLevelOffset: DesktopLevelOffset = .zero
    @Published var desktopIconsVisible: Bool = true
    @Published var useFullScreenAuxiliary: Bool = false
    @Published var menuBarOpaqueEnabled: Bool = false
    @Published var menuBarAutoHideDetected: Bool = false
    @Published var suspendWhenOtherAppFullScreen: Bool = false
    @Published var suspendHighSensitivityEnabled: Bool = false
    @Published var suspendWhenOtherAppFrontmost: Bool = false
    @Published var screenRecordingTrustedForCoverage: Bool = false
    @Published var suspendExclusionBundleIDs: [String] = []
    @Published var persistenceFailureMessage: String?
    @Published var desktopIconsFailureMessage: String?

    @Published var wallpaperKind: WallpaperKind = .video
    @Published var webWallpaperSources: [WebWallpaperSource] = []
    @Published var currentWebWallpaperID: UUID?
    @Published var webWallpaperLoadState: WebWallpaperLoadState = .idle
    @Published var webWallpaperErrorMessage: String?
    @Published var playlists: [WallpaperPlaylist] = []
    @Published var selectedPlaylistID: UUID?
    @Published var currentVideoPath: String?
    @Published var lockScreenVideoPath: String?
    @Published var registeredVideoPaths: [String] = []
    @Published var registeredVideoDisplayNames: [String: String] = [:]
    @Published var launchAtLoginEnabled: Bool = false
    @Published var appLanguage: AppLanguage = .automatic
    @Published var advancedSharingEnabled: Bool = false
    @Published var lockScreenSyncEnabled: Bool = false
    @Published var lockScreenSyncStatus: LockScreenSyncStatus = .disabled
    @Published var wallpaperPresentationByPath:
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
            return localizedString("プレイリスト")
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

    var appLocale: Locale {
        Locale(identifier: appLanguage.effectiveLanguageCode)
    }

    var effectiveAppLanguageCode: String {
        appLanguage.effectiveLanguageCode
    }

    func localizedString(_ key: String) -> String {
        AppLocalization.localizedString(key, languageCode: effectiveAppLanguageCode)
    }

    func setAppLanguage(_ language: AppLanguage) {
        guard appLanguage != language else {
            return
        }
        appLanguage = language
        cachedDisplayScreens = nil
        UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
        LocalizationManager.setLanguage(language.effectiveLanguageCode)
        NSLog(
            "[Localization] setAppLanguage -> \(language) effective=\(language.effectiveLanguageCode)"
        )
    }

    init() {
        playbackEnvironment = Self.detectPlaybackEnvironment()
        configurePlayer()
        restoreState()
        recoverStaleLockScreenSyncOnLaunchIfNeeded()
        LocalizationManager.setLanguage(effectiveAppLanguageCode)
        rebuildWindows()
        if isWebWallpaperActive {
            webWallpaperLoadState = .loading
        } else if let savedPath: String = currentVideoPath {
            playRegisteredVideo(path: savedPath)
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
        configureWallpaperWindowRefreshMonitoring()
        configureForegroundCoverageMonitoring()
        startAutoFrameRateMonitoring()
    }

    deinit {
        screenChangeWorkItem?.cancel()
        windowRebuildWorkItem?.cancel()
        windowOptionsWorkItem?.cancel()
        windowRetireWorkItem?.cancel()
        activeSpaceWindowRefreshWorkItems.forEach { $0.cancel() }
        activeSpaceWindowRefreshWorkItems.removeAll()
        coverageEvaluationWorkItem?.cancel()
        statePersistWorkItem?.cancel()
        lockScreenUnlockResetWorkItem?.cancel()
        lockScreenSyncTask?.cancel()
        retiredWindows.removeAll()
        if let observer: any NSObjectProtocol = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = finderLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = spaceTransitionGuardObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        activeSpaceTransitionLockWorkItem?.cancel()
        if let observer = frontmostAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = windowOcclusionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer: any NSObjectProtocol = playerItemEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        autoFrameRateTimer?.invalidate()
        autoFrameRateTimer = nil
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

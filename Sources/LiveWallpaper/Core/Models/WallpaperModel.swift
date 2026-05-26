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
    var sharedPlayer: AVQueuePlayer?
    var sharedLooper: AVPlayerLooper?
    var pendingPlaybackReconfiguration: Bool = false
    var screenChangeObserver: NSObjectProtocol?
    var screenChangeWorkItem: DispatchWorkItem?
    var windowRebuildWorkItem: DispatchWorkItem?
    var windowOptionsWorkItem: DispatchWorkItem?
    var windowRetireWorkItem: DispatchWorkItem?
    var retiredWindows: [NSWindow] = []
    var lastScreenSignatures: [ScreenSignature] = []
    var frontmostAppObserver: NSObjectProtocol?
    var activeSpaceObserver: NSObjectProtocol?
    var playerItemEndObserver: NSObjectProtocol?
    var axObserver: AXObserver?
    var observedAppElement: AXUIElement?
    var observedAppPID: pid_t?
    var suspendedDisplayIDs: Set<String> = []
    var autoFrameRateTimer: Timer?
    var autoFrameRateBitRateFactor: Double = 1.0
    var autoFrameRateBufferAdjustment: TimeInterval = 0
    var coverageEvaluationWorkItem: DispatchWorkItem?
    var coverageEvaluationGeneration: UInt64 = 0
    var playbackStartupValidationWorkItem: DispatchWorkItem?
    var lastPlaybackFallbackPath: String?
    var lastCoverageEvaluationAt: CFAbsoluteTime = 0
    let playbackEnvironment: PlaybackEnvironment
    var videoAspectRatioByPath: [String: Double] = [:]
    var loadingVideoAspectRatioPaths: Set<String> = []
    var presentationCacheByPlayerView: [ObjectIdentifier: PresentationCacheKey] = [:]

    @Published var clickThrough: Bool = true
    @Published var displayMode: DisplayMode = .mainOnly
    @Published var fitMode: VideoFitMode = .fill
    @Published var lightweightMode: Bool = false
    @Published var audioEnabled: Bool = false
    @Published var audioVolume: Float = 1.0
    @Published var frameRateLimit: FrameRateLimit = .off
    @Published var decodeMode: DecodeMode = .automatic
    @Published var qualityPreset: QualityPreset = .auto
    @Published var workProfile: WorkProfile = .normal
    @Published var autoFrameRateEnabled: Bool = true
    @Published var playlistPlaybackEnabled: Bool = false
    @Published var shufflePlaybackEnabled: Bool = false
    @Published var currentVideoIndex: Int?
    @Published var desktopLevelOffset: DesktopLevelOffset = .zero
    @Published var useFullScreenAuxiliary: Bool = false
    @Published var suspendWhenOtherAppFullScreen: Bool = false
    @Published var suspendExclusionBundleIDs: [String] = []
    @Published var suspendWhenOtherAppStatusMessage: String?

    @Published var playlists: [WallpaperPlaylist] = []
    @Published var selectedPlaylistID: UUID?
    @Published var currentVideoPath: String?
    @Published var registeredVideoPaths: [String] = []
    @Published var registeredVideoDisplayNames: [String: String] = [:]
    @Published var appLanguage: AppLanguage = .automatic
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
        LocalizationManager.setLanguage(effectiveAppLanguageCode)
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

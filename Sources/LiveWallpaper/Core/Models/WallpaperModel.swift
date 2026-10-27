import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Darwin

@MainActor
final class WallpaperModel: ObservableObject {
    private let maxPlaylistCount: Int = 10
    let wallpaperPresentationStorageKey: String = "wallpaperPresentationByPath"
    let wallpaperEditStorageKey: String = "wallpaperEditByPath"

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
    var sharedPlayerAudioController: PlayerAudioTrackController?
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
    /// 接続中の画面一覧。設定UIはこの一覧から「今スコープに選べる画面」を導出する
    /// ため、遅延キャッシュではなく発行される事実として持つ。非Publishedのキャッシュ
    /// だと画面を外しても SwiftUI が再描画されず、消えた画面が選ばれたまま残る。
    /// 更新は refreshDisplayScreens() 経由のみ(直接代入しないこと)。
    @Published var displayScreens: [DisplayScreenInfo] = []
    var frontmostAppObserver: NSObjectProtocol?
    var windowOcclusionObserver: NSObjectProtocol?
    var spaceTransitionGuardObserver: NSObjectProtocol?
    var playerItemEndObserver: NSObjectProtocol?
    var reduceMotionObserver: NSObjectProtocol?
    let sceneSoundPlayer = SceneSoundPlayer()
    var sceneSoundBlockers: Set<SceneSoundBlocker> = []
    var sceneSoundObservers: [NSObjectProtocol] = []
    var sceneSoundCancellable: AnyCancellable?
    var sceneSoundLiveCancellable: AnyCancellable?
    var suspendedDisplayIDs: Set<String> = []
    /// Screens auto-paused because windows cover them, without the forced freezes
    /// (pause, battery, Reduce Motion) that suspendedDisplayIDs also contains.
    var coveredDisplayIDs: Set<String> = []
    var lastCapturedFreezeFrameVideoPath: String?
    var lastCapturedFreezeFrameTime: CMTime?
    var lastCapturedFreezeFrameImage: CGImage?
    var deepSuspendWorkItem: DispatchWorkItem?
    var isDeepSuspended: Bool = false
    var isDeepResuming: Bool = false
    let deepSuspendDelay: TimeInterval = 10
    var webDeepSuspendWorkItem: DispatchWorkItem?
    /// Web壁紙のページ解放までの猶予。動画(deepSuspendDelay)より長いのは、
    /// 復帰にネットワーク往復とJSの起動が要るぶん、短い被覆で解放すると
    /// 戻したときの待ちが目立つため。
    let webDeepSuspendDelay: TimeInterval = 60
    var autoFrameRateTimer: Timer?
    var autoSwitchTimer: Timer?
    var autoFrameRateThermalObserver: NSObjectProtocol?
    var autoFrameRatePowerStateObserver: NSObjectProtocol?
    var autoFrameRateBitRateFactor: Double = 1.0
    var autoFrameRateBufferAdjustment: TimeInterval = 0
    var coverageEvaluationWorkItem: DispatchWorkItem?
    var pendingSuspendConfirmationWorkItem: DispatchWorkItem?
    var isActiveSpaceTransitioning: Bool = false
    /// Windows whose first orderFront was skipped by the space-transition lock. A window created
    /// during the lock (e.g. a display plugged in) is otherwise never ordered in: later rebuilds
    /// reuse it and only newly created windows are ordered.
    var windowsAwaitingOrdering: Set<ObjectIdentifier> = []
    var activeSpaceTransitionLockWorkItem: DispatchWorkItem?
    var statePersistWorkItem: DispatchWorkItem?
    var persistenceFailureCount: Int = 0
    let playbackEnvironment: PlaybackEnvironment
    let lockScreenSyncService: LockScreenSyncService = .init()
    let desktopIconsService: DesktopIconsService = .init()
    let lightweightProxyCache: LightweightProxyCache
    var lockScreenSyncTask: Task<Void, Never>?
    /// Identifies the running sync, so progress from a replaced one is ignored.
    var lockScreenSyncID = UUID()
    // フィット編集のプレビューが非同期ロード完了後に再描画されるよう @Published にしている。
    // (16:9 フォールバックで描画された後、実際のアスペクト比で描き直すため)
    @Published var videoAspectRatioByPath: [String: Double] = [:]
    @Published var videoNaturalSizeByPath: [String: CGSize] = [:]
    var loadingVideoAspectRatioPaths: Set<String> = []
    var presentationCacheByPlayerView: [ObjectIdentifier: PresentationCacheKey] = [:]

    @Published var clickThrough: Bool = true
    /// Forwards desktop clicks on a web wallpaper's buttons into the page while click-through is on.
    @Published var webInteractionEnabled: Bool = false
    var webInteractionMonitor: Any?
    var webInteractionObserver: NSObjectProtocol?
    /// The page that got the last press, so the drag and release go to it too.
    var webInteractionPressTarget: WebPlayerView?
    var webInteractionWheelProbe: (location: CGPoint, time: TimeInterval, accepted: Bool)?
    @Published var displayMode: DisplayMode = .mainOnly
    @Published var fitMode: VideoFitMode = .fill
    @Published var lightweightMode: Bool = false
    @Published var hdrDisplayEnabled: Bool = true
    var lightweightProxyStatesByPath: [String: LightweightProxyCache.ProxyGenerationState] = [:]
    var lightweightProxyRequests: [String: UUID] = [:]
    @Published var lightweightProxyState: LightweightProxyCache.ProxyGenerationState = .idle
    @Published var audioEnabled: Bool = false
    @Published var audioVolume: Float = 1.0
    /// 壁紙を暗くしてデスクトップアイコン・ファイル名を読みやすくする度合い(0...1)。0はオフ。
    @Published var desktopReadabilityDimOpacity: Double = 0
    @Published var cursorEffects = CursorEffectsSettings()
    /// Video path → cursor effects used instead of `cursorEffects` for that wallpaper.
    @Published var cursorEffectsByPath: [String: CursorEffectsSettings] = [:]
    var cursorTracker: CursorTracker?
    var cursorEffectsObservers: [NSObjectProtocol] = []
    var clickMonitor: Any?
    var scenePressMonitor: Any?
    /// The last press went to a scene, so its release goes there too.
    var scenePressIsDown = false
    var cursorEffectsCancellable: AnyCancellable?
    /// Finder (the desktop) or this app is frontmost; see onlyWhileDesktopActive.
    @Published var isDesktopAppFrontmost: Bool = true
    @Published var isLowPowerModeOn: Bool = false
    @Published var isThermallyConstrained: Bool = false
    var trailIdleWorkItem: DispatchWorkItem?
    /// Video path → the scene it was baked from (SceneStore). Paths without a scene
    /// are plain videos.
    @Published var sceneDocumentsByPath: [String: SceneDocument] = [:]
    /// Scenes whose baked video is being rewritten.
    @Published var scenesBaking: Set<String> = []
    /// 0...1 while an animated scene's loop is being written. Held in its own object: it changes
    /// about once a second for minutes, and publishing it here would redraw the whole settings window.
    let sceneBakeProgressStore = SceneBakeProgress()
    var sceneBakeProgress: [String: Double] {
        get { sceneBakeProgressStore.values }
        set { sceneBakeProgressStore.values = newValue }
    }
    /// Scenes whose baked video does not show the latest edit yet (pending or failed).
    var sceneStaleVideoPaths: Set<String> = []
    @Published var sceneErrorMessage: String?
    @Published var sceneScriptIssues: [String: [SceneScriptIssue]] = [:]
    /// Downloaded scenes whose JavaScript waits for the user's yes; asked one at a time.
    @Published var sceneScriptApprovalRequests: [SceneScriptApprovalRequest] = []
    @Published var sceneScriptLogs: [String: [UUID: String]] = [:]
    var sceneScriptLogTimes: [String: TimeInterval] = [:]
    /// Video path → undo history of its scene, kept per wallpaper until the app quits.
    /// Not published: every change to it comes with a change to sceneDocumentsByPath.
    var sceneHistories: [String: EditHistory<SceneDocument>] = [:]
    /// Video path → undo history of its own cursor effects (nil: follows the app-wide
    /// ones), kept until the app quits. Every change comes with one to cursorEffectsByPath.
    var cursorEffectsHistories: [String: EditHistory<CursorEffectsSettings?>] = [:]
    /// Full path → number of running tasks reading that scene file, which pruning keeps.
    var sceneFilesInUse: [String: Int] = [:]
    /// Video path → image layer additions still being read in.
    @Published var sceneLayerImportCounts: [String: Int] = [:]
    /// Leaves the lock screen video and the screen saver in place when the app quits.
    @Published var keepLockScreenAndScreenSaverAfterQuit = false
    /// Layer id → the on-device analysis running on it.
    @Published var sceneAIWork: [UUID: SceneAIWork] = [:]
    var sceneBakeWorkItems: [String: DispatchWorkItem] = [:]
    var sceneBakeTasks: [String: Task<Void, Never>] = [:]
    var sceneBakeGenerations: [String: UUID] = [:]
    /// Scenes whose bake is writing now, as opposed to waiting for edits to settle.
    @Published var scenesBakeRunning: Set<String> = []
    /// Scenes edited since their video was baked, whose bake waits until their
    /// scripts are allowed or stopped.
    @Published var sceneVideosAwaitingScriptApproval: Set<String> = []
    /// Video path → why its last bake failed; the previous video stays in use.
    @Published var sceneBakeFailures: [String: String] = [:]
    /// Scenes with edits not yet written to scene.json.
    @Published var scenesSaving: Set<String> = []
    /// Video path → why scene.json could not be written; the edit stays in memory.
    @Published var sceneSaveFailures: [String: String] = [:]
    var sceneSaveWorkItems: [String: DispatchWorkItem] = [:]
    var sceneSaveGenerations: [String: UUID] = [:]
    /// Video path → states kept for comparison in the editor; pruning keeps their files.
    @Published var sceneComparisonSnapshots: [String: SceneDocument] = [:]
    /// nil until the editor first needs them.
    @Published var userScenePresets: [ScenePreset]?
    /// Where the user's presets live; tests point it elsewhere.
    var scenePresetStore = ScenePresetStore.standard
    /// A preset shown on the preview before it is applied.
    @Published var scenePresetTrial: ScenePresetTrial?
    /// Video path → what is left to do after the last preset applied there.
    @Published var scenePresetGuides: [String: ScenePresetGuide] = [:]
    /// Video path → the part of the day its baked video shows.
    var sceneBakedTimesOfDay: [String: SceneTimeOfDay] = [:]
    var sceneTimeOfDayTimer: Timer?
    /// Video path → the part of the day a running bake writes.
    var sceneBakingTimesOfDay: [String: SceneTimeOfDay] = [:]
    var sceneTimeOfDayObservers: [NSObjectProtocol] = []
    @Published var frameRateLimit: FrameRateLimit = .off
    @Published var decodeMode: DecodeMode = .automatic
    @Published var qualityPreset: QualityPreset = .auto
    @Published var workProfile: WorkProfile = .normal
    @Published var autoFrameRateEnabled: Bool = true
    @Published var batteryAwareQualityEnabled: Bool = true
    @Published var playlistPlaybackEnabled: Bool = false
    @Published var shufflePlaybackEnabled: Bool = false
    @Published var videoLoopEnabled: Bool = true
    /// 自動切替の間隔(分)。0 はオフ。
    @Published var autoSwitchIntervalMinutes: Int = 0
    @Published var pinCurrentVideo: Bool = false
    @Published var currentVideoIndex: Int?
    @Published var desktopLevelOffset: DesktopLevelOffset = .zero
    @Published var desktopIconsVisible: Bool = true
    /// システムの「視差効果を減らす(Reduce Motion)」がONのとき、壁紙を静止
    /// フレームに固定する(既定ON)。アクセシビリティ設定を尊重するための項目。
    @Published var respectReduceMotionEnabled: Bool = true
    /// システムの現在の Reduce Motion 状態(NSWorkspaceから取得・監視)。
    @Published var systemReduceMotionEnabled: Bool = false
    /// User pause; not persisted (WallpaperModel+ManualPause.swift).
    @Published var manualPauseActive: Bool = false
    /// Battery playback policy (WallpaperModel+PowerPolicy.swift).
    @Published var batteryPlaybackPolicy: BatteryPlaybackPolicy = .normal
    /// Updated from IOKit power-source notifications.
    @Published var isOnBatteryPower: Bool = false
    var powerSourceRunLoopSource: CFRunLoopSource?
    /// Wallpaper switch effect length in seconds; 0 turns it off (WallpaperModel+Transition.swift).
    @Published var wallpaperTransitionDuration: Double = 0.5
    @Published var wallpaperTransitionStyle: WallpaperTransitionStyle = .crossfade
    var wallpaperTransitionSuppressionDepth: Int = 0
    var wallpaperTransitionNestingDepth: Int = 0
    var transitionHeldPlayers: [ObjectIdentifier: TransitionHeldPlayer] = [:]
    var transitionAudioRampTimer: Timer?
    /// Screen saver bundle install state and config sync (WallpaperModel+ScreenSaver.swift).
    @Published var screenSaverInstallState: ScreenSaverInstallState = .unavailable
    @Published var screenSaverErrorMessage: String?
    /// The video the screen saver plays on every display; nil plays what the desktop shows.
    @Published var screenSaverVideoPath: String? {
        didSet { if screenSaverVideoPath != oldValue { bakeSceneVideoIfOutOfDate(path: screenSaverVideoPath) } }
    }
    let screenSaverInstaller = ScreenSaverInstaller()
    var lastWrittenScreenSaverConfig: ScreenSaverConfig?
    var screenSaverSyncCancellable: AnyCancellable?
    /// グローバルホットキー機能のマスタースイッチ(既定OFF・オプトイン)。
    @Published var hotKeysEnabled: Bool = false
    /// 操作ごとのキー割り当て。未登録の操作は既定の組み合わせを使う。
    @Published var hotKeyCombos: [HotKeyAction: HotKeyCombo] = [:]
    /// Carbon への登録に失敗した操作(他アプリ/システムが同じ組み合わせを
    /// 既に使用している等)。AppDelegate.reloadGlobalHotKeys が更新する。
    @Published var hotKeyRegistrationFailures: Set<HotKeyAction> = []
    @Published var useFullScreenAuxiliary: Bool = false
    @Published var menuBarOpaqueEnabled: Bool = false
    @Published var menuBarAutoHideDetected: Bool = false
    @Published var suspendWhenOtherAppFullScreen: Bool = false
    @Published var suspendHighSensitivityEnabled: Bool = false
    @Published var suspendWhenOtherAppFrontmost: Bool = false
    /// Whether other apps' window bounds can be read for the high-sensitivity pause.
    @Published var windowBoundsReadableForCoverage: Bool = false
    @Published var suspendExclusionBundleIDs: [String] = []
    @Published var persistenceFailureMessage: String?
    @Published var desktopIconsFailureMessage: String?

    @Published var wallpaperKind: WallpaperKind = .video
    @Published var webWallpaperSources: [WebWallpaperSource] = []
    @Published var webWallpaperFeatureEnabled: Bool = false
    @Published var currentWebWallpaperID: UUID?
    @Published var webWallpaperLoadState: WebWallpaperLoadState = .idle
    @Published var webWallpaperErrorMessage: String?
    let localWebWallpaperServer = LocalWebWallpaperServer(persistPorts: true)
    var localWebLoadTask: Task<Void, Never>?
    /// アニメ画像(GIF等)→動画変換の進行状態。UIの進捗表示・追加ボタン無効化に使う。
    @Published var isImportingMedia: Bool = false
    @Published var mediaImportProgress: Double = 0
    @Published var mediaImportErrorMessage: String?
    /// 変換中のインポートをキャンセルするためのハンドル
    var activeMediaImportTask: Task<Result<URL, Error>, Never>?
    /// 登録済み動画の本体。プレイリストはここへの参照のみを持つ。
    @Published var libraryVideoPaths: [String] = []
    @Published var playlists: [WallpaperPlaylist] = []
    @Published var selectedPlaylistID: UUID?
    @Published var currentVideoPath: String?
    @Published var lockScreenVideoPath: String? {
        didSet { if lockScreenVideoPath != oldValue { bakeSceneVideoIfOutOfDate(path: lockScreenVideoPath) } }
    }
    /// Source seconds each lock screen video begins at; a video without an entry
    /// starts automatically at its first visible frame.
    @Published var lockScreenStartSecondsByVideo: [String: Double] = [:]
    @Published var registeredVideoPaths: [String] = []
    /// 選択中プレイリスト(または未選択時はライブラリ全体)に属するWeb壁紙。
    /// 次へ/前へ送りの対象になる点で registeredVideoPaths のWeb壁紙版。
    @Published var registeredWebWallpaperIDs: [UUID] = []
    @Published var registeredVideoDisplayNames: [String: String] = [:]
    @Published var launchAtLoginEnabled: Bool = false
    /// Sparkle の自動更新設定。実体は AppDelegate が管理し、UI 表示用にここへ同期される。
    @Published var autoUpdateEnabled: Bool = true
    @Published var appLanguage: AppLanguage = .automatic
    @Published var advancedSharingEnabled: Bool = false
    @Published var lockScreenSyncEnabled: Bool = false
    @Published var lockScreenSyncStatus: LockScreenSyncStatus = .disabled
    /// How far the lock screen video's encoding is; nil when nothing is being encoded.
    @Published var lockScreenEncodeProgress: LockScreenEncodeProgress?
    @Published var wallpaperPresentationByPath:
        [String: [String: WallpaperPresentation]] = [:]
    /// 動画パス → トリム/ループ編集。画面ごとではなく動画ファイルごとの性質なのでパスのみでキーする。
    @Published var wallpaperEditByPath: [String: WallpaperEditMetadata] = [:]
    /// 画面ID → その画面に固定表示する動画パス。空ならオーバーライドなし。
    @Published var videoOverrideByScreenID: [String: String] = [:]
    /// 画面ごとに固定した Web 壁紙(WebWallpaperSource.id)。同じ画面の videoOverrideByScreenID とは排他。
    @Published var webOverrideByScreenID: [String: UUID] = [:]
    /// Wallpapers offered by provider apps that are running right now. Never saved.
    @Published var externalWallpapers: [ExternalWallpaper] = []
    /// The external wallpaper shown on every screen in place of the user's own choice.
    /// It changes nothing the app saves, so quitting the provider restores the desktop.
    @Published var activeExternalWallpaperID: String?
    /// External wallpaper ID → the library copy made from it, so adding it again is
    /// refused while that copy is still in the library.
    @Published var importedExternalWallpaperPaths: [String: String] = [:]
    @Published var importingExternalWallpaperID: String?
    @Published var failedExternalWallpaperImportID: String?
    /// External scene ID → the revision baked and ready to show.
    @Published var readyExternalScenes: [String: Date] = [:]
    /// External scene ID → the revision that failed to bake; tried again when the
    /// provider writes a new one.
    @Published var failedExternalScenes: [String: Date] = [:]
    /// External scene ID → the revision being copied and baked.
    var externalScenePreparations: [String: (revision: Date, task: Task<Void, Never>)] = [:]
    /// A scene chosen before its bake finished, shown as soon as it is ready.
    var pendingShowExternalWallpaperID: String?
    /// 自動停止(作業中の停止など)の対象から除外する画面ID。ここに含まれる画面は
    /// 他の画面での作業やウィンドウ被覆に関わらず常に再生を続ける。
    @Published var suspendDisabledDisplayIDs: Set<String> = []
    /// 画面ID → その画面が従うプレイリストID。未設定ならライブラリ全体を対象にする。
    @Published var screenPlaylistByScreenID: [String: UUID] = [:]
    struct DedicatedPlayerSlot {
        let playbackURL: URL
        let player: AVQueuePlayer
        let looper: AVPlayerLooper
        let audioController: PlayerAudioTrackController
    }

    struct ScreenPathKey: Hashable {
        let screenID: String
        let path: String
    }

    /// screenID -> path -> 生きている専用プレイヤー。「現在」1枠 + 隣接の温存
    /// (最大2枠)を同じ辞書で保持する。
    var dedicatedSlotsByScreenID: [String: [String: DedicatedPlayerSlot]] = [:]
    /// screenID -> 現在レイヤーにアタッチされているパス(温存中の隣接スロットとの区別に使う)。
    var activeDedicatedPathByScreenID: [String: String] = [:]
    var dedicatedFreezeFrameByScreenID: [String: (path: String, time: CMTime?, image: CGImage?)] =
        [:]
    /// (screenID, path) -> 直前に破棄したときの再生位置。メモリ上のみで再起動を跨いで
    /// 永続化しない(Space UUIDはOS再起動で作り直され得るため)。
    var dedicatedResumeTimeByKey: [ScreenPathKey: CMTime] = [:]
    /// 挿入順(古い順)。dedicatedResumeTimeByKey の上限刈り込みに使う。
    var dedicatedResumeTimeInsertionOrder: [ScreenPathKey] = []
    /// ディスプレイID -> フルスクリーンを除いた Space uuid の並び(Mission Control順)。
    /// 隣接判定にはディスプレイ単位の順序が必要なため、knownDesktopSpaces
    /// (全ディスプレイをフラット化したUI表示用の一覧)とは別に保持する。
    var orderedSpaceUUIDsByDisplayID: [String: [String]] = [:]
    /// 隣接ウォームキャッシュ再計算のデバウンス用。
    var dedicatedWarmWindowWorkItem: DispatchWorkItem?
    /// 専用プレイヤーの隣接ウォームキャッシュ+再生位置記憶を有効にするか。
    /// OFFなら常にゼロ秒から再生する従来の挙動に戻る。Space別・ディスプレイ別固定の
    /// どちらの専用プレイヤー切替にも効く。
    @Published var dedicatedPlaybackContinuityEnabled: Bool = true

    /// Mission Control の Space 一覧を取得する非公開APIブリッジ。
    /// シンボル解決に失敗した環境では isAvailable = false になり、
    /// Space別壁紙機能全体が自動的に無効化される。
    let spacesBridge = CGSSpacesBridge()
    /// Space(仮想デスクトップ)ごとの壁紙切替を有効にするか。
    @Published var spaceWallpaperFeatureEnabled: Bool = false
    /// Space uuid → その Space で固定表示する動画パス。
    @Published var videoBySpaceUUID: [String: String] = [:]
    /// UI 表示用の通常デスクトップ一覧(フルスクリーンSpace除外、ordinal付き)。
    @Published var knownDesktopSpaces: [SpaceInfo] = []
    /// 画面ID → その画面で現在表示中の Space uuid。フルスクリーンSpace表示中は
    /// 直前の通常デスクトップの値を保持する(壁紙を差し替えないため)。
    @Published var currentSpaceUUIDByDisplayID: [String: String] = [:]
    /// 実行時に非公開APIの取得・パースが連続失敗したときに立てる無効化フラグ。
    @Published var spaceWallpaperRuntimeUnavailable: Bool = false
    /// メニューバーアイコンに現在のデスクトップ番号を表示するか。
    @Published var menuBarSpaceNumberEnabled: Bool = false
    var spacesSnapshotFailureCount: Int = 0
    var workspaceWakeObserver: NSObjectProtocol?

    // MARK: - スケジュール(時間帯/ダークモード連動切替・曜日スケジュール)

    var scheduleEvaluationTimer: Timer?
    /// evaluateSchedule の再入ガード。適用処理が間接的に評価を呼び戻しても多重実行しない。
    var isEvaluatingSchedule: Bool = false
    /// スコープ単位で「今どのルールが適用中か」を追跡する。ルール境界を跨いだ瞬間
    /// だけ書き込みを行うための状態で、セッション固有(ディスプレイ/Space構成に依存)
    /// のため永続化しない(再起動後は空から再評価する)。
    var lastScheduleApplicationState: [ScheduleScope: ScheduleApplicationState] = [:]
    var lastScheduleAppliedTarget: [ScheduleScope: ScheduleTarget] = [:]
    /// テスト用フック。本番では常に Date()/実際の外観を返す。
    var scheduleNowProvider: () -> Date = { Date() }
    var scheduleAppearanceProvider: () -> ScheduleAppearanceCondition = {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    @Published var scheduleRules: [ScheduleRule] = []
    /// Where sunrise/sunset rules are computed for. nil follows the time zone's city.
    @Published var scheduleLocationOverride: SolarLocation?
    /// zone.tab lookup for the current time zone, redone only when the zone changes.
    var timeZoneSolarLocationCache: (identifier: String, location: SolarLocation?)?
    /// 集中モード連携のマスタースイッチ。OFFの間もDB監視は続けるが、評価時に
    /// focusFilter ルールを無視する(WallpaperModel+Schedule.swift参照)。
    @Published var focusFilterIntegrationEnabled: Bool = true
    /// DoNotDisturb DBから読んだこのMacの集中モード一覧(WallpaperModel+FocusModes.swift)。
    @Published var focusModes: [FocusMode] = []
    /// 今有効な集中モードのidentifier。どのモードもオフならnil。
    @Published var activeFocusModeID: String?
    /// フルディスクアクセス未許可でDBを読めない状態(UIが許可導線を出す)。
    @Published var focusModeAccessDenied: Bool = false
    /// モードidentifier → 割り当て壁紙。「変更しない」モードはエントリ自体を持たない。
    @Published var focusModeAssignments: [String: ScheduleTarget] = [:]
    var focusModeMonitor: FocusModeMonitor?
    var externalWallpaperMonitor: ExternalWallpaperProviderMonitor?

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
            return localizedString("すべての壁紙")
        }
        return playlist.name
    }

    var allRegisteredVideoPaths: [String] {
        libraryVideoPaths
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
        UserDefaults.standard.set(language.rawValue, forKey: PrefsKey.appLanguage)
        LocalizationManager.setLanguage(language.effectiveLanguageCode)
        // 画面名(「画面1 (メイン)」)は localizedString で組み立てるため、
        // 言語切替後に作り直す。LocalizationManager 更新後である必要がある。
        refreshDisplayScreens()
        refreshLocalWebEnvironment()
        AppLog.localization.info(
            "setAppLanguage -> \(String(describing: language), privacy: .public) effective=\(language.effectiveLanguageCode, privacy: .public)"
        )
    }

    init(lightweightProxyCache: LightweightProxyCache? = nil) {
        self.lightweightProxyCache = lightweightProxyCache ?? LightweightProxyCache()
        playbackEnvironment = Self.detectPlaybackEnvironment()
        configurePlayer()
        restoreState()
        // Read the power source before the first playback so it can pick the proxy.
        configurePowerSourceMonitoring()
        recoverStaleLockScreenSyncOnLaunchIfNeeded()
        // Sync stays on across launches only when kept after quitting; if the system
        // lost the replacement meanwhile, put it back.
        if lockScreenSyncEnabled, !lockScreenSyncService.hasActiveLease {
            syncCurrentVideoToLockScreen()
        }
        LocalizationManager.setLanguage(effectiveAppLanguageCode)
        refreshDisplayScreens()
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
        configureReduceMotionMonitoring()
        configureSceneSoundMonitoring()
        configureCursorEffectsObservation()
        startAutoFrameRateMonitoring()
        // 復元では実在確認を省いているので、壁紙を出した後で確認して間引く。
        verifyRestoredVideoPaths()
        restartScheduleEvaluationTimer()
        evaluateSchedule(trigger: .launch)
        configureScreenSaverSync()
    }

    deinit {
        localWebLoadTask?.cancel()
        screenChangeWorkItem?.cancel()
        windowRebuildWorkItem?.cancel()
        windowOptionsWorkItem?.cancel()
        windowRetireWorkItem?.cancel()
        activeSpaceWindowRefreshWorkItems.forEach { $0.cancel() }
        activeSpaceWindowRefreshWorkItems.removeAll()
        coverageEvaluationWorkItem?.cancel()
        deepSuspendWorkItem?.cancel()
        webDeepSuspendWorkItem?.cancel()
        statePersistWorkItem?.cancel()
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
        if let observer = workspaceWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        activeSpaceTransitionLockWorkItem?.cancel()
        if let observer = frontmostAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = windowOcclusionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = reduceMotionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        for observer in sceneSoundObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        if let observer: any NSObjectProtocol = playerItemEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        autoFrameRateTimer?.invalidate()
        autoFrameRateTimer = nil
        scheduleEvaluationTimer?.invalidate()
        scheduleEvaluationTimer = nil
        if let observer = autoFrameRateThermalObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = autoFrameRatePowerStateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
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

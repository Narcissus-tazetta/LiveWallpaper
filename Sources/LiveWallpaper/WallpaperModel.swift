import AVFoundation
import AppKit
import ApplicationServices
import Combine

struct WallpaperPlaylist: Codable, Identifiable, Equatable {
  var id: UUID
  var name: String
  var videoPaths: [String]
}

@MainActor
final class WallpaperModel: ObservableObject {
  private let maxPlaylistCount: Int = 10

  private struct ScreenSignature: Equatable {
    let displayID: UInt32
    let frame: CGRect
  }

  private var windows: [NSWindow] = []
  private var playerViews: [PlayerView] = []
  private let queuePlayer: AVQueuePlayer = AVQueuePlayer()
  private var playerLooper: AVPlayerLooper?
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
  private var isSuspendedByCoveringApp: Bool = false

  @Published private(set) var clickThrough: Bool = true
  @Published private(set) var displayMode: DisplayMode = .mainOnly
  @Published private(set) var fitMode: VideoFitMode = .fill
  @Published private(set) var lightweightMode: Bool = false
  @Published private(set) var audioEnabled: Bool = false
  @Published private(set) var audioVolume: Float = 1.0
  @Published private(set) var frameRateLimit: FrameRateLimit = .off
  @Published private(set) var decodeMode: DecodeMode = .automatic
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

  init() {
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
  }

  deinit {
    screenChangeWorkItem?.cancel()
    windowRebuildWorkItem?.cancel()
    windowOptionsWorkItem?.cancel()
    windowRetireWorkItem?.cancel()
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
    MainActor.assumeIsolated {
      removeAXObserver()
    }
  }

  private func configurePlayer() {
    applyAudioSettings()
    queuePlayer.allowsExternalPlayback = false
    queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
    queuePlayer.actionAtItemEnd = .none
    applyLightweightSettings()
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
          finishedItem === self.queuePlayer.currentItem
        else {
          return
        }
        guard self.registeredVideoPaths.count > 1 else {
          self.queuePlayer.seek(to: .zero)
          self.queuePlayer.play()
          return
        }
        self.playNextVideo()
      }
    }
  }

  private func targetScreens() -> [NSScreen] {
    switch displayMode {
    case .allScreens:
      return NSScreen.screens
    case .mainOnly:
      if let main: NSScreen = NSScreen.main {
        return [main]
      }
      if let first: NSScreen = NSScreen.screens.first {
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
      retireWindows(extras)
    }

    for (index, screen) in screens.enumerated() {
      if index < windows.count {
        let window = windows[index]
        let playerView = playerViews[index]

        applyWindowOptions(window)
        window.ignoresMouseEvents = clickThrough
        window.setFrame(screen.frame, display: true)
        playerView.playerLayer.videoGravity =
          fitMode == .fit ? .resizeAspect : .resizeAspectFill
        if playerView.playerLayer.player !== queuePlayer {
          playerView.playerLayer.player = queuePlayer
        }
        if window.contentView !== playerView {
          window.contentView = playerView
        }
        window.orderBack(nil)
        window.orderFront(nil)
        continue
      }

      let frame: NSRect = screen.frame
      let window: NSWindow = NSWindow(
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

      let playerView = PlayerView(frame: .zero)
      playerView.wantsLayer = true
      playerView.playerLayer.videoGravity =
        fitMode == .fit ? .resizeAspect : .resizeAspectFill
      playerView.playerLayer.player = queuePlayer
      window.contentView = playerView
      window.orderBack(nil)
      window.orderFront(nil)

      windows.append(window)
      playerViews.append(playerView)
    }

    lastScreenSignatures = screenSignatures(for: screens)
  }

  private func prepareWindowForRetire(_ window: NSWindow) {
    if let playerView = window.contentView as? PlayerView {
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

      let targets = self.retiredWindows
      self.retiredWindows.removeAll()
      for window in targets {
        self.prepareWindowForRetire(window)
        window.close()
      }
    }

    windowRetireWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
  }

  private func applyWindowOptions(_ window: NSWindow) {
    let baseLevel: Int = Int(CGWindowLevelForKey(.desktopWindow))
    let levelValue: Int = baseLevel + desktopLevelOffset.rawValue
    window.level = NSWindow.Level(rawValue: levelValue)

    var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    if useFullScreenAuxiliary {
      behavior.insert(.fullScreenAuxiliary)
    }
    window.collectionBehavior = behavior
  }

  private func scheduleScreenSync() {
    screenChangeWorkItem?.cancel()

    let workItem = DispatchWorkItem { [weak self] in
      guard let self else {
        return
      }
      self.syncWindowsToCurrentScreens()
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
        windows[index].setFrame(screen.frame, display: true)
      }
      lastScreenSignatures = signatures
      return
    }

    rebuildWindows()
  }

  private func scheduleWindowRebuild(delay: TimeInterval = 0.08) {
    windowRebuildWorkItem?.cancel()

    let workItem = DispatchWorkItem { [weak self] in
      guard let self else {
        return
      }
      self.rebuildWindows()
    }

    windowRebuildWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  private func scheduleWindowOptionsApply(delay: TimeInterval = 0.02) {
    windowOptionsWorkItem?.cancel()

    let workItem = DispatchWorkItem { [weak self] in
      guard let self else {
        return
      }
      for window in self.windows {
        self.applyWindowOptions(window)
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
    let gravity: AVLayerVideoGravity = mode == .fit ? .resizeAspect : .resizeAspectFill
    for playerView in playerViews {
      playerView.playerLayer.videoGravity = gravity
    }
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
    if let currentPath: String = currentVideoPath {
      playVideo(url: URL(fileURLWithPath: currentPath))
    }
  }

  func setDecodeMode(_ mode: DecodeMode) {
    guard decodeMode != mode else {
      return
    }
    decodeMode = mode
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
        queuePlayer.pause()
        queuePlayer.removeAllItems()
        playerLooper = nil
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
      queuePlayer.pause()
      queuePlayer.removeAllItems()
      playerLooper = nil
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
    let newPlaylist = WallpaperPlaylist(
      id: UUID(),
      name: "プレイリスト\(playlists.count + 1)",
      videoPaths: []
    )
    playlists.append(newPlaylist)
    selectedPlaylistID = newPlaylist.id
    syncActivePlaylistPaths()
    persistPlaylistState()

    let beforeCount = registeredVideoPaths.count
    setVideo(path: path)
    let didAdd = registeredVideoPaths.count > beforeCount
    if didAdd {
      return true
    }

    if let index = playlists.firstIndex(where: { $0.id == newPlaylist.id }) {
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
    if shufflePlaybackEnabled && registeredVideoPaths.count > 2 {
      var candidate = Int.random(in: 0...maxIndex)
      while candidate == baseIndex {
        candidate = Int.random(in: 0...maxIndex)
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
    let sourceURL: URL = URL(fileURLWithPath: trimmed)
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

    addVideoPathToSelectedPlaylist(localURL.path, preferredDisplayName: sourceURL.lastPathComponent)
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
    UserDefaults.standard.set(registeredVideoDisplayNames, forKey: "registeredVideoDisplayNames")
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
    UserDefaults.standard.set(registeredVideoDisplayNames, forKey: "registeredVideoDisplayNames")

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
        queuePlayer.pause()
        queuePlayer.removeAllItems()
        playerLooper = nil
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
        at: directory, withIntermediateDirectories: true)
      NSWorkspace.shared.open(directory)
    } catch {
      return
    }
  }

  func clearCache() -> Bool {
    guard let directory = cacheDirectoryURL() else {
      return false
    }

    do {
      if FileManager.default.fileExists(atPath: directory.path) {
        try FileManager.default.removeItem(at: directory)
      }
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
      playlists.removeAll()
      selectedPlaylistID = nil
      registeredVideoPaths.removeAll()
      UserDefaults.standard.removeObject(forKey: "registeredVideoPaths")
      registeredVideoDisplayNames.removeAll()
      UserDefaults.standard.set(registeredVideoDisplayNames, forKey: "registeredVideoDisplayNames")
      if let currentPath: String = currentVideoPath, currentPath.hasPrefix(directory.path) {
        queuePlayer.pause()
        queuePlayer.removeAllItems()
        playerLooper = nil
        currentVideoPath = nil
        currentVideoIndex = nil
        UserDefaults.standard.removeObject(forKey: "videoPath")
      }
      persistPlaylistState()
      return true
    } catch {
      return false
    }
  }

  private func applyLightweightSettings() {
    queuePlayer.automaticallyWaitsToMinimizeStalling = lightweightMode
  }

  private func applyAudioSettings() {
    queuePlayer.isMuted = !audioEnabled
    queuePlayer.volume = audioVolume
  }

  private func playVideo(url: URL) {
    let asset = AVURLAsset(
      url: url,
      options: [
        AVURLAssetPreferPreciseDurationAndTimingKey: decodeMode == .balanced
      ]
    )
    let item = AVPlayerItem(asset: asset)
    switch frameRateLimit {
    case .off:
      item.preferredPeakBitRate = lightweightMode ? 1_500_000 : 0
    case .fps30:
      item.preferredPeakBitRate = 3_000_000
    case .fps60:
      item.preferredPeakBitRate = 6_000_000
    }

    switch decodeMode {
    case .automatic:
      item.preferredForwardBufferDuration = lightweightMode ? 0 : 1
    case .balanced:
      item.preferredForwardBufferDuration = 1
    case .efficiency:
      item.preferredForwardBufferDuration = 0
      if item.preferredPeakBitRate == 0 {
        item.preferredPeakBitRate = 1_500_000
      }
    }
    queuePlayer.pause()
    queuePlayer.removeAllItems()
    playerLooper = nil
    if playlistPlaybackEnabled {
      queuePlayer.insert(item, after: nil)
    } else {
      playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: item)
    }
    applyAudioSettings()
    queuePlayer.play()
    evaluateForegroundCoverageState()
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
      "wallpaper-\(UUID().uuidString).\(ext)")

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
    let savedAudioVolume: Float = UserDefaults.standard.float(forKey: "audioVolume")
    audioVolume = savedAudioVolume == 0 ? 1.0 : min(max(savedAudioVolume, 0), 1)
    if UserDefaults.standard.object(forKey: "audioVolume") as? NSNumber != nil {
      audioVolume = min(max(savedAudioVolume, 0), 1)
    }
    applyAudioSettings()
    applyLightweightSettings()
    suspendWhenOtherAppFullScreen =
      UserDefaults.standard.object(forKey: "suspendWhenOtherAppFullScreen") as? Bool ?? false
    if let savedExclusions = UserDefaults.standard.stringArray(
      forKey: "suspendExclusionBundleIDs")
    {
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

    let allPaths = Set(playlists.flatMap { $0.videoPaths })
    if let savedDisplayNames = UserDefaults.standard.dictionary(
      forKey: "registeredVideoDisplayNames")
      as? [String: String]
    {
      registeredVideoDisplayNames = savedDisplayNames.filter {
        allPaths.contains($0.key)
      }
    }
    if let savedPath: String = UserDefaults.standard.string(forKey: "videoPath"),
      FileManager.default.fileExists(atPath: savedPath),
      let playlistContainingPath = playlists.first(where: { $0.videoPaths.contains(savedPath) })
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
    persistPlaylistState()
  }

  private func addVideoPathToSelectedPlaylist(_ path: String, preferredDisplayName: String? = nil) {
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
      UserDefaults.standard.set(registeredVideoDisplayNames, forKey: "registeredVideoDisplayNames")
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
  }

  private func pruneDisplayNamesForExistingPaths() {
    let validPaths = Set(playlists.flatMap { $0.videoPaths })
    registeredVideoDisplayNames = registeredVideoDisplayNames.filter { validPaths.contains($0.key) }
    UserDefaults.standard.set(registeredVideoDisplayNames, forKey: "registeredVideoDisplayNames")
  }

  private func persistPlaylistState() {
    if let data = try? JSONEncoder().encode(playlists) {
      UserDefaults.standard.set(data, forKey: "playlistsData")
    }
    UserDefaults.standard.set(registeredVideoPaths, forKey: "registeredVideoPaths")
    UserDefaults.standard.set(selectedPlaylistID?.uuidString, forKey: "selectedPlaylistID")
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
        self?.evaluateForegroundCoverageState()
      }
    }

    activeSpaceObserver = workspaceCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.evaluateForegroundCoverageState()
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
        model.evaluateForegroundCoverageState()
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
    let shouldSuspend = isFrontmostAppWindowVisible()
    applyCoveringAppSuspension(shouldSuspend)
  }

  private func applyCoveringAppSuspension(_ shouldSuspend: Bool) {
    guard isSuspendedByCoveringApp != shouldSuspend else {
      return
    }
    isSuspendedByCoveringApp = shouldSuspend
    if shouldSuspend {
      queuePlayer.pause()
    } else {
      queuePlayer.play()
    }
  }

  private func isFrontmostAppWindowVisible() -> Bool {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
      return false
    }

    if let bundleID = frontmostApp.bundleIdentifier,
      suspendExclusionBundleIDs.contains(normalizeBundleID(bundleID))
    {
      return false
    }

    let frontmostPID = frontmostApp.processIdentifier
    let ownPID = ProcessInfo.processInfo.processIdentifier
    guard frontmostPID != ownPID else {
      return false
    }

    guard
      let windowInfo = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[String: Any]]
    else {
      return false
    }

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

      if bounds.width >= 120, bounds.height >= 120 {
        return true
      }
    }

    return false
  }

  private func normalizeBundleID(_ bundleID: String) -> String {
    bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  func currentAppVersion() -> String {
    if let version: String = Bundle.main.object(
      forInfoDictionaryKey: "CFBundleShortVersionString")
      as? String,
      !version.isEmpty
    {
      return version
    }
    return AppConfig.defaultVersion
  }
}

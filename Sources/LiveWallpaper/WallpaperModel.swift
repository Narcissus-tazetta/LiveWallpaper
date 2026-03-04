import AVFoundation
import AppKit
import ApplicationServices
import Combine

enum AppConfig {
  static let defaultVersion = "0.0.3"
  static let sparkleAppcastURL =
    "https://raw.githubusercontent.com/Narcissus-tazetta/LiveWallpaper/main/docs/appcast.xml"
  static let sparklePublicEDKey = "uoATy8ItPd3DQDHahg8JEWgXUNS4//A29+JLUy2zxhY="
}

enum DisplayMode: String {
  case mainOnly
  case allScreens
}

enum VideoFitMode: String {
  case fill
  case fit
}

enum FrameRateLimit: String {
  case off
  case fps30
  case fps60
}

enum DecodeMode: String {
  case automatic
  case balanced
  case efficiency
}

enum DesktopLevelOffset: Int {
  case minusOne = -1
  case zero = 0
  case plusOne = 1
}

final class PlayerView: NSView {
  override func makeBackingLayer() -> CALayer {
    AVPlayerLayer()
  }

  var playerLayer: AVPlayerLayer {
    layer as! AVPlayerLayer
  }
}

@MainActor
final class WallpaperModel: ObservableObject {
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
  @Published private(set) var desktopLevelOffset: DesktopLevelOffset = .zero
  @Published private(set) var useFullScreenAuxiliary: Bool = false
  @Published private(set) var suspendWhenOtherAppFullScreen: Bool = false
  @Published private(set) var suspendExclusionBundleIDs: [String] = []

  @Published private(set) var currentVideoPath: String?

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

    guard let localURL: URL = importVideoToAppSupport(from: sourceURL) else {
      return
    }

    currentVideoPath = localURL.path
    UserDefaults.standard.set(localURL.path, forKey: "videoPath")

    playVideo(url: localURL)
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
      if let currentPath: String = currentVideoPath, currentPath.hasPrefix(directory.path) {
        queuePlayer.pause()
        queuePlayer.removeAllItems()
        playerLooper = nil
        currentVideoPath = nil
        UserDefaults.standard.removeObject(forKey: "videoPath")
      }
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
    playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: item)
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
      if let previousPath: String = currentVideoPath,
        previousPath.hasPrefix(targetDirectory.path),
        previousPath != targetURL.path,
        fileManager.fileExists(atPath: previousPath)
      {
        try fileManager.removeItem(atPath: previousPath)
      }
      try fileManager.copyItem(at: sourceURL, to: targetURL)

      if let files = try? fileManager.contentsOfDirectory(
        at: targetDirectory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      ) {
        for file in files {
          if file.path == targetURL.path {
            continue
          }
          if let previousPath = currentVideoPath, file.path == previousPath {
            continue
          }
          if file.lastPathComponent.hasPrefix("wallpaper-") {
            try? fileManager.removeItem(at: file)
          }
        }
      }
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
    if let savedPath: String = UserDefaults.standard.string(forKey: "videoPath") {
      currentVideoPath = savedPath
    }
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

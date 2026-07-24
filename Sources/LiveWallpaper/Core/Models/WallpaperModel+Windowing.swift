import AppKit
import AVFoundation
import Foundation

@MainActor
extension WallpaperModel {
    enum WindowRefreshReason: String {
        case activeSpaceTransition
        case finderRestart
    }

    private static let windowRefreshTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func refreshDelays(for reason: WindowRefreshReason) -> [TimeInterval] {
        switch reason {
        case .activeSpaceTransition:
            return [0.0]
        case .finderRestart:
            return [0.1, 0.35, 0.8, 1.6, 3.0]
        }
    }

    static func allowsWindowReorder(for reason: WindowRefreshReason) -> Bool {
        switch reason {
        case .activeSpaceTransition:
            return false
        case .finderRestart:
            return true
        }
    }

    static func shouldReassertOrderingOnRebuild(isReusedWindow: Bool) -> Bool {
        !isReusedWindow
    }

    private static func windowRefreshTimestamp() -> String {
        windowRefreshTimestampFormatter.string(from: Date())
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

    func setDesktopLevelOffset(_ offset: DesktopLevelOffset) {
        guard desktopLevelOffset != offset else {
            return
        }
        UserDefaults.standard.set(offset.rawValue, forKey: "desktopLevelOffset")
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            guard self.desktopLevelOffset != offset else {
                return
            }
            self.desktopLevelOffset = offset
            self.scheduleWindowOptionsApply()
        }
    }

    func setFullScreenAuxiliary(_ enabled: Bool) {
        guard useFullScreenAuxiliary != enabled else {
            return
        }
        UserDefaults.standard.set(enabled, forKey: "useFullScreenAuxiliary")
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            guard self.useFullScreenAuxiliary != enabled else {
                return
            }
            self.useFullScreenAuxiliary = enabled
            self.scheduleWindowOptionsApply()
        }
    }

    func availableDisplayScreens() -> [DisplayScreenInfo] {
        displayScreens
    }

    /// NSScreen.screens から画面一覧を作り直して displayScreens に発行する。
    /// 画面名はローカライズされるため、画面構成の変化だけでなく言語変更でも
    /// 呼ぶ必要がある。
    func refreshDisplayScreens() {
        let screens = NSScreen.screens
        let result = screens.enumerated().map { index, screen in
            let screenID = displayIDString(for: screen)
            let isMain = (NSScreen.main == screen)
            let screenLabel = localizedString("画面")
            let mainLabel = localizedString("メイン")
            let name = isMain
                ? "\(screenLabel)\(index + 1) (\(mainLabel))"
                : "\(screenLabel)\(index + 1)"
            return DisplayScreenInfo(id: screenID, name: name, frame: screen.frame)
        }
        guard result != displayScreens else {
            return
        }
        displayScreens = result
    }

    func displayIDForWindow(at index: Int) -> String {
        if index < windows.count {
            let window = windows[index]
            if let displayID = displayIDByWindow[ObjectIdentifier(window)] {
                return displayID
            }
        }
        if index < windows.count, let screen = windows[index].screen {
            return displayIDString(for: screen)
        }
        let screens = targetScreens()
        if index < screens.count {
            return displayIDString(for: screens[index])
        }
        return "main"
    }

    func applySuspensionStateToPlayers() {
        if isWebWallpaperActive {
            applyWebSuspensionState()
            return
        }
        // オーバーライド画面の専用プレイヤーは独立に処理し、以降の共有プレイヤー
        // ロジック(フリーズフレーム・deep suspend)は残りの画面だけを対象にする。
        applyDedicatedSuspensionState()
        guard let player = sharedPlayer else {
            return
        }
        let displayCount = max(playerViews.count, windows.count)
        guard displayCount > 0 else {
            player.pause()
            return
        }
        let displayIDs = (0 ..< displayCount).map { displayIDForWindow(at: $0) }
        let sharedDisplayIDs = sharedPlayerDisplayIDs(among: displayIDs)
        // 共有プレイヤーを使う画面が1つもない(全画面オーバーライド中)場合も、
        // 共有プレイヤーはどこにも見えていない=完全に隠れているのと同義に扱う。
        // そうしないと、もう使われていない共有プレイヤーの重いリソース(deep
        // suspend による解放)が永久に発火しなくなる。
        let allSuspended = sharedDisplayIDs.isEmpty
            || sharedDisplayIDs.allSatisfy { suspendedDisplayIDs.contains($0) }

        // A deep-resume is in flight (rebuilding the freed item in the
        // background). Until it finishes, keep showing the freeze frame rather
        // than attaching the not-yet-ready player. If coverage flipped back to
        // fully-covered mid-resume, abort the swap-in and fall through to
        // re-freeze; finishDeepResume then bails on its next tick.
        if isDeepResuming {
            if allSuspended {
                isDeepResuming = false
            } else {
                return
            }
        }

        // Resuming from deep suspend: the heavy video resources were freed while
        // fully covered, so we must rebuild the item before any layer is
        // re-attached. resumeFromDeepSuspend() keeps the freeze frame visible
        // until the fresh item is ready, then swaps it in seamlessly.
        if isDeepSuspended, !allSuspended {
            resumeFromDeepSuspend()
            return
        }

        if allSuspended {
            // If we've already deep-suspended (item torn down to save memory),
            // there is nothing live to capture — the shared player is empty and
            // reading currentTime()/capturing would be meaningless. Just keep the
            // cached freeze image applied to the layers and stay paused.
            if isDeepSuspended {
                applyFreezeImageToAllViews(lastCapturedFreezeFrameImage)
                player.pause()
                return
            }
            // Pausing AVPlayerLayer isn't reliable on its own here: it can drop
            // to its backgroundColor (see applyPlayerPresentation) instead of
            // holding the last composited frame. Detach the live player and show
            // a captured still instead, exactly like the web wallpaper already
            // freezes on a snapshot before hiding (WebPlayerView.setSuspended).
            //
            // This function is also called from hot paths unrelated to a real
            // suspend/resume transition (every playVideo, window rebuilds), so
            // while already suspended it can re-run with nothing to actually
            // capture. captureCurrentVideoFrame(from:) is a pure function of
            // (currentVideoPath, player.currentTime()) — the same file at the
            // same timestamp always decodes to the same pixels — so a redundant
            // decode is skipped when both match the last capture; only the
            // decode itself is skipped, the detach/apply-contents step below
            // still always runs (playVideo reattaches the live player before
            // calling this, so skipping that would flash the layer's background
            // color).
            let capturedTime = player.currentTime()
            let freezeImage: CGImage?
            if lastCapturedFreezeFrameVideoPath == currentVideoPath,
               lastCapturedFreezeFrameTime == capturedTime,
               let cachedImage = lastCapturedFreezeFrameImage
            {
                freezeImage = cachedImage
            } else {
                freezeImage = captureCurrentVideoFrame(from: player)
                lastCapturedFreezeFrameVideoPath = currentVideoPath
                lastCapturedFreezeFrameTime = capturedTime
                lastCapturedFreezeFrameImage = freezeImage
            }
            applyFreezeImageToAllViews(freezeImage)
            player.pause()
            // Free the heavy video resources if the wallpaper stays fully covered
            // long enough. Delayed so brief app switches never trigger a rebuild.
            scheduleDeepSuspend()
            return
        }

        // No longer fully suspended and not deep — cancel any pending free.
        cancelDeepSuspend()

        var viewsAwaitingFirstFrame: [PlayerView] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in playerViews.indices {
            let displayID = index < displayIDs.count
                ? displayIDs[index]
                : displayIDForWindow(at: index)
            // オーバーライド画面は applyDedicatedSuspensionState が担当済み。
            guard isSharedPlayerDisplay(displayID) else {
                continue
            }
            let expectedPlayer = suspendedDisplayIDs.contains(displayID) ? nil : player
            let layer = playerViews[index].playerLayer
            guard layer.player !== expectedPlayer else {
                continue
            }
            if expectedPlayer != nil, layer.contents != nil, !layer.isReadyForDisplay {
                // Re-attaching a live player to a layer that is currently showing
                // a freeze still, but that layer can't render a frame yet — e.g. a
                // deep-resume rebuilt the player from scratch, so this AVPlayerLayer
                // has never composited. Clearing `contents` now would leave the
                // layer momentarily empty, and its clear background shows through
                // as black. Keep the still up and drop it once the layer is ready.
                layer.player = expectedPlayer
                viewsAwaitingFirstFrame.append(playerViews[index])
            } else {
                if expectedPlayer != nil {
                    layer.contents = nil
                }
                layer.player = expectedPlayer
            }
        }
        CATransaction.commit()
        player.play()
        clearFreezeStillWhenReady(viewsAwaitingFirstFrame, attemptsRemaining: 30)
    }

    /// Drops the freeze still (`playerLayer.contents`) from each view once its
    /// layer can actually display a video frame, so a freshly-attached (e.g.
    /// deep-resumed) player never flashes its empty background before the first
    /// frame lands. Re-validated on every tick: a view that got re-suspended or
    /// re-detached meanwhile is dropped from the wait, and if readiness never
    /// reports we still reveal the live player rather than freezing forever.
    func clearFreezeStillWhenReady(
        _ views: [PlayerView],
        attemptsRemaining: Int
    ) {
        // Only keep waiting on views that are still live (a player attached) and
        // still showing a still. If a view was re-suspended in the meantime, the
        // freeze path owns its contents again — leave it untouched.
        let pending = views.filter { view in
            view.playerLayer.player != nil && view.playerLayer.contents != nil
        }
        guard !pending.isEmpty else {
            return
        }

        let giveUp = attemptsRemaining <= 0
        let clearable = pending.filter { $0.playerLayer.isReadyForDisplay || giveUp }
        if !clearable.isEmpty {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for view in clearable {
                view.playerLayer.contents = nil
            }
            CATransaction.commit()
        }

        let stillWaiting = pending.filter { !$0.playerLayer.isReadyForDisplay }
        guard !giveUp, !stillWaiting.isEmpty else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.clearFreezeStillWhenReady(
                stillWaiting,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }

    /// Synchronously decodes the frame at the player's current time directly
    /// from the asset file, independent of the live AVPlayerLayer's rendering
    /// state (which is what we can't rely on while paused/detached).
    ///
    /// Intentionally reads from `currentVideoPath` (the original file) rather than
    /// going through `resolvedPlaybackURL(for:)` — even when lightweight mode is
    /// swapped to a proxy, a single still-frame decode here is cheap and this
    /// keeps the freeze-frame at full source quality.
    private func captureCurrentVideoFrame(from player: AVPlayer) -> CGImage? {
        guard let path = currentVideoPath else {
            return nil
        }
        return VideoFrameCapture.capture(path: path, time: player.currentTime())
    }

    func configureWallpaperWindowRefreshMonitoring() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        if let observer = spaceTransitionGuardObserver {
            workspaceCenter.removeObserver(observer)
            spaceTransitionGuardObserver = nil
        }
        // Space切替からこの通知が飛んでくるまでにはOS側の遅延があり(Mission
        // Controlの切替アニメーション後にやや遅れて発火する)、アプリ側では
        // 検知しようがない。壁紙ウィンドウ自体は .canJoinAllSpaces で全Space
        // 共通の1枚なので、切替直後にほんの少しラグを感じるのはこの通知待ちが
        // 支配的要因であり、妥協して受け入れる(ウォームキャッシュ側の改善余地は
        // ensureDedicatedSlot 側のコメント参照)。
        spaceTransitionGuardObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.beginActiveSpaceTransitionLock(reason: "workspace-active-space")
                self?.handleActiveSpaceChanged()
            }
        }
        configureSpaceWakeMonitoring()

        finderLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                    app.bundleIdentifier == "com.apple.finder"
                else {
                    return
                }
                AppLog.windowRefresh.debug(
                    "finderLaunchDetected at=\(Self.windowRefreshTimestamp(), privacy: .public)"
                )
                self?.scheduleFinderRestartWindowRefresh()
            }
        }
    }

    func scheduleFinderRestartWindowRefresh() {
        scheduleWallpaperWindowRefresh(reason: .finderRestart)
    }

    func scheduleActiveSpaceWindowRefresh() {
        scheduleWallpaperWindowRefresh(reason: .activeSpaceTransition)
    }

    private func scheduleWallpaperWindowRefresh(reason: WindowRefreshReason) {
        if reason == .activeSpaceTransition, !shouldRefreshWindowsForActiveSpace() {
            AppLog.windowRefresh.debug(
                "skip reason=\(reason.rawValue, privacy: .public) unchanged-signature at=\(Self.windowRefreshTimestamp(), privacy: .public)"
            )
            return
        }
        activeSpaceWindowRefreshWorkItems.forEach { $0.cancel() }
        activeSpaceWindowRefreshWorkItems.removeAll()
        let delays = Self.refreshDelays(for: reason)
        let allowReorder = Self.allowsWindowReorder(for: reason)

        AppLog.windowRefresh.debug(
            "schedule reason=\(reason.rawValue, privacy: .public) allowReorder=\(allowReorder, privacy: .public) delays=\(String(describing: delays), privacy: .public) at=\(Self.windowRefreshTimestamp(), privacy: .public)"
        )

        for delay in delays {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else {
                    return
                }
                refreshWallpaperWindowsForActiveSpace(
                    allowReorder: allowReorder,
                    reason: reason
                )
            }
            activeSpaceWindowRefreshWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    func targetScreens() -> [NSScreen] {
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

    func rebuildWindows() {
        if isWebWallpaperActive {
            rebuildWebWindows()
        } else {
            rebuildVideoWindows()
        }
        applyMenuBarMaskState()
        applyDesktopReadabilityDimState()
    }

    private func rebuildVideoWindows() {
        let screens: [NSScreen] = targetScreens()
        let player = ensureSharedPlayer()

        var reusableByDisplayID: [String: NSWindow] = [:]
        for index in windows.indices {
            let displayID = displayIDForWindow(at: index)
            if reusableByDisplayID[displayID] == nil {
                reusableByDisplayID[displayID] = windows[index]
            }
        }

        var nextWindows: [NSWindow] = []
        var nextPlayerViews: [PlayerView] = []
        var reusedWindowIDs: Set<ObjectIdentifier> = []

        for screen in screens {
            let displayID = displayIDString(for: screen)
            let reusedWindow = reusableByDisplayID[displayID]
            let window = reusedWindow ?? makeBorderlessWallpaperWindow(for: screen, opaqueBackground: false)
            let playerView: PlayerView = {
                if let existing = window.contentView as? PlayerView {
                    return existing
                }
                let view = PlayerView(frame: CGRect(origin: .zero, size: screen.frame.size))
                view.autoresizingMask = [.width, .height]
                return view
            }()

            applyWindowOptions(window)
            window.ignoresMouseEvents = clickThrough
            if window.frame != screen.frame {
                window.setFrame(screen.frame, display: true)
            }
            applyPlayerPresentation(to: playerView, screen: screen)
            // オーバーライド画面への専用プレイヤーの付け替えは、この後の
            // applySuspensionStateToPlayers に任せる。
            if isSharedPlayerDisplay(displayID),
               playerView.playerLayer.player !== player
            {
                playerView.playerLayer.player = player
            }
            if window.contentView !== playerView {
                window.contentView = playerView
            }
            if Self.shouldReassertOrderingOnRebuild(isReusedWindow: reusedWindow != nil) {
                reassertWallpaperOrdering(window)
            }

            displayIDByWindow[ObjectIdentifier(window)] = displayID
            reusedWindowIDs.insert(ObjectIdentifier(window))
            nextWindows.append(window)
            nextPlayerViews.append(playerView)
        }

        let obsoleteWindows = windows.filter { !reusedWindowIDs.contains(ObjectIdentifier($0)) }
        retireObsoleteWindows(obsoleteWindows)

        windows = nextWindows
        playerViews = nextPlayerViews
        webPlayerViews = []

        pruneDedicatedPlayers(activeDisplayIDs: Set(screens.map { displayIDString(for: $0) }))
        syncSuspendedDisplays(for: screens)
        applySuspensionStateToPlayers()

        lastScreenSignatures = screenSignatures(for: screens)
    }

    private func rebuildWebWindows() {
        // Web壁紙は全画面を置き換えるため、専用プレイヤーは全て解放する。
        stopAllDedicatedPlayers()
        let screens: [NSScreen] = targetScreens()

        var reusableByDisplayID: [String: NSWindow] = [:]
        for index in windows.indices {
            let displayID = displayIDForWindow(at: index)
            if reusableByDisplayID[displayID] == nil {
                reusableByDisplayID[displayID] = windows[index]
            }
        }

        var nextWindows: [NSWindow] = []
        var nextWebPlayerViews: [WebPlayerView] = []
        var reusedWindowIDs: Set<ObjectIdentifier> = []

        for screen in screens {
            let displayID = displayIDString(for: screen)
            let reusedWindow = reusableByDisplayID[displayID]
            let window = reusedWindow ?? makeBorderlessWallpaperWindow(for: screen, opaqueBackground: true)
            let webView: WebPlayerView = {
                if let existing = window.contentView as? WebPlayerView {
                    return existing
                }
                let view = WebPlayerView(frame: CGRect(origin: .zero, size: screen.frame.size))
                view.autoresizingMask = [.width, .height]
                return view
            }()

            applyWindowOptions(window)
            window.ignoresMouseEvents = clickThrough
            if window.frame != screen.frame {
                window.setFrame(screen.frame, display: true)
            }
            if window.contentView !== webView {
                window.contentView = webView
            }
            if Self.shouldReassertOrderingOnRebuild(isReusedWindow: reusedWindow != nil) {
                reassertWallpaperOrdering(window)
            }

            displayIDByWindow[ObjectIdentifier(window)] = displayID
            reusedWindowIDs.insert(ObjectIdentifier(window))
            nextWindows.append(window)
            nextWebPlayerViews.append(webView)
        }

        let obsoleteWindows = windows.filter { !reusedWindowIDs.contains(ObjectIdentifier($0)) }
        retireObsoleteWindows(obsoleteWindows)

        windows = nextWindows
        webPlayerViews = nextWebPlayerViews
        playerViews = []

        syncSuspendedDisplays(for: screens)
        applyWebSuspensionState()

        lastScreenSignatures = screenSignatures(for: screens)

        if let source = activeWebWallpaperSource {
            loadWebWallpaper(source: source)
        }
    }

    private func retireObsoleteWindows(_ obsoleteWindows: [NSWindow]) {
        retireWindows(obsoleteWindows)
    }

    private func syncSuspendedDisplays(for screens: [NSScreen]) {
        let validDisplayIDs = Set(screens.map { displayIDString(for: $0) })
        suspendedDisplayIDs = suspendedDisplayIDs.intersection(validDisplayIDs)
        // Reduce Motion 中は、ウィンドウ再構築で追加/変化した画面も含めて
        // すべて静止させたままにする(intersection で消えた分を戻す)。
        if reduceMotionFreezeActive {
            suspendedDisplayIDs.formUnion(validDisplayIDs)
        }
    }

    private func makeBorderlessWallpaperWindow(
        for screen: NSScreen,
        opaqueBackground: Bool
    ) -> NSWindow {
        let frame = screen.frame
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = opaqueBackground ? .black : .clear
        window.isOpaque = opaqueBackground
        window.hasShadow = false
        window.animationBehavior = .none
        window.setFrame(frame, display: true)
        return window
    }

    private func makeWallpaperWebWindow(for screen: NSScreen) -> (window: NSWindow, webView: WebPlayerView) {
        let frame = screen.frame
        let window = makeBorderlessWallpaperWindow(for: screen, opaqueBackground: true)

        let webView = WebPlayerView(frame: CGRect(origin: .zero, size: frame.size))
        webView.autoresizingMask = [.width, .height]
        window.contentView = webView
        return (window, webView)
    }

    private func makeWallpaperWindow(
        for screen: NSScreen,
        player: AVQueuePlayer
    ) -> (window: NSWindow, playerView: PlayerView) {
        let frame = screen.frame
        let window = makeBorderlessWallpaperWindow(for: screen, opaqueBackground: false)

        let playerView = PlayerView(frame: CGRect(origin: .zero, size: frame.size))
        playerView.autoresizingMask = [.width, .height]
        playerView.playerLayer.player = player
        window.contentView = playerView
        return (window, playerView)
    }

    private func prepareWindowForRetire(_ window: NSWindow) {
        displayIDByWindow.removeValue(forKey: ObjectIdentifier(window))
        if let playerView = window.contentView as? PlayerView {
            presentationCacheByPlayerView.removeValue(forKey: ObjectIdentifier(playerView))
            playerView.playerLayer.player = nil
        } else if let webView = window.contentView as? WebPlayerView {
            webView.tearDown()
        }
        window.contentView = nil
    }

    private func retireWindows(_ windowsToRetire: [NSWindow]) {
        guard !windowsToRetire.isEmpty else {
            return
        }
        for window in windowsToRetire {
            prepareWindowForRetire(window)
            window.close()
        }
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

    private func refreshWallpaperWindowsForActiveSpace(
        allowReorder: Bool,
        reason: WindowRefreshReason
    ) {
        let screensByID = Dictionary(
            uniqueKeysWithValues: targetScreens().map { (displayIDString(for: $0), $0) }
        )

        AppLog.windowRefresh.debug(
            "run reason=\(reason.rawValue, privacy: .public) allowReorder=\(allowReorder, privacy: .public) windowCount=\(self.windows.count) at=\(Self.windowRefreshTimestamp(), privacy: .public)"
        )

        for (index, window) in windows.enumerated() {
            applyWindowOptions(window)
            window.ignoresMouseEvents = clickThrough
            let displayID = displayIDForWindow(at: index)
            if let screen = screensByID[displayID] {
                if window.frame != screen.frame {
                    window.setFrame(screen.frame, display: true)
                }
                if isWebWallpaperActive, index < webPlayerViews.count {
                    let webView = webPlayerViews[index]
                    if window.contentView !== webView {
                        window.contentView = webView
                    }
                } else if index < playerViews.count {
                    let playerView = playerViews[index]
                    applyPlayerPresentation(to: playerView, screen: screen)
                    if isSharedPlayerDisplay(displayID),
                       playerView.playerLayer.player !== sharedPlayer
                    {
                        playerView.playerLayer.player = sharedPlayer
                    }
                    if window.contentView !== playerView {
                        window.contentView = playerView
                    }
                }
            }
            if allowReorder {
                reassertWallpaperOrdering(window)
            }
        }
        if isWebWallpaperActive {
            applyWebSuspensionState()
        } else {
            applySuspensionStateToPlayers()
        }
        applyMenuBarMaskState()
        applyDesktopReadabilityDimState()
    }

    private func reassertWallpaperOrdering(_ window: NSWindow) {
        guard !isActiveSpaceTransitioning else {
            AppLog.windowRefresh.debug(
                "skip-reorder active-space-transition at=\(Self.windowRefreshTimestamp(), privacy: .public)"
            )
            return
        }
        window.orderFront(nil)
    }

    func beginActiveSpaceTransitionLock(
        duration: TimeInterval = 1.2,
        reason: String
    ) {
        activeSpaceTransitionLockWorkItem?.cancel()
        isActiveSpaceTransitioning = true
        AppLog.spaceTransition.debug(
            "lock-start reason=\(reason, privacy: .public) duration=\(duration, format: .fixed(precision: 2)) at=\(Self.windowRefreshTimestamp(), privacy: .public)"
        )
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            isActiveSpaceTransitioning = false
            activeSpaceTransitionLockWorkItem = nil
            AppLog.spaceTransition.debug(
                "lock-end reason=\(reason, privacy: .public) at=\(Self.windowRefreshTimestamp(), privacy: .public)"
            )
        }
        activeSpaceTransitionLockWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(duration, 0.6),
            execute: workItem
        )
    }

    func shouldRefreshWindowsForActiveSpace() -> Bool {
        let screens = targetScreens()
        if windows.count != screens.count
            || (isWebWallpaperActive
                ? webPlayerViews.count != screens.count
                : playerViews.count != screens.count)
        {
            return true
        }
        let signatures = screenSignatures(for: screens)
        return signatures != lastScreenSignatures
    }

    func scheduleScreenSync() {
        refreshDisplayScreens()
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
        // 画面一覧は「壁紙ウィンドウを作り直すか」とは独立に最新化する。mainOnly では
        // targetScreens() がメインしか返さないため、サブ画面を外しても signature は
        // 変わらず下の guard で return する。ここで発行しないと、その経路では設定UIが
        // 外した画面を出したままになる。
        refreshDisplayScreens()

        let screens = targetScreens()
        let signatures = screenSignatures(for: screens)

        guard signatures != lastScreenSignatures else {
            return
        }

        // ディスプレイ構成が変わると CGS のディスプレイ↔Space 対応も変わるため、
        // ウィンドウ再構築前に現在 Space の解決を取り直す。
        if spaceWallpaperFeatureEnabled {
            refreshSpacesSnapshot()
        }
        rebuildWindows()
        evaluateSchedule(trigger: .displayConfigurationChanged)
    }

    func scheduleWindowRebuild(delay: TimeInterval = 0.2) {
        windowRebuildWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            rebuildWindows()
        }

        windowRebuildWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + min(max(delay, 0.2), 0.5),
            execute: workItem
        )
    }

    func scheduleWindowOptionsApply(delay: TimeInterval = 0.02) {
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

    func displayIDString(for screen: NSScreen?) -> String {
        guard let screen else {
            return "main"
        }
        let value =
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value ?? 0
        return String(value)
    }
}

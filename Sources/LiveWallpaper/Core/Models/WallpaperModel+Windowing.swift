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
        let screens = NSScreen.screens
        return screens.enumerated().map { index, screen in
            let screenID = displayIDString(for: screen)
            let isMain = (NSScreen.main == screen)
            let screenLabel = localizedString("画面")
            let mainLabel = localizedString("メイン")
            let name = isMain
                ? "\(screenLabel)\(index + 1) (\(mainLabel))"
                : "\(screenLabel)\(index + 1)"
            return DisplayScreenInfo(id: screenID, name: name, frame: screen.frame)
        }
    }

    private func displayIDForWindow(at index: Int) -> String {
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
        guard let player = sharedPlayer else {
            return
        }
        let displayCount = max(playerViews.count, windows.count)
        guard displayCount > 0 else {
            player.pause()
            return
        }
        let displayIDs = (0 ..< displayCount).map { displayIDForWindow(at: $0) }
        let allSuspended = displayIDs.allSatisfy { suspendedDisplayIDs.contains($0) }

        if allSuspended {
            for index in playerViews.indices {
                if playerViews[index].playerLayer.player !== player {
                    playerViews[index].playerLayer.player = player
                }
            }
            player.pause()
            return
        }

        for index in playerViews.indices {
            let displayID = index < displayIDs.count
                ? displayIDs[index]
                : displayIDForWindow(at: index)
            let expectedPlayer = suspendedDisplayIDs.contains(displayID) ? nil : player
            if playerViews[index].playerLayer.player !== expectedPlayer {
                playerViews[index].playerLayer.player = expectedPlayer
            }
        }
        player.play()
    }

    func configureWallpaperWindowRefreshMonitoring() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        if let observer = spaceTransitionGuardObserver {
            workspaceCenter.removeObserver(observer)
            spaceTransitionGuardObserver = nil
        }
        spaceTransitionGuardObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.beginActiveSpaceTransitionLock(reason: "workspace-active-space")
            }
        }

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
                NSLog(
                    "[WindowRefresh] finderLaunchDetected at=%@",
                    Self.windowRefreshTimestamp()
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
            NSLog(
                "[WindowRefresh] skip reason=%@ unchanged-signature at=%@",
                reason.rawValue,
                Self.windowRefreshTimestamp()
            )
            return
        }
        activeSpaceWindowRefreshWorkItems.forEach { $0.cancel() }
        activeSpaceWindowRefreshWorkItems.removeAll()
        let delays = Self.refreshDelays(for: reason)
        let allowReorder = Self.allowsWindowReorder(for: reason)

        NSLog(
            "[WindowRefresh] schedule reason=%@ allowReorder=%@ delays=%@ at=%@",
            reason.rawValue,
            allowReorder ? "true" : "false",
            String(describing: delays),
            Self.windowRefreshTimestamp()
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
        let screens: [NSScreen] = targetScreens()
        let player = ensureSharedPlayer()

        var reusableByDisplayID: [String: (window: NSWindow, playerView: PlayerView)] = [:]
        for index in windows.indices where index < playerViews.count {
            let displayID = displayIDForWindow(at: index)
            if reusableByDisplayID[displayID] == nil {
                reusableByDisplayID[displayID] = (windows[index], playerViews[index])
            }
        }

        var nextWindows: [NSWindow] = []
        var nextPlayerViews: [PlayerView] = []
        var reusedWindowIDs: Set<ObjectIdentifier> = []

        for screen in screens {
            let displayID = displayIDString(for: screen)
            let reusedPair = reusableByDisplayID[displayID]
            let pair = reusedPair ?? makeWallpaperWindow(for: screen, player: player)
            let window = pair.window
            let playerView = pair.playerView

            applyWindowOptions(window)
            window.ignoresMouseEvents = clickThrough
            if window.frame != screen.frame {
                window.setFrame(screen.frame, display: true)
            }
            applyPlayerPresentation(to: playerView, screen: screen)
            if playerView.playerLayer.player !== player {
                playerView.playerLayer.player = player
            }
            if window.contentView !== playerView {
                window.contentView = playerView
            }
            if Self.shouldReassertOrderingOnRebuild(isReusedWindow: reusedPair != nil) {
                reassertWallpaperOrdering(window)
            }

            displayIDByWindow[ObjectIdentifier(window)] = displayID
            reusedWindowIDs.insert(ObjectIdentifier(window))
            nextWindows.append(window)
            nextPlayerViews.append(playerView)
        }

        let obsoleteWindows = windows.filter { !reusedWindowIDs.contains(ObjectIdentifier($0)) }
        for window in obsoleteWindows {
            prepareWindowForRetire(window)
            window.orderOut(nil)
        }
        retireWindows(obsoleteWindows)

        windows = nextWindows
        playerViews = nextPlayerViews

        let validDisplayIDs = Set(screens.map { displayIDString(for: $0) })
        suspendedDisplayIDs = suspendedDisplayIDs.intersection(validDisplayIDs)
        applySuspensionStateToPlayers()

        lastScreenSignatures = screenSignatures(for: screens)
    }

    private func makeWallpaperWindow(
        for screen: NSScreen,
        player: AVQueuePlayer
    ) -> (window: NSWindow, playerView: PlayerView) {
        let frame: NSRect = screen.frame
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.setFrame(frame, display: true)

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

    private func refreshWallpaperWindowsForActiveSpace(
        allowReorder: Bool,
        reason: WindowRefreshReason
    ) {
        let screensByID = Dictionary(
            uniqueKeysWithValues: targetScreens().map { (displayIDString(for: $0), $0) }
        )

        NSLog(
            "[WindowRefresh] run reason=%@ allowReorder=%@ windowCount=%d at=%@",
            reason.rawValue,
            allowReorder ? "true" : "false",
            windows.count,
            Self.windowRefreshTimestamp()
        )

        for (index, window) in windows.enumerated() {
            applyWindowOptions(window)
            window.ignoresMouseEvents = clickThrough
            let displayID = displayIDForWindow(at: index)
            if let screen = screensByID[displayID] {
                if window.frame != screen.frame {
                    window.setFrame(screen.frame, display: true)
                }
                if index < playerViews.count {
                    let playerView = playerViews[index]
                    applyPlayerPresentation(to: playerView, screen: screen)
                    if playerView.playerLayer.player !== sharedPlayer {
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
        applySuspensionStateToPlayers()
    }

    private func reassertWallpaperOrdering(_ window: NSWindow) {
        guard !isActiveSpaceTransitioning else {
            NSLog(
                "[WindowRefresh] skip-reorder active-space-transition at=%@",
                Self.windowRefreshTimestamp()
            )
            return
        }
        window.orderBack(nil)
        window.orderFront(nil)
    }

    func beginActiveSpaceTransitionLock(
        duration: TimeInterval = 1.2,
        reason: String
    ) {
        activeSpaceTransitionLockWorkItem?.cancel()
        isActiveSpaceTransitioning = true
        NSLog(
            "[SpaceTransition] lock-start reason=%@ duration=%.2f at=%@",
            reason,
            duration,
            Self.windowRefreshTimestamp()
        )
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            isActiveSpaceTransitioning = false
            activeSpaceTransitionLockWorkItem = nil
            NSLog(
                "[SpaceTransition] lock-end reason=%@ at=%@",
                reason,
                Self.windowRefreshTimestamp()
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
        if windows.count != screens.count || playerViews.count != screens.count {
            return true
        }
        let signatures = screenSignatures(for: screens)
        return signatures != lastScreenSignatures
    }

    func scheduleScreenSync() {
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

        rebuildWindows()
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

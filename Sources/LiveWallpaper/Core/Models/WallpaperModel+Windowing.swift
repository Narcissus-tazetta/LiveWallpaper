import AppKit
import AVFoundation
import Foundation

@MainActor
extension WallpaperModel {
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
        UserDefaults.standard.set(mode.rawValue, forKey: "displayMode")
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            guard self.displayMode != mode else {
                return
            }
            self.displayMode = mode
            self.scheduleWindowRebuild()
        }
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
            player.pause()
        } else {
            player.play()
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
            let pair = reusableByDisplayID[displayID] ?? makeWallpaperWindow(
                for: screen,
                player: player
            )
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
            window.orderBack(nil)
            window.orderFront(nil)

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

    func scheduleActiveSpaceWindowRefresh() {
        activeSpaceWindowRefreshWorkItems.forEach { $0.cancel() }
        activeSpaceWindowRefreshWorkItems.removeAll()

        for delay in [0.03, 0.18, 0.45] {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else {
                    return
                }
                refreshWallpaperWindowsForActiveSpace()
            }
            activeSpaceWindowRefreshWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func refreshWallpaperWindowsForActiveSpace() {
        let screensByID = Dictionary(
            uniqueKeysWithValues: targetScreens().map { (displayIDString(for: $0), $0) }
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
            window.orderFrontRegardless()
        }
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

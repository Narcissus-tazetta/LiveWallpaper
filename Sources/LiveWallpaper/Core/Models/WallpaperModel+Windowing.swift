import AppKit
import AVFoundation
import Foundation

/// 壁紙ウィンドウの構築・破棄と、画面(NSScreen)状態の管理。
/// スケジューリング(デバウンス・Space切替監視)は [[WallpaperModel+WindowRefreshScheduling]]、
/// 再生/一時停止の反映は [[WallpaperModel+PlayerSuspension]] を参照。
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
        UserDefaults.standard.set(enabled, forKey: PrefsKey.clickThrough)
    }

    func setDisplayMode(_ mode: DisplayMode) {
        guard displayMode != mode else {
            return
        }
        displayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: PrefsKey.displayMode)
        scheduleWindowRebuild()
    }

    func setDesktopLevelOffset(_ offset: DesktopLevelOffset) {
        guard desktopLevelOffset != offset else {
            return
        }
        UserDefaults.standard.set(offset.rawValue, forKey: PrefsKey.desktopLevelOffset)
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
        UserDefaults.standard.set(enabled, forKey: PrefsKey.useFullScreenAuxiliary)
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

    /// スケジューリング側(即時再構築後の枠適用・アクティブSpace再描画)からも呼ばれる。
    func applyWindowOptions(_ window: NSWindow) {
        let baseLevel = Int(CGWindowLevelForKey(.desktopWindow))
        let levelValue: Int = baseLevel + desktopLevelOffset.rawValue
        window.level = NSWindow.Level(rawValue: levelValue)

        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if useFullScreenAuxiliary {
            behavior.insert(.fullScreenAuxiliary)
        }
        window.collectionBehavior = behavior
    }

    /// スケジューリング側(shouldRefreshWindowsForActiveSpace/syncWindowsToCurrentScreens)からも呼ばれる。
    func screenSignatures(for screens: [NSScreen]) -> [ScreenSignature] {
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

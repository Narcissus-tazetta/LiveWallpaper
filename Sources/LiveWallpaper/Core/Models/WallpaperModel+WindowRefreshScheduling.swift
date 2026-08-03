import AppKit
import Foundation

/// 壁紙ウィンドウ再構築のデバウンス・Space切替/Finder再起動の監視。
/// ウィンドウそのものの構築/破棄は [[WallpaperModel+Windowing]] を参照。
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

    /// ウィンドウ構築(Windowing)側からも呼ばれる。
    func reassertWallpaperOrdering(_ window: NSWindow) {
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
}

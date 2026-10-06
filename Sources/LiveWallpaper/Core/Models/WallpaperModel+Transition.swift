import AppKit
import AVFoundation

/// An outgoing player kept alive only while a switch effect still shows it. Torn
/// down in the same order as stopAllPlayers (looping off before removing items),
/// because removing items from a still-looping AVQueuePlayer corrupts its state.
@MainActor
final class TransitionHeldPlayer {
    let player: AVQueuePlayer
    private(set) var looper: AVPlayerLooper?
    /// Dedicated players belong to their slot; the effect only becomes
    /// responsible for tearing one down if the slot evicts it mid-fade.
    private(set) var ownsPlayer: Bool
    private var users = 0
    private let onRelease: (TransitionHeldPlayer) -> Void

    init(
        player: AVQueuePlayer,
        looper: AVPlayerLooper?,
        ownsPlayer: Bool,
        onRelease: @escaping (TransitionHeldPlayer) -> Void
    ) {
        self.player = player
        self.looper = looper
        self.ownsPlayer = ownsPlayer
        self.onRelease = onRelease
    }

    func adopt(looper: AVPlayerLooper) {
        self.looper = looper
        ownsPlayer = true
    }

    func retain() {
        users += 1
    }

    func release() {
        users -= 1
        guard users <= 0 else {
            return
        }
        defer { onRelease(self) }
        guard ownsPlayer else {
            return
        }
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
    }
}

/// Wallpaper switch effects (cross-fade / dip to black).
///
/// Decoding a still of the outgoing frame takes 200–400 ms on the main thread for
/// 4K video, so instead the outgoing player is kept running in a second layer for
/// the length of the effect and removed once the new content is really on screen.
@MainActor
extension WallpaperModel {
    static let wallpaperTransitionDurationOptions: [Double] = [0, 0.5, 1, 2]
    private static let videoReadyTimeout: TimeInterval = 3
    private static let webReadyTimeout: TimeInterval = 8

    var wallpaperTransitionsEnabled: Bool {
        wallpaperTransitionDuration > 0
            && !systemReduceMotionEnabled
            && wallpaperTransitionSuppressionDepth == 0
            && wallpaperTransitionNestingDepth == 0
    }

    func setWallpaperTransitionDuration(_ seconds: Double) {
        guard wallpaperTransitionDuration != seconds else {
            return
        }
        wallpaperTransitionDuration = seconds
        UserDefaults.standard.set(seconds, forKey: PrefsKey.wallpaperTransitionDuration)
    }

    func setWallpaperTransitionStyle(_ style: WallpaperTransitionStyle) {
        guard wallpaperTransitionStyle != style else {
            return
        }
        wallpaperTransitionStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: PrefsKey.wallpaperTransitionStyle)
    }

    func restoreWallpaperTransitionSettings() {
        wallpaperTransitionDuration =
            UserDefaults.standard.object(forKey: PrefsKey.wallpaperTransitionDuration) as? Double ?? 0.5
        wallpaperTransitionStyle = UserDefaults.standard.string(forKey: PrefsKey.wallpaperTransitionStyle)
            .flatMap(WallpaperTransitionStyle.init(rawValue:)) ?? .crossfade
    }

    /// For updates that coincide with an OS animation (switching Spaces).
    func withoutWallpaperTransitions(_ body: () -> Void) {
        wallpaperTransitionSuppressionDepth += 1
        defer { wallpaperTransitionSuppressionDepth -= 1 }
        body()
    }

    /// Wraps a change of the wallpaper shared by all screens to `target`.
    func performSharedWallpaperTransition(
        to target: WallpaperPlaybackEntry,
        _ change: () -> Void
    ) {
        guard wallpaperTransitionsEnabled, currentPlaybackEntry != target else {
            change()
            return
        }
        wallpaperTransitionNestingDepth += 1
        defer { wallpaperTransitionNestingDepth -= 1 }

        let wasWeb = isWebWallpaperActive
        let targetIsWeb: Bool
        if case .web = target {
            targetIsWeb = true
        } else {
            targetIsWeb = false
        }
        let retired = wasWeb ? nil : retireSharedPlayerForTransition()
        retired?.retain()
        defer { retired?.release() }

        if wasWeb || targetIsWeb {
            // Video⇄web and web⇄web replace the content view itself. The old view is
            // moved as-is into a temporary window that keeps showing it on top.
            let overlays = handOffContentViewsToOverlayWindows(wasWeb: wasWeb)
            change()
            retired?.retain()
            finishOverlayTransitionWhenReady(
                overlays,
                targetIsWeb: targetIsWeb,
                deadline: Date().addingTimeInterval(targetIsWeb ? Self.webReadyTimeout : Self.videoReadyTimeout),
                completion: { retired?.release() }
            )
            startAudioTransition(from: retired?.player)
            return
        }

        let candidates = playerViews.indices
            .filter { isSharedPlayerDisplay(displayIDForWindow(at: $0)) }
            .map { playerViews[$0] }
        transitionViews(candidates, livePlayer: { layer in
            retired.flatMap { layer.player === $0.player ? $0.player : nil }
        }, change: change, completion: { _ in
            retired?.retain()
            return { retired?.release() }
        })
        startAudioTransition(from: retired?.player)
    }

    /// Wraps a per-display or per-Space assignment change. Which screens change is
    /// only known after the change resolves, so every screen is prepared and the
    /// ones whose content did not change are dropped before anything is drawn.
    func performDisplayAssignmentTransition(_ change: () -> Void) {
        guard wallpaperTransitionsEnabled, !isWebWallpaperActive else {
            change()
            return
        }
        wallpaperTransitionNestingDepth += 1
        defer { wallpaperTransitionNestingDepth -= 1 }

        var heldByView: [ObjectIdentifier: TransitionHeldPlayer] = [:]
        for view in playerViews {
            // Keep a dedicated player's picture until the fade ends even if
            // unassigning evicts its slot (see adoptEvictedPlayerForTransition).
            if let player = view.playerLayer.player as? AVQueuePlayer, player !== sharedPlayer {
                let held = holdPlayerForTransition(player)
                held.retain()
                heldByView[ObjectIdentifier(view)] = held
            }
        }
        transitionViews(playerViews, livePlayer: { $0.player }, change: change, completion: { view in
            guard let held = heldByView[ObjectIdentifier(view)] else {
                return nil
            }
            held.retain()
            return { held.release() }
        })
        // Effects that are running took their own hold; drop the setup one.
        for held in heldByView.values {
            held.release()
        }
    }

    /// Called from evictDedicatedSlot: takes over tearing the player down if an
    /// effect is still showing it.
    func adoptEvictedPlayerForTransition(_ player: AVQueuePlayer, looper: AVPlayerLooper) -> Bool {
        guard let held = transitionHeldPlayers[ObjectIdentifier(player)] else {
            return false
        }
        held.adopt(looper: looper)
        return true
    }

    // MARK: - In-view effect

    /// Pins the current content of `views`, applies `change`, then runs the effect
    /// on the views whose content actually changed. `completion` is asked once per
    /// running effect for a callback to invoke when that effect ends.
    private func transitionViews(
        _ views: [PlayerView],
        livePlayer: (AVPlayerLayer) -> AVPlayer?,
        change: () -> Void,
        completion: (PlayerView) -> (() -> Void)?
    ) {
        struct Pinned {
            let view: PlayerView
            let generation: Int
            let player: AVPlayer?
            let still: Any?
        }
        var pinned: [Pinned] = []
        for view in views {
            let layer = view.playerLayer
            let player = livePlayer(layer)
            guard player != nil || layer.contents != nil else {
                continue
            }
            let generation = view.beginTransition(from: player, still: layer.contents)
            pinned.append(Pinned(view: view, generation: generation, player: layer.player, still: layer.contents))
        }
        change()
        // Same run loop turn as beginTransition, so nothing has been rendered yet;
        // dropping unchanged views here is invisible.
        for entry in pinned {
            let layer = entry.view.playerLayer
            let unchanged = layer.player === entry.player
                && (layer.player != nil || (layer.contents as AnyObject?) === (entry.still as AnyObject?))
            if unchanged || !playerViews.contains(where: { $0 === entry.view }) {
                entry.view.cancelTransition()
                continue
            }
            entry.view.startTransition(
                generation: entry.generation,
                style: wallpaperTransitionStyle,
                duration: wallpaperTransitionDuration
            )
            finishTransitionWhenReady(
                entry.view,
                generation: entry.generation,
                deadline: Date().addingTimeInterval(Self.videoReadyTimeout),
                completion: completion(entry.view) ?? {}
            )
        }
    }

    private func finishTransitionWhenReady(
        _ view: PlayerView,
        generation: Int,
        deadline: Date,
        firstObservedTime: CMTime? = nil,
        completion: @escaping () -> Void
    ) {
        guard generation == view.transitionGeneration else {
            completion()
            return
        }
        let progress = Self.newContentProgress(view.playerLayer, firstObservedTime: firstObservedTime)
        guard progress.isShowing || Date() >= deadline else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.finishTransitionWhenReady(
                    view, generation: generation, deadline: deadline,
                    firstObservedTime: progress.firstObservedTime, completion: completion
                )
            }
            return
        }
        if !progress.isShowing {
            AppLog.windowRefresh.error("transition: new content not on screen before timeout; finishing anyway")
        }
        view.finishTransition(
            generation: generation,
            style: wallpaperTransitionStyle,
            duration: wallpaperTransitionDuration,
            completion: completion
        )
    }

    /// Whether the layer is really drawing the new content yet. Right after a player
    /// swap, AVPlayerLayer reports isReadyForDisplay (and the item reports
    /// readyToPlay) several hundred ms before the first frame is actually on screen,
    /// so fading on those signals exposes black. Playback time advancing past the
    /// first observed position is the signal that frames are being rendered.
    static func newContentProgress(
        _ layer: AVPlayerLayer,
        firstObservedTime: CMTime?
    ) -> (isShowing: Bool, firstObservedTime: CMTime?) {
        guard let player = layer.player else {
            return (layer.contents != nil, nil)
        }
        guard let item = player.currentItem, item.status == .readyToPlay, layer.isReadyForDisplay else {
            return (false, firstObservedTime)
        }
        let now = player.currentTime()
        guard let first = firstObservedTime else {
            return (false, now)
        }
        // A paused player never advances; once ready it is showing its frame.
        if player.rate == 0 {
            return (true, first)
        }
        return ((now - first).seconds >= 0.05, first)
    }

    // MARK: - Shared player hand-off

    private func retireSharedPlayerForTransition() -> TransitionHeldPlayer? {
        guard let player = sharedPlayer else {
            return nil
        }
        let held = TransitionHeldPlayer(player: player, looper: sharedLooper, ownsPlayer: true) { [weak self] held in
            self?.transitionHeldPlayers.removeValue(forKey: ObjectIdentifier(held.player))
        }
        transitionHeldPlayers[ObjectIdentifier(player)] = held
        // Let the next installPlayerItem build a fresh player; the old one lives on
        // in `held` until the effect is over.
        sharedPlayer = nil
        sharedLooper = nil
        return held
    }

    private func holdPlayerForTransition(_ player: AVQueuePlayer) -> TransitionHeldPlayer {
        if let existing = transitionHeldPlayers[ObjectIdentifier(player)] {
            return existing
        }
        let held = TransitionHeldPlayer(player: player, looper: nil, ownsPlayer: false) { [weak self] held in
            self?.transitionHeldPlayers.removeValue(forKey: ObjectIdentifier(held.player))
        }
        transitionHeldPlayers[ObjectIdentifier(player)] = held
        return held
    }

    // MARK: - Effects that replace the whole view (video⇄web)

    private struct TransitionOverlay {
        let window: NSWindow
        let content: NSView
        let blackout: NSView
    }

    private func handOffContentViewsToOverlayWindows(wasWeb: Bool) -> [TransitionOverlay] {
        var overlays: [TransitionOverlay] = []
        for window in windows {
            guard let content = window.contentView else {
                continue
            }
            let overlay = NSWindow(
                contentRect: window.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            overlay.isReleasedWhenClosed = false
            overlay.backgroundColor = window.backgroundColor
            overlay.isOpaque = window.isOpaque
            overlay.hasShadow = false
            overlay.animationBehavior = .none
            overlay.ignoresMouseEvents = true
            applyWindowOptions(overlay)

            let container = NSView(frame: CGRect(origin: .zero, size: window.frame.size))
            container.wantsLayer = true
            window.contentView = nil
            content.frame = container.bounds
            content.autoresizingMask = [.width, .height]
            container.addSubview(content)
            let blackout = NSView(frame: container.bounds)
            blackout.wantsLayer = true
            blackout.layer?.backgroundColor = NSColor.black.cgColor
            blackout.alphaValue = 0
            blackout.autoresizingMask = [.width, .height]
            container.addSubview(blackout)
            overlay.contentView = container
            overlay.setFrame(window.frame, display: false)
            overlay.order(.above, relativeTo: window.windowNumber)
            overlays.append(TransitionOverlay(window: overlay, content: content, blackout: blackout))
            if let playerView = content as? PlayerView {
                presentationCacheByPlayerView.removeValue(forKey: ObjectIdentifier(playerView))
            }
        }
        // Detach the moved views so playback updates and the new page load go only
        // to the views the following rebuild creates.
        if wasWeb {
            webPlayerViews = []
        } else {
            playerViews = []
        }
        if wallpaperTransitionStyle == .dipToBlack {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = wallpaperTransitionDuration / 2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for overlay in overlays {
                    overlay.blackout.animator().alphaValue = 1
                }
            }
        }
        return overlays
    }

    private func finishOverlayTransitionWhenReady(
        _ overlays: [TransitionOverlay],
        targetIsWeb: Bool,
        deadline: Date,
        notBefore: Date? = nil,
        firstObservedTimes: [ObjectIdentifier: CMTime] = [:],
        completion: @escaping () -> Void
    ) {
        // The dip-to-black first half must complete before revealing.
        let notBefore = notBefore ?? Date().addingTimeInterval(
            wallpaperTransitionStyle == .dipToBlack ? wallpaperTransitionDuration / 2 : 0
        )
        var observedTimes = firstObservedTimes
        let isReady: Bool
        if targetIsWeb {
            isReady = !webPlayerViews.isEmpty
                && (webWallpaperLoadState == .loaded || webWallpaperLoadState == .failed)
        } else {
            isReady = !playerViews.isEmpty && playerViews.allSatisfy { view in
                let key = ObjectIdentifier(view)
                let progress = Self.newContentProgress(view.playerLayer, firstObservedTime: observedTimes[key])
                observedTimes[key] = progress.firstObservedTime
                return progress.isShowing
            }
        }
        guard (isReady || Date() >= deadline), Date() >= notBefore else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.finishOverlayTransitionWhenReady(
                    overlays, targetIsWeb: targetIsWeb, deadline: deadline, notBefore: notBefore,
                    firstObservedTimes: observedTimes, completion: completion
                )
            }
            return
        }
        if !isReady {
            AppLog.windowRefresh.error("transition: new wallpaper view not ready before timeout; finishing anyway")
        }
        let revealDuration = wallpaperTransitionStyle == .dipToBlack
            ? wallpaperTransitionDuration / 2
            : wallpaperTransitionDuration
        if wallpaperTransitionStyle == .dipToBlack {
            // Fully black: hide the old content so only black fades away.
            for overlay in overlays {
                overlay.content.isHidden = true
            }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = revealDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for overlay in overlays {
                overlay.window.animator().alphaValue = 0
            }
        } completionHandler: {
            MainActor.assumeIsolated {
                for overlay in overlays {
                    if let webView = overlay.content as? WebPlayerView {
                        webView.tearDown()
                    } else if let playerView = overlay.content as? PlayerView {
                        playerView.playerLayer.player = nil
                    }
                    overlay.window.contentView = nil
                    overlay.window.close()
                }
                completion()
            }
        }
    }

    // MARK: - Audio

    /// Cross-fade: old down while new comes up over the whole effect.
    /// Dip to black: old down in the first half, new up in the second half.
    private func startAudioTransition(from oldPlayer: AVPlayer?) {
        transitionAudioRampTimer?.invalidate()
        transitionAudioRampTimer = nil
        guard audioEnabled, let oldPlayer else {
            return
        }
        let duration = wallpaperTransitionDuration
        let isDip = wallpaperTransitionStyle == .dipToBlack
        let startVolume = oldPlayer.volume
        let started = Date()
        sharedPlayer?.volume = 0
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                let t = min(Date().timeIntervalSince(started) / duration, 1)
                let outProgress = Float(isDip ? min(t * 2, 1) : t)
                let inProgress = Float(isDip ? max(t * 2 - 1, 0) : t)
                oldPlayer.volume = startVolume * (1 - outProgress)
                // Reads audioVolume every tick so a volume change mid-fade is honored.
                self.sharedPlayer?.volume = self.audioVolume * inProgress
                if t >= 1 {
                    timer.invalidate()
                    self.transitionAudioRampTimer = nil
                    self.applyAudioSettings()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        transitionAudioRampTimer = timer
    }
}

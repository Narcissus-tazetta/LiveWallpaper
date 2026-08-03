import AppKit
import AVFoundation

/// 共有プレイヤーの再生/一時停止・フリーズフレーム・deep suspend への反映。
/// ディスプレイ固定(専用プレイヤー)側は [[WallpaperModel+DedicatedPlayers]] が
/// 独立に処理し、このファイルは残りの共有プレイヤー管轄の画面だけを扱う。
@MainActor
extension WallpaperModel {
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
}

import AVFoundation
import AppKit

@MainActor
extension WallpaperModel {
    /// Detaches the live player from every layer and pins the given still image
    /// as the layer contents, inside a single non-animated transaction. Shared by
    /// the normal freeze path and the deep-suspend "keep showing the cached still"
    /// path.
    func applyFreezeImageToAllViews(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in playerViews.indices {
            // オーバーライド画面のフリーズは applyDedicatedSuspensionState が
            // 専用プレイヤーの動画から生成した静止画で行う。
            guard isSharedPlayerDisplay(displayIDForWindow(at: index)) else {
                continue
            }
            let view = playerViews[index]
            view.playerLayer.player = nil
            view.playerLayer.contents = image
        }
        CATransaction.commit()
    }

    /// Arms the delayed release of heavy video resources. Cancels any prior timer
    /// so a burst of suspend-path calls just pushes the deadline out; the release
    /// only fires after the wallpaper has stayed fully covered for the full delay.
    func scheduleDeepSuspend() {
        guard !isDeepSuspended else {
            return
        }
        deepSuspendWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performDeepSuspend()
        }
        deepSuspendWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + deepSuspendDelay, execute: workItem)
    }

    func cancelDeepSuspend() {
        deepSuspendWorkItem?.cancel()
        deepSuspendWorkItem = nil
    }

    /// Fires after the wallpaper has been continuously fully covered for
    /// `deepSuspendDelay`. Re-validates that we're still fully suspended, then
    /// frees the AVPlayerItem/asset/decode buffers/looper via stopAllPlayers().
    /// The cached freeze image already applied to the layers is left untouched,
    /// so nothing goes black — the layers keep showing the still.
    private func performDeepSuspend() {
        deepSuspendWorkItem = nil
        guard !isWebWallpaperActive, !isDeepSuspended else {
            return
        }
        guard sharedPlayer != nil else {
            return
        }
        let displayCount = max(playerViews.count, windows.count)
        guard displayCount > 0 else {
            return
        }
        let displayIDs = (0 ..< displayCount).map { displayIDForWindow(at: $0) }
        let sharedDisplayIDs = sharedPlayerDisplayIDs(among: displayIDs)
        // 共有プレイヤーを使う画面が1つもなければ(全画面オーバーライド中)、
        // 共有プレイヤーはどこにも見えていないので解放してよい。
        // applySuspensionStateToPlayers 側の allSuspended 判定と揃えている。
        let sharedPlayerFullyHidden = sharedDisplayIDs.isEmpty
            || sharedDisplayIDs.allSatisfy({ suspendedDisplayIDs.contains($0) })
        guard sharedPlayerFullyHidden else {
            return
        }
        guard currentVideoPath != nil else {
            return
        }
        // Free heavy resources. stopAllPlayers() clears isDeepSuspended (it's the
        // general teardown reset), so set the flag afterward.
        stopAllPlayers()
        isDeepSuspended = true
    }

    // MARK: - Web壁紙

    /// Web壁紙版の deep suspend タイマー。動画側と同じく、被覆が続いた場合のみ
    /// 発火するよう呼ばれるたびに期限を延ばす。
    func scheduleWebDeepSuspend() {
        webDeepSuspendWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performWebDeepSuspend()
        }
        webDeepSuspendWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + webDeepSuspendDelay, execute: workItem)
    }

    func cancelWebDeepSuspend() {
        webDeepSuspendWorkItem?.cancel()
        webDeepSuspendWorkItem = nil
    }

    /// 全画面が被覆されたまま `webDeepSuspendDelay` が経過したら、各 WebPlayerView に
    /// ページ本体を解放させる。表示中のフリーズ画像はそのまま残るので見た目は変わらない。
    /// 復帰(再ロード)は WebPlayerView.setSuspended(false) 側が担当する。
    private func performWebDeepSuspend() {
        webDeepSuspendWorkItem = nil
        guard isWebWallpaperActive else {
            return
        }
        // タイマー発火までの間に被覆が解けていないか、ここで必ず取り直して確認する。
        let displayIDs = (0 ..< webPlayerViews.count).map { displayIDForWindow(at: $0) }
        guard !displayIDs.isEmpty,
              displayIDs.allSatisfy({ suspendedDisplayIDs.contains($0) })
        else {
            return
        }
        AppLog.suspend.debug(
            "web deep suspend: unloading views=\(self.webPlayerViews.count)"
        )
        for view in webPlayerViews {
            view.deepUnload()
        }
    }

    /// Rebuilds the freed video in the background while the freeze frame stays
    /// visible, then swaps to live playback at the frozen position once ready.
    func resumeFromDeepSuspend() {
        guard !isDeepResuming else {
            return
        }
        cancelDeepSuspend()
        isDeepSuspended = false
        // サスペンド中にスケジュール境界を跨いでいた場合、ガードで保留されていた適用を
        // ここで実行する。適用によって共有壁紙(動画/Web)が切り替わったら、そちらが
        // 既に再生を開始しているのでフリーズフレーム復帰は行わず終了する。
        if !scheduleRules.isEmpty {
            let previousPath = currentVideoPath
            evaluateSchedule(trigger: .deepSuspendResumed)
            if isWebWallpaperActive || currentVideoPath != previousPath {
                return
            }
        }
        guard let path = currentVideoPath else {
            return
        }
        let requestedTime = lastCapturedFreezeFrameTime
        // Build the item detached (attach: false) so the freeze image on the
        // layers is preserved until the fresh item is ready to render.
        // installPlayerItem calls stopAllPlayers (which resets isDeepResuming),
        // so mark the resume in flight only afterward.
        installPlayerItem(url: resolvedPlaybackURL(for: path), attach: false)
        isDeepResuming = true
        finishDeepResume(requestedTime: requestedTime, attemptsRemaining: 40)
    }

    private func finishDeepResume(requestedTime: CMTime?, attemptsRemaining: Int) {
        // Superseded by a new video, a re-cover, or a teardown — stop resuming.
        guard isDeepResuming else {
            return
        }
        guard attemptsRemaining > 0 else {
            // Never stay frozen forever: attach live even if readiness never came.
            attachLivePlayerAfterDeepResume()
            return
        }
        guard let player = sharedPlayer, let item = player.currentItem else {
            attachLivePlayerAfterDeepResume()
            return
        }
        guard item.status == .readyToPlay else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.finishDeepResume(
                    requestedTime: requestedTime,
                    attemptsRemaining: attemptsRemaining - 1
                )
            }
            return
        }

        guard let requestedTime, requestedTime.isNumeric, requestedTime.seconds > 0 else {
            attachLivePlayerAfterDeepResume()
            return
        }
        let durationSeconds = item.duration.seconds
        let safeSeconds: Double
        if durationSeconds.isFinite, durationSeconds > 0.05 {
            safeSeconds = min(max(requestedTime.seconds, 0), durationSeconds - 0.05)
        } else {
            safeSeconds = max(requestedTime.seconds, 0)
        }
        let safeTime = CMTime(
            seconds: safeSeconds,
            preferredTimescale: requestedTime.timescale > 0 ? requestedTime.timescale : 600
        )
        player.seek(to: safeTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                self?.attachLivePlayerAfterDeepResume()
            }
        }
    }

    /// Swaps the freeze frame for the now-ready live player. Delegates to
    /// applySuspensionStateToPlayers(), which — with isDeepSuspended already
    /// cleared — clears each layer's still contents, re-attaches the player, and
    /// resumes playback; and if coverage changed again mid-rebuild (user
    /// re-entered fullscreen), it correctly re-freezes instead.
    private func attachLivePlayerAfterDeepResume() {
        // Clear the in-flight flag first so the delegated call is allowed to
        // actually attach the live player (rather than being held on the freeze
        // frame by the isDeepResuming guard).
        isDeepResuming = false
        applySuspensionStateToPlayers()
    }
}

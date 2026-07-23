import AVFoundation
import Foundation

@MainActor
extension WallpaperModel {
    /// Resolves the URL that should actually be decoded for `path` right now: the
    /// lightweight proxy if one is already cached and lightweight mode is on,
    /// otherwise the original file. This check is synchronous and never triggers
    /// generation itself — see `ensureLightweightProxyIfNeeded(for:)` for that.
    func resolvedPlaybackURL(for path: String) -> URL {
        let originalURL = URL(fileURLWithPath: path)
        guard lightweightMode, let proxyURL = lightweightProxyCache.cachedProxyURL(for: path) else {
            return originalURL
        }
        return proxyURL
    }

    /// The single entry point every video-selection path should call instead of
    /// building a URL and calling `playVideo(url:)` directly, so that lightweight
    /// mode's proxy-or-original resolution stays consistent everywhere.
    func playRegisteredVideo(path: String) {
        playVideo(url: resolvedPlaybackURL(for: path))
        ensureLightweightProxyIfNeeded(for: path)
    }

    private func ensureLightweightProxyIfNeeded(for path: String) {
        guard lightweightMode else {
            lightweightProxyCache.cancelActiveGeneration()
            lightweightProxyState = .idle
            return
        }
        if lightweightProxyCache.cachedProxyURL(for: path) != nil {
            lightweightProxyState = .ready
            return
        }
        lightweightProxyState = .generating
        lightweightProxyCache.generateProxyIfNeeded(for: path) { [weak self] result in
            // Re-validate both that this is still the current video AND that
            // lightweight mode is still on — a generation started before the
            // user switched video/toggled the mode off may resolve after either
            // has already changed, and must not resurrect stale UI state.
            guard let self, self.currentVideoPath == path, self.lightweightMode else {
                return
            }
            switch result {
            case .ready(let proxyURL):
                self.lightweightProxyState = .ready
                // If the wallpaper is deep-suspended, the video is torn down and
                // not playing — don't rebuild it now just to swap to the proxy.
                // Resume from deep suspend re-resolves the URL (picking up this
                // freshly-cached proxy) via resolvedPlaybackURL, so the swap
                // happens naturally when the wallpaper comes back.
                guard !self.isDeepSuspended else {
                    return
                }
                let resumeTime = self.sharedPlayer?.currentTime() ?? .zero
                self.reinstallPlayerItemContinuingPlayback(url: proxyURL, attach: true)
                self.restorePlaybackPositionAfterProxySwap(resumeTime)
            case .passthrough:
                self.lightweightProxyState = .ready
            case .cancelled:
                break
            case .failed:
                self.lightweightProxyState = .failed
            }
        }
    }

    private func restorePlaybackPositionAfterProxySwap(_ requestedTime: CMTime) {
        guard requestedTime.isNumeric else {
            return
        }
        let seconds = requestedTime.seconds
        guard seconds.isFinite, seconds > 0 else {
            return
        }
        tryRestorePlaybackPositionAfterProxySwap(
            requestedTime: requestedTime,
            attemptsRemaining: 12
        )
    }

    private func tryRestorePlaybackPositionAfterProxySwap(
        requestedTime: CMTime,
        attemptsRemaining: Int
    ) {
        guard attemptsRemaining > 0 else {
            return
        }
        guard let player = sharedPlayer,
              let item = player.currentItem
        else {
            return
        }

        guard item.status == .readyToPlay else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.tryRestorePlaybackPositionAfterProxySwap(
                    requestedTime: requestedTime,
                    attemptsRemaining: attemptsRemaining - 1
                )
            }
            return
        }

        // トリム編集のループ区間の外を指していたら復元シークを見送る(区間外へ
        // seek すると AVPlayerLooper のループへ戻れずそのフレームで止まる)。
        guard let safeSeconds = clampedResumeSeconds(
            requestedTime.seconds,
            path: currentVideoPath,
            itemDurationSeconds: item.duration.seconds
        ) else {
            return
        }
        let safeTime = CMTime(
            seconds: safeSeconds,
            preferredTimescale: requestedTime.timescale > 0 ? requestedTime.timescale : 600
        )
        player.seek(to: safeTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

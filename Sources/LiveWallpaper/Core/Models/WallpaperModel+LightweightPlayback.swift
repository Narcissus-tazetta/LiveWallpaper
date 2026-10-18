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
        guard effectiveLightweightMode, let proxyURL = lightweightProxyCache.cachedProxyURL(for: path) else {
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

    func ensureLightweightProxyIfNeeded(for path: String) {
        guard effectiveLightweightMode else {
            resetLightweightProxyRequests()
            return
        }
        guard lightweightProxyRequests[path] == nil else { return }
        if lightweightProxyCache.cachedProxyURL(for: path) != nil {
            lightweightProxyStatesByPath[path] = .ready
            refreshLightweightProxyState()
            return
        }
        let requestID = UUID()
        lightweightProxyRequests[path] = requestID
        lightweightProxyStatesByPath[path] = .generating
        refreshLightweightProxyState()
        lightweightProxyCache.generateProxyIfNeeded(for: path) { [weak self] result in
            guard let self, self.lightweightProxyRequests[path] == requestID else { return }
            self.lightweightProxyRequests[path] = nil
            guard self.effectiveLightweightMode else { return }
            switch result {
            case .ready(let proxyURL):
                self.lightweightProxyStatesByPath[path] = .ready
                if self.currentVideoPath == path, !self.isDeepSuspended {
                    let resumeTime = self.sharedPlayer?.currentTime() ?? .zero
                    self.reinstallPlayerItemContinuingPlayback(url: proxyURL, attach: true)
                    self.restorePlaybackPositionAfterProxySwap(resumeTime)
                }
                for (screenID, activePath) in self.activeDedicatedPathByScreenID
                    where activePath == path
                {
                    self.replaceDedicatedPlaybackURL(proxyURL, screenID: screenID, path: path)
                }
            case .passthrough:
                self.lightweightProxyStatesByPath[path] = .ready
            case .cancelled:
                self.lightweightProxyStatesByPath[path] = .idle
            case .failed:
                self.lightweightProxyStatesByPath[path] = .failed
            }
            self.refreshLightweightProxyState()
        }
    }

    func resetLightweightProxyRequests() {
        lightweightProxyRequests = [:]
        lightweightProxyStatesByPath = [:]
        lightweightProxyCache.cancelActiveGeneration()
        lightweightProxyState = .idle
    }

    func refreshLightweightProxyState() {
        let paths = Set(activeDedicatedPathByScreenID.values)
            .union(currentVideoPath.map { [$0] } ?? [])
        lightweightProxyCache.retainGenerationRequests(for: paths)
        lightweightProxyStatesByPath = lightweightProxyStatesByPath
            .filter { paths.contains($0.key) }
        let states = lightweightProxyStatesByPath.values
        lightweightProxyState = !effectiveLightweightMode ? .idle
            : states.contains(.failed) ? .failed
            : states.contains(.generating) ? .generating
            : states.contains(.ready) ? .ready : .idle
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

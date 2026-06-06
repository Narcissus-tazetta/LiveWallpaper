import Foundation

@MainActor
extension WallpaperModel {
    enum PlaybackEndBehavior {
        case loopCurrent
        case advancePlaylist
        case playOnce
    }

    var canPinCurrentVideo: Bool {
        playlistPlaybackEnabled && registeredVideoPaths.count > 1
    }

    var isVideoLoopSettingEnabled: Bool {
        registeredVideoPaths.count > 1 && !playlistPlaybackEnabled
    }

    var effectiveVideoLoopEnabled: Bool {
        isVideoLoopSettingEnabled ? videoLoopEnabled : true
    }

    func playbackEndBehavior() -> PlaybackEndBehavior {
        if registeredVideoPaths.count <= 1 {
            return .loopCurrent
        }
        if pinCurrentVideo {
            return .loopCurrent
        }
        if playlistPlaybackEnabled {
            return .advancePlaylist
        }
        if videoLoopEnabled {
            return .loopCurrent
        }
        return .playOnce
    }

    func shouldUsePlaybackLooper() -> Bool {
        playbackEndBehavior() == .loopCurrent
    }

    func normalizePlaybackConstraints() {
        if pinCurrentVideo, !canPinCurrentVideo {
            pinCurrentVideo = false
        }
        if pinCurrentVideo, shufflePlaybackEnabled {
            shufflePlaybackEnabled = false
            UserDefaults.standard.set(false, forKey: "shufflePlaybackEnabled")
        }
    }

    func clearPinCurrentVideo() {
        guard pinCurrentVideo else {
            return
        }
        pinCurrentVideo = false
    }
}

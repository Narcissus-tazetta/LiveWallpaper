import Foundation

@MainActor
extension WallpaperModel {
    enum PlaybackEndBehavior {
        case loopCurrent
        case advancePlaylist
        case playOnce
    }

    var canPinCurrentVideo: Bool {
        playlistPlaybackEnabled && registeredPlaybackEntries.count > 1
    }

    var isVideoLoopSettingEnabled: Bool {
        registeredPlaybackEntries.count > 1 && !playlistPlaybackEnabled
    }

    var effectiveVideoLoopEnabled: Bool {
        isVideoLoopSettingEnabled ? videoLoopEnabled : true
    }

    /// 動画が自然終了したときにループするか、次のエントリ(動画・Web壁紙どちらも
    /// あり得る)へ進むかの判定。キューの総数で見る必要があるため
    /// registeredVideoPaths ではなく registeredPlaybackEntries を使う。
    func playbackEndBehavior() -> PlaybackEndBehavior {
        if registeredPlaybackEntries.count <= 1 {
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
            // 自動的な pin 解除でも共有スコープのスケジュールガードが外れるため再評価する。
            // (evaluateSchedule は再入ガードで多重実行を防いでいる。)
            evaluateSchedule(trigger: .playbackConstraintChanged)
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

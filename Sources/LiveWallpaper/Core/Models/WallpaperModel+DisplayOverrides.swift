import AppKit
import AVFoundation

/// ディスプレイごとの壁紙固定(オーバーライド)。
/// 指定した画面だけ専用プレイヤーで別の動画をループ再生し、それ以外の画面は
/// 従来どおり共有プレイヤー(プレイリスト再生)を使う。オーバーライドが1つも
/// なければ、既存の再生経路には一切手を触れない。
///
/// v1 の割り切り:
/// - 専用プレイヤーは常に消音(音声は共有プレイヤーのみ)・常にループ。
/// - deep suspend(リソース解放)は共有プレイヤーのみ。専用プレイヤーは
///   全面被覆時に一時停止+フリーズフレーム表示まで。
@MainActor
extension WallpaperModel {
    func videoOverride(forScreenID screenID: String) -> String? {
        videoOverrideByScreenID[screenID]
    }

    /// この画面が共有プレイヤー(ディスプレイ固定なし)の管轄かどうか。
    /// 「この画面は誰が担当するか」の唯一の判定はここに集約し、ウィンドウ構築・
    /// 被覆判定・deep suspend・自動切替など全ての呼び出し元がこれを経由する。
    /// 個別に `videoOverrideByScreenID[...] == nil` を書くと、判定基準がずれた
    /// ときに一部の呼び出し元だけ更新漏れが起きるため避ける。
    func isSharedPlayerDisplay(_ screenID: String) -> Bool {
        videoOverrideByScreenID[screenID] == nil
    }

    /// 指定した画面IDのうち、共有プレイヤーが担当するものだけを返す。
    func sharedPlayerDisplayIDs(among displayIDs: some Sequence<String>) -> [String] {
        displayIDs.filter(isSharedPlayerDisplay)
    }

    func setVideoOverride(path: String?, forScreenID screenID: String) {
        if let path {
            guard FileManager.default.fileExists(atPath: path) else {
                return
            }
            guard videoOverrideByScreenID[screenID] != path else {
                return
            }
            videoOverrideByScreenID[screenID] = path
        } else {
            guard videoOverrideByScreenID[screenID] != nil else {
                return
            }
            videoOverrideByScreenID.removeValue(forKey: screenID)
            stopDedicatedPlayer(forScreenID: screenID)
            if suspendDisabledDisplayIDs.remove(screenID) != nil {
                UserDefaults.standard.set(
                    Array(suspendDisabledDisplayIDs),
                    forKey: "suspendDisabledDisplayIDs"
                )
            }
        }
        persistVideoOverrides()
        // 共有側の attach ループとオーバーライド側の処理が両方ここで走り、
        // 対象画面のビューに期待されるプレイヤーが付け替わる。
        applySuspensionStateToPlayers()
    }

    /// 指定した動画へのオーバーライドをすべて解除する(登録削除時の後始末)。
    func clearVideoOverrides(forPath path: String) {
        for (screenID, overridePath) in videoOverrideByScreenID where overridePath == path {
            setVideoOverride(path: nil, forScreenID: screenID)
        }
    }

    // MARK: - 画面ごとのプレイリスト割り当て

    func screenPlaylistID(forScreenID screenID: String) -> UUID? {
        screenPlaylistByScreenID[screenID]
    }

    /// 画面が対象とする動画パス一覧。プレイリスト未設定、または該当プレイリストが
    /// 既に削除されている場合はライブラリ全体にフォールバックする。
    func screenVideoPaths(forScreenID screenID: String) -> [String] {
        if let playlistID = screenPlaylistByScreenID[screenID],
           let playlist = playlists.first(where: { $0.id == playlistID })
        {
            return playlist.videoPaths
        }
        return libraryVideoPaths
    }

    /// - Parameter autoAssignFirstVideo: 割り当て動画が新しいスコープに含まれない、
    ///   またはまだ何も割り当てられていないとき、先頭の動画を自動的に割り当てるか。
    ///   設定画面でユーザーがプレイリストを選ぶ通常操作では true(利便性のため)。
    ///   設定インポートのような非対話的な適用では false にし、ファイルが存在しない
    ///   などの理由で動画側の適用が失敗したときにローカルの別動画が勝手に選ばれる
    ///   (ユーザーが選んでいない動画が割り当てられる)事故を防ぐ。
    func setScreenPlaylist(
        _ playlistID: UUID?,
        forScreenID screenID: String,
        autoAssignFirstVideo: Bool = true
    ) {
        if let playlistID {
            guard screenPlaylistByScreenID[screenID] != playlistID else {
                return
            }
            screenPlaylistByScreenID[screenID] = playlistID
        } else {
            guard screenPlaylistByScreenID[screenID] != nil else {
                return
            }
            screenPlaylistByScreenID.removeValue(forKey: screenID)
        }
        persistScreenPlaylists()

        guard autoAssignFirstVideo else {
            return
        }
        // 現在の割り当て動画が新しいスコープに含まれなければ、先頭の動画へ切り替える。
        let scoped = screenVideoPaths(forScreenID: screenID)
        if let current = videoOverrideByScreenID[screenID], !scoped.contains(current) {
            setVideoOverride(path: scoped.first, forScreenID: screenID)
        } else if videoOverrideByScreenID[screenID] == nil {
            setVideoOverride(path: scoped.first, forScreenID: screenID)
        }
    }

    private func persistScreenPlaylists() {
        let raw = screenPlaylistByScreenID.mapValues(\.uuidString)
        UserDefaults.standard.set(raw, forKey: "screenPlaylistByScreenID")
    }

    func restoreScreenPlaylists() {
        guard let saved = UserDefaults.standard.dictionary(
            forKey: "screenPlaylistByScreenID"
        ) as? [String: String] else {
            return
        }
        var restored: [String: UUID] = [:]
        for (screenID, rawUUID) in saved {
            if let uuid = UUID(uuidString: rawUUID) {
                restored[screenID] = uuid
            }
        }
        screenPlaylistByScreenID = restored
    }

    /// 画面専用プレイリスト内で次/前の動画へ進める。
    func playNextVideo(forScreenID screenID: String) {
        advanceScreenVideo(forScreenID: screenID, forward: true)
    }

    func playPreviousVideo(forScreenID screenID: String) {
        advanceScreenVideo(forScreenID: screenID, forward: false)
    }

    private func advanceScreenVideo(forScreenID screenID: String, forward: Bool) {
        let paths = screenVideoPaths(forScreenID: screenID)
        guard !paths.isEmpty else {
            return
        }
        guard paths.count > 1 else {
            setVideoOverride(path: paths[0], forScreenID: screenID)
            return
        }
        let currentIndex = videoOverrideByScreenID[screenID].flatMap { paths.firstIndex(of: $0) }
        let baseIndex = currentIndex ?? (forward ? -1 : 0)
        let nextIndex = forward
            ? (baseIndex + 1) % paths.count
            : (baseIndex - 1 + paths.count) % paths.count
        setVideoOverride(path: paths[nextIndex], forScreenID: screenID)
    }

    // MARK: - 自動停止の除外

    func isSuspendDisabled(forScreenID screenID: String) -> Bool {
        suspendDisabledDisplayIDs.contains(screenID)
    }

    func setSuspendDisabled(_ disabled: Bool, forScreenID screenID: String) {
        if disabled {
            guard suspendDisabledDisplayIDs.insert(screenID).inserted else {
                return
            }
        } else {
            guard suspendDisabledDisplayIDs.remove(screenID) != nil else {
                return
            }
        }
        UserDefaults.standard.set(
            Array(suspendDisabledDisplayIDs),
            forKey: "suspendDisabledDisplayIDs"
        )
        evaluateForegroundCoverageState()
    }

    func restoreVideoOverrides() {
        guard
            let saved = UserDefaults.standard.dictionary(forKey: "videoOverrideByScreenID")
            as? [String: String]
        else {
            return
        }
        videoOverrideByScreenID = saved.filter { FileManager.default.fileExists(atPath: $0.value) }
    }

    private func persistVideoOverrides() {
        UserDefaults.standard.set(videoOverrideByScreenID, forKey: "videoOverrideByScreenID")
    }

    // MARK: - 専用プレイヤーの管理

    func ensureDedicatedPlayer(forScreenID screenID: String, path: String) -> AVQueuePlayer {
        if let existing = dedicatedPlayersByScreenID[screenID],
           dedicatedPlayerPathByScreenID[screenID] == path
        {
            return existing
        }
        stopDedicatedPlayer(forScreenID: screenID)

        // 音声は共有プレイヤー(メインの壁紙)のみ。専用プレイヤーは常に消音。
        let player = createConfiguredPlayer(muted: true)

        let profile = resolvePlaybackProfile()
        let item = AVPlayerItem(asset: AVURLAsset(url: resolvedPlaybackURL(for: path)))
        item.preferredPeakBitRate = profile.bitRate
        item.preferredForwardBufferDuration = profile.buffer
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        dedicatedLoopersByScreenID[screenID] = AVPlayerLooper(player: player, templateItem: item)
        dedicatedPlayersByScreenID[screenID] = player
        dedicatedPlayerPathByScreenID[screenID] = path
        return player
    }

    func stopDedicatedPlayer(forScreenID screenID: String) {
        // AVPlayerLooper は最後の強参照を落とす前に明示的に無効化する
        // (stopAllPlayers と同じ理由。放置すると古いアイテムが残留し得る)。
        if let looper = dedicatedLoopersByScreenID.removeValue(forKey: screenID) {
            looper.disableLooping()
        }
        if let player = dedicatedPlayersByScreenID.removeValue(forKey: screenID) {
            player.pause()
            player.removeAllItems()
        }
        dedicatedPlayerPathByScreenID.removeValue(forKey: screenID)
        dedicatedFreezeFrameByScreenID.removeValue(forKey: screenID)
    }

    func stopAllDedicatedPlayers() {
        for screenID in Array(dedicatedPlayersByScreenID.keys) {
            stopDedicatedPlayer(forScreenID: screenID)
        }
    }

    /// 接続されていない画面の専用プレイヤーを止める(画面切断時のリソース解放)。
    /// オーバーライド設定自体は保持され、再接続時に再生成される。
    func pruneDedicatedPlayers(activeDisplayIDs: Set<String>) {
        for screenID in Array(dedicatedPlayersByScreenID.keys)
            where !activeDisplayIDs.contains(screenID)
        {
            stopDedicatedPlayer(forScreenID: screenID)
        }
    }

    // MARK: - 再生/停止の反映

    /// オーバーライド画面の専用プレイヤーの再生/停止をビューへ反映する。
    /// 共有プレイヤー側のフリーズフレーム・deep suspend 機構とは独立して動く。
    func applyDedicatedSuspensionState() {
        guard !videoOverrideByScreenID.isEmpty, !isWebWallpaperActive else {
            return
        }
        var viewsAwaitingFirstFrame: [PlayerView] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in playerViews.indices {
            let displayID = displayIDForWindow(at: index)
            guard let path = videoOverrideByScreenID[displayID] else {
                continue
            }
            let layer = playerViews[index].playerLayer
            if suspendedDisplayIDs.contains(displayID) {
                let player = dedicatedPlayersByScreenID[displayID]
                // プレイヤー未生成(停止中に起動・画面接続・割り当てされた場合)でも
                // 静止画は必ず貼る。何も貼らないとその画面だけ黒いままになる。
                // 停止中に別の動画へ割り当て直された場合(キャッシュされた静止画の
                // パスが新しい割り当てと食い違う)も、古い動画の静止画のままに
                // ならないよう再生成する。
                let freezeIsStale = dedicatedFreezeFrameByScreenID[displayID]?.path != path
                if layer.player != nil || layer.contents == nil || freezeIsStale {
                    // 一時停止した AVPlayerLayer は背景色に落ちることがあるため、
                    // 共有側と同じくプレイヤーを外して静止画を貼る。
                    let freeze = dedicatedFreezeFrame(
                        forScreenID: displayID,
                        path: path,
                        time: player?.currentTime() ?? .zero
                    )
                    layer.player = nil
                    layer.contents = freeze
                }
                player?.pause()
                AppLog.suspend.debug(
                    "dedicated suspend display=\(displayID, privacy: .public) hasPlayer=\(player != nil)"
                )
            } else {
                let player = ensureDedicatedPlayer(forScreenID: displayID, path: path)
                if layer.player !== player {
                    if layer.contents != nil, !layer.isReadyForDisplay {
                        // フリーズ画像を貼ったまま初回描画を待つ(黒フラッシュ防止)。
                        layer.player = player
                        viewsAwaitingFirstFrame.append(playerViews[index])
                    } else {
                        layer.contents = nil
                        layer.player = player
                    }
                }
                player.play()
                AppLog.suspend.debug(
                    "dedicated play display=\(displayID, privacy: .public) rate=\(player.rate)"
                )
            }
        }
        CATransaction.commit()
        clearFreezeStillWhenReady(viewsAwaitingFirstFrame, attemptsRemaining: 30)
    }

    /// 全面被覆で専用プレイヤーを止めるときのフリーズフレーム。
    /// (path, time) が前回と同じなら再デコードを省く。
    private func dedicatedFreezeFrame(
        forScreenID screenID: String,
        path: String,
        time: CMTime
    ) -> CGImage? {
        if let cached = dedicatedFreezeFrameByScreenID[screenID],
           cached.path == path, cached.time == time
        {
            return cached.image
        }
        let image = VideoFrameCapture.capture(path: path, time: time)
        dedicatedFreezeFrameByScreenID[screenID] = (path: path, time: time, image: image)
        return image
    }
}

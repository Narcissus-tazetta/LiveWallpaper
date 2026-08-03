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
    /// この動画が、今つながっている画面のどれかに割り当てられているか。
    /// 壁紙一覧のバッジ用。videoOverrideByScreenID を直に見ると、外した画面宛ての
    /// 残った割り当てでもバッジが点く(その割り当ての解除手段はカードのメニュー側に
    /// 残してあるので、ここで見せないだけなら情報は失われない)。
    func hasLiveDisplayOverride(forPath path: String) -> Bool {
        let connected = Set(availableDisplayScreens().map(\.id))
        return videoOverrideByScreenID.contains { screenID, assigned in
            assigned == path && connected.contains(screenID)
        }
    }

    func videoOverride(forScreenID screenID: String) -> String? {
        videoOverrideByScreenID[screenID]
    }

    /// この画面が共有プレイヤー(ディスプレイ固定なし)の管轄かどうか。
    /// 「この画面は誰が担当するか」の唯一の判定はここに集約し、ウィンドウ構築・
    /// 被覆判定・deep suspend・自動切替など全ての呼び出し元がこれを経由する。
    /// 個別に `videoOverrideByScreenID[...] == nil` を書くと、判定基準がずれた
    /// ときに一部の呼び出し元だけ更新漏れが起きるため避ける。
    /// Space別壁紙(resolvedOverridePath 内で優先解決)もここを通じて全呼び出し元に
    /// 反映される。
    func isSharedPlayerDisplay(_ screenID: String) -> Bool {
        resolvedOverridePath(forScreenID: screenID) == nil
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
            evictAllDedicatedSlots(forScreenID: screenID)
            if suspendDisabledDisplayIDs.remove(screenID) != nil {
                UserDefaults.standard.set(
                    Array(suspendDisabledDisplayIDs),
                    forKey: PrefsKey.suspendDisabledDisplayIDs
                )
            }
        }
        persistVideoOverrides()
        // 共有側の attach ループとオーバーライド側の処理が両方ここで走り、
        // 対象画面のビューに期待されるプレイヤーが付け替わる。
        applySuspensionStateToPlayers()
        scheduleDedicatedWarmWindowReconciliation()
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
        UserDefaults.standard.set(raw, forKey: PrefsKey.screenPlaylistByScreenID)
    }

    func restoreScreenPlaylists() {
        guard let saved = UserDefaults.standard.dictionary(
            forKey: PrefsKey.screenPlaylistByScreenID
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
            forKey: PrefsKey.suspendDisabledDisplayIDs
        )
        evaluateForegroundCoverageState()
    }

    func restoreVideoOverrides() {
        guard
            let saved = UserDefaults.standard.dictionary(forKey: PrefsKey.videoOverrideByScreenID)
            as? [String: String]
        else {
            return
        }
        // 実在確認は verifyRestoredVideoPaths() が起動後にまとめて行う(restoreState 参照)。
        videoOverrideByScreenID = saved
    }

    private func persistVideoOverrides() {
        UserDefaults.standard.set(videoOverrideByScreenID, forKey: PrefsKey.videoOverrideByScreenID)
    }
}

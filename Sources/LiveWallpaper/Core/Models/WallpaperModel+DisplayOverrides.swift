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
                    forKey: "suspendDisabledDisplayIDs"
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
        // 実在確認は verifyRestoredVideoPaths() が起動後にまとめて行う(restoreState 参照)。
        videoOverrideByScreenID = saved
    }

    private func persistVideoOverrides() {
        UserDefaults.standard.set(videoOverrideByScreenID, forKey: "videoOverrideByScreenID")
    }

    // MARK: - 専用プレイヤーの管理

    enum DedicatedPlayerRole {
        case active
        case warmStandby
    }

    /// 指定パスの専用プレイヤーを用意する。既に同じパスのスロットがあれば再利用する。
    /// - Parameter isActive: true なら「現在」スロットとして即座にアタッチ対象になる
    ///   (通常のビットレート/バッファ)。false なら隣接ウォームキャッシュとしての温存生成
    ///   (バッファのみ縮小し、即座には再生・アタッチしない)。
    @discardableResult
    func ensureDedicatedSlot(
        forScreenID screenID: String,
        path: String,
        isActive: Bool
    ) -> AVQueuePlayer {
        if let existing = dedicatedSlotsByScreenID[screenID]?[path] {
            guard isActive, activeDedicatedPathByScreenID[screenID] != path else {
                if isActive {
                    demotePreviousActiveSlotIfNeeded(forScreenID: screenID, newActivePath: path)
                    activeDedicatedPathByScreenID[screenID] = path
                }
                return existing.player
            }
            // 温存(warmStandby)状態から現在スロットへ昇格する場合。AVPlayerLooper は
            // templateItem を外部に公開せず、ループのたびに内部で保持したコピーを
            // 挿入するため、既存アイテムのプロパティを書き換えるだけではループ後に
            // 縮小したバッファ/ビットレートへ静かに戻ってしまう。evictDedicatedSlot で
            // 再生位置を記憶してから作り直し、通常の復元シーク経路でその位置へ戻す。
            evictDedicatedSlot(forScreenID: screenID, path: path)
            return createDedicatedSlot(forScreenID: screenID, path: path, isActive: true)
        }
        return createDedicatedSlot(forScreenID: screenID, path: path, isActive: isActive)
    }

    private func createDedicatedSlot(
        forScreenID screenID: String,
        path: String,
        isActive: Bool
    ) -> AVQueuePlayer {
        // 音声は共有プレイヤー(メインの壁紙)のみ。専用プレイヤーは常に消音。
        let player = createConfiguredPlayer(muted: true)

        let profile = resolvePlaybackProfile(role: isActive ? .active : .warmStandby)
        let item = AVPlayerItem(asset: AVURLAsset(url: resolvedPlaybackURL(for: path)))
        item.preferredPeakBitRate = profile.bitRate
        item.preferredForwardBufferDuration = profile.buffer
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        let looper = makeWallpaperLooper(player: player, templateItem: item, path: path)
        // isActive: false (温存/ウォームスロット)でもここでは play() しない。常時再生
        // しておけばアクティブ昇格時のデコード開始待ちが無くなり体感ラグはほぼ消えるが、
        // 画面に出ていない動画をディスプレイ数×隣接数ぶん常時デコードし続けることになり
        // CPU/バッテリー消費が増える。Space別壁紙は隣接Space切替時の遅延源にもなるため
        // 一度検討したが、コスト対効果が悪いとして見送り、一時停止のまま温存する現状の
        // 挙動(切替時に多少のデコード開始ラグが乗る)を妥協点として受け入れている。

        var slots = dedicatedSlotsByScreenID[screenID] ?? [:]
        slots[path] = DedicatedPlayerSlot(player: player, looper: looper)
        dedicatedSlotsByScreenID[screenID] = slots
        if isActive {
            demotePreviousActiveSlotIfNeeded(forScreenID: screenID, newActivePath: path)
            activeDedicatedPathByScreenID[screenID] = path
        }

        if dedicatedPlaybackContinuityEnabled,
           let remembered = dedicatedResumeTimeByKey[ScreenPathKey(screenID: screenID, path: path)]
        {
            AppLog.continuity.debug(
                "restore requested display=\(screenID, privacy: .public) seconds=\(remembered.seconds) path=\((path as NSString).lastPathComponent, privacy: .public)"
            )
            seekDedicatedSlot(player: player, screenID: screenID, path: path)
        } else {
            AppLog.continuity.debug(
                "no saved position display=\(screenID, privacy: .public) path=\((path as NSString).lastPathComponent, privacy: .public)"
            )
        }
        return player
    }

    func ensureDedicatedPlayer(forScreenID screenID: String, path: String) -> AVQueuePlayer {
        ensureDedicatedSlot(forScreenID: screenID, path: path, isActive: true)
    }

    /// 「現在」スロットが別のパスへ切り替わるとき、旧「現在」スロットが隣接
    /// ウォームキャッシュとして残る場合は一時停止する。これをしないと、旧スロットは
    /// 再生されたまま画面から外れるだけになり、表示されていない動画をデコードし
    /// 続けて CPU/バッテリーを浪費する。
    private func demotePreviousActiveSlotIfNeeded(forScreenID screenID: String, newActivePath: String) {
        guard let previousPath = activeDedicatedPathByScreenID[screenID],
              previousPath != newActivePath,
              let previousSlot = dedicatedSlotsByScreenID[screenID]?[previousPath]
        else {
            return
        }
        previousSlot.player.pause()
    }

    /// 指定スロットを破棄する。破棄直前に再生位置を記憶する(ウォームキャッシュの
    /// 有無に関わらず、後で同じ画面・同じ動画に戻ってきたときゼロ秒からにしないため)。
    func evictDedicatedSlot(forScreenID screenID: String, path: String) {
        guard var slots = dedicatedSlotsByScreenID[screenID], let slot = slots[path] else {
            return
        }
        let evictTime = slot.player.currentTime()
        AppLog.continuity.debug(
            "evict display=\(screenID, privacy: .public) seconds=\(evictTime.isNumeric ? evictTime.seconds : -1) path=\((path as NSString).lastPathComponent, privacy: .public)"
        )
        if dedicatedPlaybackContinuityEnabled {
            recordResumeTime(evictTime, forScreenID: screenID, path: path)
        }
        slot.looper.disableLooping()
        slot.player.pause()
        slot.player.removeAllItems()
        slots.removeValue(forKey: path)
        dedicatedSlotsByScreenID[screenID] = slots.isEmpty ? nil : slots
        if activeDedicatedPathByScreenID[screenID] == path {
            activeDedicatedPathByScreenID.removeValue(forKey: screenID)
            dedicatedFreezeFrameByScreenID.removeValue(forKey: screenID)
        }
    }

    /// トリム/ループ編集が保存されたときに呼ぶ。この動画を専用プレイヤーで
    /// 表示している画面があれば、そのスロットだけ破棄する。破棄後は既存の
    /// ウォームウィンドウ調整(scheduleDedicatedWarmWindowReconciliation)が
    /// 通常の再構築経路(createDedicatedSlot、編集後の内容を反映する)で
    /// 作り直す。
    func refreshDedicatedSlotsIfNeeded(for path: String) {
        var affected = false
        for screenID in Array(dedicatedSlotsByScreenID.keys) {
            guard dedicatedSlotsByScreenID[screenID]?[path] != nil else {
                continue
            }
            evictDedicatedSlot(forScreenID: screenID, path: path)
            affected = true
        }
        if affected {
            scheduleDedicatedWarmWindowReconciliation()
        }
    }

    /// 画面の全スロット(現在+温存)を破棄する。
    func evictAllDedicatedSlots(forScreenID screenID: String) {
        for path in Array((dedicatedSlotsByScreenID[screenID] ?? [:]).keys) {
            evictDedicatedSlot(forScreenID: screenID, path: path)
        }
    }

    /// 「現在」以外の温存スロットだけを破棄する(安全弁が働いたときに使う)。
    func evictDedicatedSlotsOtherThanActive(forScreenID screenID: String) {
        let activePath = activeDedicatedPathByScreenID[screenID]
        for path in Array((dedicatedSlotsByScreenID[screenID] ?? [:]).keys) where path != activePath {
            evictDedicatedSlot(forScreenID: screenID, path: path)
        }
    }

    func stopDedicatedPlayer(forScreenID screenID: String) {
        evictAllDedicatedSlots(forScreenID: screenID)
    }

    func stopAllDedicatedPlayers() {
        for screenID in Array(dedicatedSlotsByScreenID.keys) {
            evictAllDedicatedSlots(forScreenID: screenID)
        }
    }

    /// 接続されていない画面の専用プレイヤーを止める(画面切断時のリソース解放)。
    /// オーバーライド設定自体は保持され、再接続時に再生成される。
    func pruneDedicatedPlayers(activeDisplayIDs: Set<String>) {
        for screenID in Array(dedicatedSlotsByScreenID.keys)
            where !activeDisplayIDs.contains(screenID)
        {
            evictAllDedicatedSlots(forScreenID: screenID)
        }
    }

    func allDedicatedSlotEntries() -> [(screenID: String, path: String, slot: DedicatedPlayerSlot, isActive: Bool)] {
        dedicatedSlotsByScreenID.flatMap { screenID, slots in
            slots.map { path, slot in
                (screenID: screenID, path: path, slot: slot, isActive: activeDedicatedPathByScreenID[screenID] == path)
            }
        }
    }

    private func activeDedicatedSlot(forScreenID screenID: String) -> DedicatedPlayerSlot? {
        guard let path = activeDedicatedPathByScreenID[screenID] else {
            return nil
        }
        return dedicatedSlotsByScreenID[screenID]?[path]
    }

    // MARK: - 再生継続性(隣接ウォームキャッシュ + 再生位置記憶)

    func setDedicatedPlaybackContinuityEnabled(_ enabled: Bool) {
        guard dedicatedPlaybackContinuityEnabled != enabled else {
            return
        }
        dedicatedPlaybackContinuityEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "dedicatedPlaybackContinuityEnabled")
        if !enabled {
            // 「現在」スロットには触れず、温存分と再生位置記憶だけを即座に破棄する。
            dedicatedWarmWindowWorkItem?.cancel()
            dedicatedWarmWindowWorkItem = nil
            for screenID in Array(dedicatedSlotsByScreenID.keys) {
                evictDedicatedSlotsOtherThanActive(forScreenID: screenID)
            }
            dedicatedResumeTimeByKey.removeAll()
            dedicatedResumeTimeInsertionOrder.removeAll()
        }
    }

    private func recordResumeTime(_ time: CMTime, forScreenID screenID: String, path: String) {
        guard time.isNumeric, time.seconds > 0 else {
            AppLog.continuity.debug(
                "record skipped (not numeric/positive) display=\(screenID, privacy: .public) path=\((path as NSString).lastPathComponent, privacy: .public)"
            )
            return
        }
        let key = ScreenPathKey(screenID: screenID, path: path)
        // 既存キーの更新でも末尾へ移動し、最近使ったものほど刈り込まれにくくする
        // (挿入順ではなく真のLRUにする)。
        dedicatedResumeTimeInsertionOrder.removeAll { $0 == key }
        dedicatedResumeTimeInsertionOrder.append(key)
        dedicatedResumeTimeByKey[key] = time
        // ライブラリが大きいセッションで無制限に育たないよう軽量LRU的に刈り込む。
        let maxEntries = 50
        while dedicatedResumeTimeInsertionOrder.count > maxEntries {
            let oldest = dedicatedResumeTimeInsertionOrder.removeFirst()
            dedicatedResumeTimeByKey.removeValue(forKey: oldest)
        }
    }

    /// readyToPlay になるまで待ってからシークする。スロットが破棄されれば player への
    /// 強参照が切れて weak が nil になり、再試行チェーンは自然に止まる。シーク先は
    /// 呼び出し時点のスナップショットではなく、シーク実行時点の最新の記憶値を都度
    /// 読みに行く。
    ///
    /// 監視対象は `player.currentItem` であって、生成時に AVPlayerLooper へ渡した
    /// テンプレート item ではない点に注意。AVPlayerLooper はテンプレートを直接
    /// player に挿入せず、ループ用に内部でコピーしたアイテムを挿入するため、
    /// テンプレート側の `.status` は再生開始後も `.unknown` のまま更新されない
    /// (実際にこれが原因で復元シークが一度も発火しないバグになっていた)。
    ///
    /// ポーリング間隔は最初の1秒だけ50ms、以降は250msへ落として無駄な再試行の
    /// 負荷を抑える。壊れたファイルなど readyToPlay にも failed にもならない
    /// 場合に備え、15秒でチェーンを打ち切る安全弁を設ける(通常は数百ms以内に
    /// readyToPlay になるため、この上限に達するのは異常系のみ)。
    private func seekDedicatedSlot(
        player: AVQueuePlayer,
        screenID: String,
        path: String,
        elapsed: TimeInterval = 0
    ) {
        let giveUpAfter: TimeInterval = 15
        guard elapsed < giveUpAfter else {
            AppLog.continuity.debug(
                "restore gave up after \(elapsed)s display=\(screenID, privacy: .public) path=\((path as NSString).lastPathComponent, privacy: .public)"
            )
            return
        }
        func retryAfterInterval() {
            let interval: TimeInterval = elapsed < 1 ? 0.05 : 0.25
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self, weak player] in
                guard let self, let player else {
                    return
                }
                self.seekDedicatedSlot(player: player, screenID: screenID, path: path, elapsed: elapsed + interval)
            }
        }
        guard let item = player.currentItem else {
            retryAfterInterval()
            return
        }
        guard item.status != .failed else {
            AppLog.continuity.error(
                "restore aborted: item failed to load display=\(screenID, privacy: .public) path=\((path as NSString).lastPathComponent, privacy: .public)"
            )
            return
        }
        guard item.status == .readyToPlay else {
            retryAfterInterval()
            return
        }
        guard let requestedTime = dedicatedResumeTimeByKey[ScreenPathKey(screenID: screenID, path: path)] else {
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
        player.seek(to: safeTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            AppLog.continuity.debug(
                "restore seek finished=\(finished) target=\(safeSeconds) actual=\(player.currentTime().seconds)"
            )
        }
    }

    /// 今この画面を支配しているのが Space かディスプレイ別固定かを判定し、現在の
    /// パスと隣接候補パス(最大2つ)を返す。どちらでもなければ nil(専用プレイヤー
    /// 自体が不要 = 共有プレイヤー管轄)。
    private func dedicatedWarmWindowContext(forScreenID screenID: String) -> (current: String, neighbors: [String])? {
        if spaceWallpaperFeatureEnabled, isSpaceWallpaperAvailable,
           let spaceUUID = currentSpaceUUIDByDisplayID[screenID],
           let currentPath = videoBySpaceUUID[spaceUUID],
           FileManager.default.fileExists(atPath: currentPath)
        {
            let order = orderedSpaceUUIDsByDisplayID[screenID] ?? []
            let (left, right) = DedicatedPlayerWarmWindow.neighbors(current: spaceUUID, order: order)
            let neighborPaths = [left, right].compactMap { $0.flatMap { videoBySpaceUUID[$0] } }
            return (currentPath, neighborPaths)
        }
        if let currentPath = videoOverrideByScreenID[screenID] {
            let order = screenVideoPaths(forScreenID: screenID)
            let (left, right) = DedicatedPlayerWarmWindow.neighbors(current: currentPath, order: order)
            return (currentPath, [left, right].compactMap { $0 })
        }
        return nil
    }

    /// 隣接プリフェッチ(温存)だけを許可するかどうかの安全弁。既存の負荷シグナルを
    /// 再利用し、新規の監視機構は作らない。再生位置記憶自体はここに関わらず常時有効。
    private var shouldAllowWarmWindowPrefetch: Bool {
        if lightweightMode {
            return false
        }
        if workProfile == .lowPower || workProfile == .ultraLight {
            return false
        }
        if ProcessInfo.processInfo.thermalState == .critical {
            return false
        }
        if batteryAwareQualityEnabled, ProcessInfo.processInfo.isLowPowerModeEnabled {
            return false
        }
        if allWallpaperDisplayIDs().count > 2 {
            return false
        }
        return true
    }

    /// 高速連続切替(スワイプ連打・次へ/前へ連打)時に、隣接の生成/破棄という
    /// 付随作業だけをまとめて実行する。「現在」スロットの切り替え自体は
    /// applySuspensionStateToPlayers が同期的に即座に反映済み。
    func scheduleDedicatedWarmWindowReconciliation(delay: TimeInterval = 0.2) {
        guard dedicatedPlaybackContinuityEnabled else {
            return
        }
        dedicatedWarmWindowWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.reconcileDedicatedWarmWindow()
        }
        dedicatedWarmWindowWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func reconcileDedicatedWarmWindow() {
        guard dedicatedPlaybackContinuityEnabled, !isWebWallpaperActive else {
            return
        }
        guard shouldAllowWarmWindowPrefetch else {
            for screenID in Array(dedicatedSlotsByScreenID.keys) {
                evictDedicatedSlotsOtherThanActive(forScreenID: screenID)
            }
            return
        }
        for screenID in allWallpaperDisplayIDs() {
            guard let context = dedicatedWarmWindowContext(forScreenID: screenID) else {
                continue
            }
            let desired = Set(context.neighbors)
            let existing = Set((dedicatedSlotsByScreenID[screenID] ?? [:]).keys)
                .subtracting([context.current])
            let plan = DedicatedPlayerWarmWindow.diff(desired: desired, existing: existing)
            for path in plan.toEvict {
                evictDedicatedSlot(forScreenID: screenID, path: path)
            }
            for path in plan.toCreate {
                ensureDedicatedSlot(forScreenID: screenID, path: path, isActive: false)
            }
        }
    }

    // MARK: - 再生/停止の反映

    /// オーバーライド画面の専用プレイヤーの再生/停止をビューへ反映する。
    /// 共有プレイヤー側のフリーズフレーム・deep suspend 機構とは独立して動く。
    func applyDedicatedSuspensionState() {
        guard hasAnyDedicatedOverride, !isWebWallpaperActive else {
            return
        }
        var viewsAwaitingFirstFrame: [PlayerView] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in playerViews.indices {
            let displayID = displayIDForWindow(at: index)
            guard let path = resolvedOverridePath(forScreenID: displayID) else {
                continue
            }
            let layer = playerViews[index].playerLayer
            if suspendedDisplayIDs.contains(displayID) {
                let player = activeDedicatedSlot(forScreenID: displayID)?.player
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
                let player = ensureDedicatedSlot(forScreenID: displayID, path: path, isActive: true)
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

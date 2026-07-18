import AppKit
import AVFoundation

/// Space(仮想デスクトップ)ごとの壁紙切替。
///
/// Space別割り当ては「Space切替のたびに動的に解決されるディスプレイ別
/// オーバーライド」として実装する。担当判定は isSharedPlayerDisplay →
/// resolvedOverridePath に集約されているため、ウィンドウ構築・被覆停止・
/// deep suspend・自動切替は既存経路のまま Space別壁紙に追従する。
///
/// v1 の割り切り(ディスプレイ別オーバーライドと同じ):
/// - Space別は動画1本の固定のみ(プレイリストなし)。
/// - 専用プレイヤーは常に消音・常にループ。
/// - Web壁紙アクティブ中は対象外。
@MainActor
extension WallpaperModel {
    /// この機能が現在の環境で利用可能か(シンボル解決成功かつ実行時失敗未検出)。
    var isSpaceWallpaperAvailable: Bool {
        spacesBridge.isAvailable && !spaceWallpaperRuntimeUnavailable
    }

    /// 「この画面に今表示すべきオーバーライド動画」の唯一の解決点。
    /// 優先順位: Space別 > ディスプレイ別 > 共有(nil)。狭いスコープが勝つ。
    /// 未知の Space uuid・フルスクリーンSpace・機能OFF・非公開API利用不可の
    /// すべてが「Space層が nil → ディスプレイ別 → 共有」という同一の
    /// フォールバック経路に乗る。
    func resolvedOverridePath(forScreenID screenID: String) -> String? {
        if spaceWallpaperFeatureEnabled,
           isSpaceWallpaperAvailable,
           let spaceUUID = currentSpaceUUIDByDisplayID[screenID],
           let path = videoBySpaceUUID[spaceUUID],
           FileManager.default.fileExists(atPath: path)
        {
            return path
        }
        return videoOverrideByScreenID[screenID]
    }

    /// 専用プレイヤーで処理すべきオーバーライドが1つでも有効か。
    /// applyDedicatedSuspensionState の早期 return 判定に使う。
    var hasAnyDedicatedOverride: Bool {
        if !videoOverrideByScreenID.isEmpty {
            return true
        }
        return spaceWallpaperFeatureEnabled && isSpaceWallpaperAvailable
            && !videoBySpaceUUID.isEmpty
    }

    // MARK: - 割り当ての管理

    func spaceVideo(forSpaceUUID uuid: String) -> String? {
        videoBySpaceUUID[uuid]
    }

    func setSpaceVideo(path: String?, forSpaceUUID uuid: String) {
        if let path {
            guard FileManager.default.fileExists(atPath: path) else {
                return
            }
            guard videoBySpaceUUID[uuid] != path else {
                return
            }
            videoBySpaceUUID[uuid] = path
        } else {
            guard videoBySpaceUUID[uuid] != nil else {
                return
            }
            videoBySpaceUUID.removeValue(forKey: uuid)
        }
        persistSpaceVideos()
        // 変更した Space が現在表示中なら、共有側とオーバーライド側の両方の
        // attach 処理がここで走って表示が切り替わる。表示中でなければ何も
        // 変わらない(次の Space 切替時に反映される)。
        applySpaceWallpaperSwap()
    }

    /// 指定した動画への Space 割り当てをすべて解除する(登録削除時の後始末)。
    func clearSpaceVideos(forPath path: String) {
        let matching = videoBySpaceUUID.filter { $0.value == path }.keys
        guard !matching.isEmpty else {
            return
        }
        for uuid in matching {
            videoBySpaceUUID.removeValue(forKey: uuid)
        }
        persistSpaceVideos()
        applySpaceWallpaperSwap()
    }

    func setSpaceWallpaperFeatureEnabled(_ enabled: Bool) {
        guard spaceWallpaperFeatureEnabled != enabled else {
            return
        }
        spaceWallpaperFeatureEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "spaceWallpaperFeatureEnabled")
        if enabled {
            refreshSpacesSnapshot()
        } else {
            orderedSpaceUUIDsByDisplayID.removeAll()
            // 機能OFF中はスナップショットを取り直さないので、残しておくと二度と
            // 更新されない古い Space 一覧をUIに見せることになる。割り当て自体
            // (videoBySpaceUUID)は再ONで復元できるよう保持する。
            knownDesktopSpaces = []
            currentSpaceUUIDByDisplayID = [:]
        }
        applySpaceWallpaperSwap()
    }

    func setMenuBarSpaceNumberEnabled(_ enabled: Bool) {
        guard menuBarSpaceNumberEnabled != enabled else {
            return
        }
        menuBarSpaceNumberEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "menuBarSpaceNumberEnabled")
        // バッジ表示は AppDelegate 側が activeDesktopSpaceDidResolveNotification と
        // $menuBarSpaceNumberEnabled で追従する。
        refreshSpaceDependentInterface()
    }

    // MARK: - 永続化

    private func persistSpaceVideos() {
        UserDefaults.standard.set(videoBySpaceUUID, forKey: "videoBySpaceUUID")
    }

    func restoreSpaceWallpaperState() {
        spaceWallpaperFeatureEnabled =
            UserDefaults.standard.object(forKey: "spaceWallpaperFeatureEnabled") as? Bool ?? false
        menuBarSpaceNumberEnabled =
            UserDefaults.standard.object(forKey: "menuBarSpaceNumberEnabled") as? Bool ?? false
        if let saved = UserDefaults.standard.dictionary(forKey: "videoBySpaceUUID")
            as? [String: String]
        {
            // 実在確認は verifyRestoredVideoPaths() が起動後にまとめて行う(restoreState 参照)。
            videoBySpaceUUID = saved
        }
        if spaceWallpaperFeatureEnabled {
            refreshSpacesSnapshot()
        }
    }

    // MARK: - Space 状態の取得

    /// 非公開APIから Space 一覧と各ディスプレイの現在 Space を取り直す。
    /// フルスクリーンSpace が現在表示中のディスプレイでは記録を更新しない
    /// (直前の通常デスクトップの壁紙を保ち、無駄な差し替えを避ける)。
    func refreshSpacesSnapshot() {
        guard spacesBridge.isAvailable, !spaceWallpaperRuntimeUnavailable else {
            return
        }
        guard
            let raw = spacesBridge.rawManagedDisplaySpaces(),
            let snapshots = SpaceSnapshotParser.parse(raw)
        else {
            spacesSnapshotFailureCount += 1
            AppLog.spaces.error(
                "snapshot failed count=\(self.spacesSnapshotFailureCount)"
            )
            // 非公開APIの返却形式が変わった可能性。誤った壁紙を出し続ける
            // より機能ごと止めて従来動作へ戻す。
            if spacesSnapshotFailureCount >= 3 {
                spaceWallpaperRuntimeUnavailable = true
                AppLog.spaces.error("disabled: repeated snapshot failures")
            }
            return
        }
        spacesSnapshotFailureCount = 0

        knownDesktopSpaces = snapshots.flatMap(\.spaces).filter { !$0.isFullscreen }

        var current: [String: String] = currentSpaceUUIDByDisplayID
        // knownDesktopSpaces はUI表示用に全ディスプレイをフラット化しており、
        // 隣接ウォームキャッシュの判定に必要なディスプレイ単位の並び順を失う
        // ため、別途 orderedSpaceUUIDsByDisplayID として保持する。
        var orderedByDisplay: [String: [String]] = [:]
        if snapshots.count == 1,
           snapshots[0].cgsDisplayIdentifier == SpaceSnapshotParser.mainDisplayIdentifier
        {
            // 「ディスプレイごとに個別のSpace」OFF: 全画面が同じ Space を表示。
            if !snapshots[0].currentSpaceIsFullscreen {
                let uuid = snapshots[0].currentSpaceUUID
                for displayID in allWallpaperDisplayIDs() {
                    current[displayID] = uuid
                }
            }
            let order = snapshots[0].spaces.filter { !$0.isFullscreen }.map(\.uuid)
            for displayID in allWallpaperDisplayIDs() {
                orderedByDisplay[displayID] = order
            }
        } else {
            let appIDByCGSUUID = displayIDByCGSDisplayUUID()
            for snapshot in snapshots where !snapshot.currentSpaceIsFullscreen {
                if let displayID = appIDByCGSUUID[snapshot.cgsDisplayIdentifier] {
                    current[displayID] = snapshot.currentSpaceUUID
                }
            }
            for snapshot in snapshots {
                if let displayID = appIDByCGSUUID[snapshot.cgsDisplayIdentifier] {
                    orderedByDisplay[displayID] = snapshot.spaces.filter { !$0.isFullscreen }.map(\.uuid)
                }
            }
        }
        if current != currentSpaceUUIDByDisplayID {
            currentSpaceUUIDByDisplayID = current
        }
        orderedSpaceUUIDsByDisplayID = orderedByDisplay
        AppLog.spaces.debug(
            "snapshot desktops=\(self.knownDesktopSpaces.count) current=\(current, privacy: .public)"
        )
    }

    /// CGS のディスプレイUUID文字列 → アプリの画面ID(CGDirectDisplayIDの文字列)。
    private func displayIDByCGSDisplayUUID() -> [String: String] {
        var mapping: [String: String] = [:]
        for screen in NSScreen.screens {
            guard
                let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber
            else {
                continue
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?
                .takeRetainedValue()
            else {
                continue
            }
            let uuidString = CFUUIDCreateString(nil, uuid) as String
            mapping[uuidString] = String(number.uint32Value)
        }
        return mapping
    }

    // MARK: - 切替フロー

    /// activeSpaceDidChangeNotification から呼ばれる入口。
    func handleActiveSpaceChanged() {
        guard spaceWallpaperFeatureEnabled, isSpaceWallpaperAvailable,
              !isWebWallpaperActive
        else {
            return
        }
        let previous = currentSpaceUUIDByDisplayID
        refreshSpacesSnapshot()
        guard currentSpaceUUIDByDisplayID != previous else {
            return
        }
        applySpaceWallpaperSwap()
        refreshSpaceDependentInterface()
    }

    /// 現在の Space 解決結果に合わせて各画面のプレイヤーを付け替える。
    /// 実体は applySuspensionStateToPlayers(共有側 attach + 専用側 attach の
    /// 両方を担う既存経路)。ここでは黒フラッシュ防止の静止画事前貼り付けと、
    /// どのオーバーライドも無くなった画面の専用プレイヤー回収だけを足す。
    func applySpaceWallpaperSwap() {
        guard !isWebWallpaperActive else {
            return
        }
        prepareFreezeFramesForOwnershipChanges()
        applySuspensionStateToPlayers()
        releaseDedicatedPlayersWithoutOverride()
        scheduleDedicatedWarmWindowReconciliation()
    }

    /// 担当プレイヤーが変わる画面に、旧コンテンツの静止画を先に貼っておく。
    /// 付け替え直後の AVPlayerLayer は初回フレーム描画まで背景(黒)に落ちる
    /// ことがあるため、貼っておけば既存の clearFreezeStillWhenReady 経路が
    /// 「静止画 → 新動画の初フレーム」で滑らかに繋ぐ。
    private func prepareFreezeFramesForOwnershipChanges() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in playerViews.indices {
            let displayID = displayIDForWindow(at: index)
            let layer = playerViews[index].playerLayer
            guard let attached = layer.player else {
                continue
            }
            let expectedPath = resolvedOverridePath(forScreenID: displayID)
            if expectedPath == nil, attached === sharedPlayer {
                // 既に共有プレイヤー担当のまま。共有プレイヤー内での動画切替は
                // プレイヤーのオーナーシップ変更ではないため、フリーズフレーム
                // 貼り付け+デタッチは不要(貼ってしまうと通常再生中の全画面が
                // Space切替のたびに一瞬止まる)。
                continue
            }
            let attachedPath = attachedPlayerPath(
                attached, forScreenID: displayID
            )
            guard attachedPath != expectedPath else {
                continue
            }
            if layer.contents == nil, layer.isReadyForDisplay,
               let attachedPath
            {
                let freeze = VideoFrameCapture.capture(
                    path: attachedPath, time: attached.currentTime()
                )
                if let freeze {
                    layer.contents = freeze
                    // isReadyForDisplay は layer.player に紐づくため、ここで
                    // デタッチしておかないと直後の attach 処理(applySuspensionState-
                    // ToPlayers/applyDedicatedSuspensionState)が「まだ古いプレイヤーが
                    // 描画中 → isReadyForDisplay == true」と誤判定し、このフリーズ画像を
                    // 即座に破棄して未描画の新プレイヤーへ直結してしまう(黒フラッシュ/
                    // 一瞬の停止)。nil にしておけば isReadyForDisplay は必ず false になり、
                    // 新プレイヤーの初回描画までフリーズ画像を保持する経路に正しく乗る。
                    layer.player = nil
                }
            }
        }
        CATransaction.commit()
    }

    /// レイヤーに付いているプレイヤーが再生している動画パス。
    private func attachedPlayerPath(
        _ player: AVPlayer, forScreenID screenID: String
    ) -> String? {
        if player === sharedPlayer {
            return currentVideoPath
        }
        if let path = activeDedicatedPathByScreenID[screenID],
           dedicatedSlotsByScreenID[screenID]?[path]?.player === player
        {
            return path
        }
        return nil
    }

    /// Space別もディスプレイ別も無くなった画面の専用プレイヤーを解放する。
    /// (共有プレイヤーへの復帰自体は applySuspensionStateToPlayers が済ませている)
    private func releaseDedicatedPlayersWithoutOverride() {
        for screenID in Array(dedicatedSlotsByScreenID.keys)
            where resolvedOverridePath(forScreenID: screenID) == nil
        {
            evictAllDedicatedSlots(forScreenID: screenID)
        }
    }

    /// Space 切替に追従する画面表示(メニューバーのバッジ等)の更新フック。
    /// AppDelegate 側が上書き登録する。
    private func refreshSpaceDependentInterface() {
        NotificationCenter.default.post(
            name: Self.activeDesktopSpaceDidResolveNotification, object: nil
        )
    }

    static let activeDesktopSpaceDidResolveNotification =
        Notification.Name("WallpaperModel.activeDesktopSpaceDidResolve")

    /// メイン画面が現在表示している Space の uuid(メニューバー操作の対象)。
    var currentSpaceUUIDForMainDisplay: String? {
        currentSpaceUUIDByDisplayID[displayIDString(for: NSScreen.main)]
    }

    /// メインディスプレイに実際に表示されている壁紙のパス。ディスプレイ別/Space別
    /// オーバーライドで専用プレイヤー担当になっていればそちらを、そうでなければ
    /// 共有プレイヤーの再生中動画を返す。「現在のデスクトップに割り当て」系の
    /// メニュー操作は、共有プレイヤーの currentVideoPath だけでは専用プレイヤー
    /// 担当時に無関係の動画を参照してしまうため、必ずこちらを使うこと。
    var currentlyVisiblePathForMainDisplay: String? {
        resolvedOverridePath(forScreenID: displayIDString(for: NSScreen.main)) ?? currentVideoPath
    }

    /// UI表示用: uuid → 「デスクトップN」の N。
    func desktopOrdinal(forSpaceUUID uuid: String) -> Int? {
        knownDesktopSpaces.first(where: { $0.uuid == uuid })?.ordinal
    }

    // MARK: - 環境変化への追従

    /// スリープ復帰時は復帰前と別の Space になっていることがあるため取り直す。
    func configureSpaceWakeMonitoring() {
        guard workspaceWakeObserver == nil else {
            return
        }
        workspaceWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleActiveSpaceChanged()
            }
        }
    }
}

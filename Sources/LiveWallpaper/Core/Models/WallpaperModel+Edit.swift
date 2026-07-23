import AVFoundation
import Foundation

@MainActor
extension WallpaperModel {
    private func updateEdit(_ edit: WallpaperEditMetadata?, for path: String) {
        if let edit, !edit.isNoOp {
            wallpaperEditByPath[path] = edit
        } else {
            wallpaperEditByPath.removeValue(forKey: path)
        }
        persistWallpaperEditState()
        reinstallCurrentPlayerItemIfNeeded(for: path)
        refreshDedicatedSlotsIfNeeded(for: path)
    }

    private func reinstallCurrentPlayerItemIfNeeded(for path: String) {
        guard currentVideoPath == path, !isWebWallpaperActive else {
            return
        }
        playRegisteredVideo(path: path)
    }

    func setWallpaperEdit(
        trimStart: Double,
        trimEnd: Double?,
        loopStart: Double? = nil,
        path: String
    ) {
        let edit = WallpaperEditMetadata(
            trimStart: trimStart,
            trimEnd: trimEnd,
            loopStart: loopStart
        )
        updateEdit(edit, for: path)
    }

    func resetWallpaperEdit(path: String) {
        updateEdit(nil, for: path)
    }

    func hasWallpaperEditOverride(path: String) -> Bool {
        wallpaperEditByPath[path] != nil
    }

    func wallpaperEdit(for path: String) -> WallpaperEditMetadata? {
        wallpaperEditByPath[path]
    }

    /// `path` に保存済みのトリム編集を反映した継ぎ目なしループを作る。
    /// 共有プレイヤー(WallpaperModel+Playback.swift)と画面固定の専用プレイヤー
    /// (WallpaperModel+DisplayOverrides.swift)の両方から呼ばれる。実際のループ構築は
    /// トリム編集画面のWYSIWYGプレビューとも共有する `WallpaperLoopBuilder` に
    /// 一本化してある。
    /// - Parameter playsIntro: 「途中からループする」のイントロ(初回だけカット
    ///   開始位置から)を出すか。直前の再生位置を復元する経路では false にする
    ///   — 復元シークとイントロシークが両方 readyToPlay を待って撃ち合うと、
    ///   どちらが後に着地するかで再生位置が揺れるため。
    func makeWallpaperLooper(
        player: AVQueuePlayer,
        templateItem item: AVPlayerItem,
        path: String?,
        playsIntro: Bool = true,
        context: String = "shared"
    ) -> AVPlayerLooper {
        guard let path, let edit = wallpaperEditByPath[path], !edit.isNoOp else {
            return AVPlayerLooper(player: player, templateItem: item)
        }
        return WallpaperLoopBuilder.makeLooper(
            player: player,
            templateItem: item,
            trimStart: edit.trimStart,
            trimEnd: edit.trimEnd,
            loopStart: edit.loopStart,
            playsIntro: playsIntro,
            context: "\(context) \((path as NSString).lastPathComponent)"
        )
    }

    /// 「前回の続きから再生する」ための復元シーク先を丸める、唯一の実装。
    /// 専用プレイヤーのスロット再生成(WallpaperModel+DisplayOverrides.swift)・
    /// deep suspend からの復帰(WallpaperModel+DeepSuspend.swift)・軽量プロキシへの
    /// 差し替え(WallpaperModel+LightweightPlayback.swift)の3経路が共有する。
    ///
    /// トリム編集がある動画では、記録された位置がカットで捨てた領域を指している
    /// ことがある(編集前に記録された位置、トリム範囲を後から狭めた場合など)。
    /// そこへ seek すると `AVPlayerLooper` のループ区間の外へ出てしまい、ループに
    /// 戻れずそのフレームで停止する。区間外なら nil を返し、呼び出し側に復元シーク
    /// そのものを見送らせる(カット開始位置からの再生になる)。
    ///
    /// - Returns: シークすべき秒数。シークすべきでなければ nil。
    func clampedResumeSeconds(
        _ requestedSeconds: Double,
        path: String?,
        itemDurationSeconds: Double?
    ) -> Double? {
        guard requestedSeconds.isFinite, requestedSeconds > 0 else {
            return nil
        }
        let duration: Double? = itemDurationSeconds.flatMap {
            $0.isFinite && $0 > WallpaperLoopBuilder.resumeEndGuard ? $0 : nil
        }
        guard let path, let edit = wallpaperEditByPath[path], !edit.isNoOp else {
            // 編集なし: 従来どおり尺の内側へ丸めるだけ。
            guard let duration else {
                return requestedSeconds
            }
            return min(requestedSeconds, duration - WallpaperLoopBuilder.resumeEndGuard)
        }
        return WallpaperLoopBuilder.clampedResumeSeconds(
            requestedSeconds,
            trimStart: edit.trimStart,
            trimEnd: edit.trimEnd,
            itemDurationSeconds: duration
        )
    }
}

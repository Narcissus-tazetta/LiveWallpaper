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

    func setWallpaperEdit(trimStart: Double, trimEnd: Double?, loopStart: Double?, path: String) {
        let edit = WallpaperEditMetadata(trimStart: trimStart, trimEnd: trimEnd, loopStart: loopStart)
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

    /// `path` に保存済みのトリム/ループ編集を反映した AVPlayerLooper を作る。
    /// 共有プレイヤー(WallpaperModel+Playback.swift)と画面固定の専用プレイヤー
    /// (WallpaperModel+DisplayOverrides.swift)の両方から呼ばれる、ループ構築の
    /// 唯一の実装にする(バンドエイド的な二重実装を避ける)。
    ///
    /// trimEnd が未設定の場合、テンプレートの実尺をここで同期取得する手段がないため
    /// (AVAssetの尺読み込みは非同期)、durationに .positiveInfinity を渡す。
    /// AVPlayerLooperはこれをアイテムの自然な終端にクランプして扱うため、
    /// 尺を知らなくてもeffectiveLoopStartからループさせられる。
    func makeWallpaperLooper(
        player: AVQueuePlayer,
        templateItem item: AVPlayerItem,
        path: String?
    ) -> AVPlayerLooper {
        guard let path, let edit = wallpaperEditByPath[path], !edit.isNoOp else {
            return AVPlayerLooper(player: player, templateItem: item)
        }
        let start = CMTime(seconds: edit.effectiveLoopStart, preferredTimescale: 600)
        let duration: CMTime = edit.trimEnd.map {
            CMTime(seconds: $0, preferredTimescale: 600) - start
        } ?? .positiveInfinity
        let range = CMTimeRange(start: start, duration: duration)
        return AVPlayerLooper(player: player, templateItem: item, timeRange: range)
    }
}

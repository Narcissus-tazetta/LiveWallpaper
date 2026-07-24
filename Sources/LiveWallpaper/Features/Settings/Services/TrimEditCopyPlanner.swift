import Foundation

/// 編集内容を別の動画へコピーするときの「その動画に合わせた作り直し」。
///
/// カット範囲は秒の絶対値なので、そのまま別の動画へ書き込むとコピー先の尺を
/// はみ出しうる。はみ出した trimEnd は再生時に `AVPlayerLooper` を `.failed`
/// にして**その壁紙が一切再生されなくなる**(`WallpaperLoopBuilder` 参照)ため、
/// コピーは必ずここを通してコピー先の尺の内側へ収める。収まらない動画へは
/// 何も書かずに nil を返し、呼び出し側にスキップさせる — 半端に丸めた範囲を
/// 黙って書き込むより、「この動画には短すぎてコピーできなかった」と伝える方が
/// 分かりやすい。
enum TrimEditCopyPlanner {
    /// - Parameters:
    ///   - targetDuration: コピー先の実尺。0以下(まだ読めていない/壊れている)
    ///     なら検証できないので nil を返す。
    ///   - minimumSegment: ループ区間として最低限確保する長さ。
    ///   - endGuard: 実尺の内側へ必ず残す余白(`WallpaperLoopBuilder.loopEndGuard`)。
    /// - Returns: コピー先へ保存してよい編集内容。収まらなければ nil。
    static func plan(
        source: WallpaperEditMetadata,
        targetDuration: Double,
        minimumSegment: Double,
        endGuard: Double
    ) -> WallpaperEditMetadata? {
        guard targetDuration.isFinite, targetDuration > 0 else {
            return nil
        }
        let trimStart = max(source.trimStart, 0)
        let maxEnd = targetDuration - endGuard
        guard trimStart + minimumSegment <= maxEnd else {
            // コピー先が短すぎて、カット開始位置の先に区間を作れない。
            return nil
        }

        let requestedEnd = source.trimEnd ?? targetDuration
        let trimEnd = min(requestedEnd, maxEnd)
        guard trimEnd >= trimStart + minimumSegment else {
            return nil
        }

        // ループ開始位置は「収まらなければ捨てる」。カット範囲だけでもコピー
        // できた方が有用で、中途半端な位置へ丸めたループ開始位置は害しかない。
        var loopStart: Double?
        if let sourceLoopStart = source.loopStart,
           sourceLoopStart > trimStart,
           sourceLoopStart <= trimEnd - minimumSegment
        {
            loopStart = sourceLoopStart
        }

        return WallpaperEditMetadata(
            trimStart: trimStart,
            trimEnd: trimEnd,
            loopStart: loopStart
        )
    }
}

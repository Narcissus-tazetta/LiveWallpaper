import Foundation

/// A single video's non-destructive trim edit. All values are seconds
/// relative to asset start (t=0). No re-encoding — pure playback-range metadata.
///
/// `loopStart` は「途中からループする」用の任意指定。初回だけ `trimStart` から
/// 通しで再生し、2周目以降は `loopStart ... trimEnd` を繰り返す
/// (`WallpaperLoopBuilder` 参照)。未指定なら最初からカット範囲全体をループする。
struct WallpaperEditMetadata: Codable, Equatable {
    var trimStart: Double = 0
    var trimEnd: Double?
    var loopStart: Double?

    func isValid(assetDuration: Double?) -> Bool {
        guard trimStart >= 0 else { return false }
        if let trimEnd, trimEnd <= trimStart {
            return false
        }
        if let loopStart {
            if loopStart < trimStart {
                return false
            }
            if let trimEnd, loopStart >= trimEnd {
                return false
            }
        }
        if let duration = assetDuration {
            if trimStart > duration {
                return false
            }
            if let trimEnd, trimEnd > duration {
                return false
            }
            if let loopStart, loopStart > duration {
                return false
            }
        }
        return true
    }

    var isNoOp: Bool {
        trimStart == 0 && trimEnd == nil && loopStart == nil
    }

    /// 2周目以降のループ開始位置。未指定ならカット開始位置。
    var effectiveLoopStart: Double {
        loopStart ?? trimStart
    }
}

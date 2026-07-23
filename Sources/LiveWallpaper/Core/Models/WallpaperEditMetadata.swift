import Foundation

/// A single video's non-destructive trim/loop edit. All values are seconds
/// relative to asset start (t=0). No re-encoding — pure playback-range metadata.
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
        }
        return true
    }

    var isNoOp: Bool {
        trimStart == 0 && trimEnd == nil && loopStart == nil
    }

    /// ループ再生を再開する秒数。カスタムのループ開始位置が無ければカット開始位置。
    var effectiveLoopStart: Double {
        loopStart ?? trimStart
    }
}

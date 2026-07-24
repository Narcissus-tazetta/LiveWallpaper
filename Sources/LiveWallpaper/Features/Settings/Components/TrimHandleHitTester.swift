import CoreGraphics

enum TrimHandleTarget: Equatable {
    case start
    case end
    case loopStart
    case track
}

/// `TrimRangeScrubber` のドラッグ開始位置から、どのハンドルを掴んだと見なすかを
/// 決める純粋なジオメトリ判定。ビュー本体から切り離してあるのは、start/end が
/// 画面上で重なった状態でも「開始位置に最も近いハンドル」を一意に選べることを
/// SwiftUIのレンダリングに依存せず検証できるようにするため
/// (以前は各ハンドルが個別に `.gesture` を持ち、重なった領域は常に最後に描画された
/// ハンドルへ吸われて掴めなかった)。
enum TrimHandleHitTester {
    /// 座標が nil のハンドルは候補に入れない。「途中からループする」がOFFで
    /// ハンドル自体が無い場合と、タイムラインを拡大していてハンドルが画面外に
    /// ある場合の両方がある — どちらも掴めない以上、そこを掴んだ操作は
    /// トラックのスクラブとして扱うのが正しい。
    static func resolve(
        at x: CGFloat,
        trimStartX: CGFloat?,
        trimEndX: CGFloat?,
        loopStartX: CGFloat? = nil,
        hitRadius: CGFloat
    ) -> TrimHandleTarget {
        var candidates: [(TrimHandleTarget, CGFloat)] = []
        if let trimStartX {
            candidates.append((.start, trimStartX))
        }
        if let trimEndX {
            candidates.append((.end, trimEndX))
        }
        if let loopStartX {
            candidates.append((.loopStart, loopStartX))
        }
        guard
            let nearest = candidates.min(by: { abs($0.1 - x) < abs($1.1 - x) }),
            abs(nearest.1 - x) <= hitRadius
        else {
            return .track
        }
        return nearest.0
    }
}

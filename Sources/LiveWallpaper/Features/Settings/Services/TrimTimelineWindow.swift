import Foundation

/// トリム編集のタイムラインが今映している時間範囲(ズーム/スクロールの状態)。
///
/// スクラバーは秒 ↔︎ x座標 の変換を「アセット全体」ではなくこの窓に対して行う。
/// 5分の動画をトラック幅400ptで表示すると1pt ≒ 0.75秒になり、0.1秒精度の
/// ドラッグが物理的に不可能なため、窓を狭めて解像度を稼げるようにする。
///
/// ビューから切り離した純構造体にしてあるのは、ズームのアンカー維持や端での
/// クランプといった間違えやすい算術を、SwiftUIのレイアウトに依存せず検証できる
/// ようにするため。すべてのメンバは「アセット尺の内側に収まっている」ことを
/// 不変条件として保つ(`clamped(assetDuration:)`)。
struct TrimTimelineWindow: Equatable {
    /// これ以上は拡大しない下限。1フレームだけ映してもハンドルを掴めないため、
    /// 常にこれだけの秒数は見えるようにする。
    static let minimumDuration: Double = 0.25

    private(set) var start: Double
    private(set) var duration: Double

    init(start: Double, duration: Double) {
        self.start = start.isFinite ? start : 0
        self.duration = duration.isFinite ? max(duration, Self.minimumDuration) : Self.minimumDuration
    }

    static func full(assetDuration: Double) -> TrimTimelineWindow {
        TrimTimelineWindow(start: 0, duration: max(assetDuration, minimumDuration))
    }

    var end: Double {
        start + duration
    }

    func contains(_ time: Double) -> Bool {
        time >= start && time <= end
    }

    /// 全体表示(これ以上引けない)か。ズームアウトボタンの無効化に使う。
    func isFullyZoomedOut(assetDuration: Double) -> Bool {
        assetDuration <= 0 || duration >= assetDuration - 0.0001
    }

    func isFullyZoomedIn() -> Bool {
        duration <= Self.minimumDuration + 0.0001
    }

    /// アセットの内側へ収める。窓がアセットより広ければ全体表示に落とす。
    func clamped(assetDuration: Double) -> TrimTimelineWindow {
        guard assetDuration > 0 else {
            return .full(assetDuration: 0)
        }
        let clampedDuration = min(max(duration, Self.minimumDuration), assetDuration)
        let maxStart = max(assetDuration - clampedDuration, 0)
        let clampedStart = min(max(start, 0), maxStart)
        return TrimTimelineWindow(start: clampedStart, duration: clampedDuration)
    }

    /// `anchor` の秒が画面上の同じ位置に留まるようにズームする。
    /// - Parameter factor: 1より大きければ拡大、小さければ縮小。
    func zoomed(by factor: Double, anchor: Double, assetDuration: Double) -> TrimTimelineWindow {
        guard factor > 0, factor.isFinite, assetDuration > 0 else {
            return clamped(assetDuration: assetDuration)
        }
        let newDuration = min(max(duration / factor, Self.minimumDuration), assetDuration)
        // アンカーの「窓内での相対位置」を保つ。単純に中心を固定すると、端を
        // 掴んでズームしたときに見ていた場所が画面外へ逃げる。
        let anchorRatio = duration > 0 ? min(max((anchor - start) / duration, 0), 1) : 0.5
        let newStart = anchor - anchorRatio * newDuration
        return TrimTimelineWindow(start: newStart, duration: newDuration)
            .clamped(assetDuration: assetDuration)
    }

    func panned(bySeconds delta: Double, assetDuration: Double) -> TrimTimelineWindow {
        guard delta.isFinite else {
            return self
        }
        return TrimTimelineWindow(start: start + delta, duration: duration)
            .clamped(assetDuration: assetDuration)
    }

    /// 指定範囲を余白付きで丸ごと収める(「選択範囲へズーム」)。
    static func fitting(
        from: Double,
        to: Double,
        assetDuration: Double
    ) -> TrimTimelineWindow {
        let span = max(to - from, minimumDuration)
        let padding = span * 0.08
        return TrimTimelineWindow(start: from - padding, duration: span + padding * 2)
            .clamped(assetDuration: assetDuration)
    }

    /// 再生位置が窓の外へ出たら追いかける。全体表示のときは何もしない。
    /// 追従先は窓の左端ぴったりではなく少し内側にして、直前の文脈を残す。
    func following(playhead: Double, assetDuration: Double) -> TrimTimelineWindow {
        guard assetDuration > 0, !isFullyZoomedOut(assetDuration: assetDuration) else {
            return self
        }
        guard playhead.isFinite, !contains(playhead) else {
            return self
        }
        return TrimTimelineWindow(start: playhead - duration * 0.2, duration: duration)
            .clamped(assetDuration: assetDuration)
    }

    /// 窓内での相対位置(0...1)。窓の外は0未満/1超の値をそのまま返す
    /// — 呼び出し側が「画面外なので描かない」を判定できるようにするため。
    func ratio(forTime time: Double) -> Double {
        guard duration > 0 else {
            return 0
        }
        return (time - start) / duration
    }

    func time(atRatio ratio: Double) -> Double {
        start + ratio * duration
    }

    /// 画面上の1ptが何秒に相当するか。キーフレーム吸着の許容誤差を
    /// 「見た目の距離」で決めるために使う。
    func secondsPerPoint(width: Double) -> Double {
        guard width > 0 else {
            return 0
        }
        return duration / width
    }
}

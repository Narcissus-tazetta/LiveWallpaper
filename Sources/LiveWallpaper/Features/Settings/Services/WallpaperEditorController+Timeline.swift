import Foundation

/// タイムラインのズーム/スクロールと、キーフレーム吸着。
///
/// どちらも「長い動画をフレーム単位で編集する」ための機能で、状態としては
/// ドラフト(保存対象)ではなく表示側の都合なので、保存・破棄の対象には含めない。
extension WallpaperEditorController {
    /// 1回のズーム操作で変える倍率。
    var zoomStepFactor: Double {
        1.6
    }

    var canZoomIn: Bool {
        draft.assetDuration > 0 && !timelineWindow.isFullyZoomedIn()
    }

    var canZoomOut: Bool {
        draft.assetDuration > 0 && !timelineWindow.isFullyZoomedOut(assetDuration: draft.assetDuration)
    }

    /// 動画を読み込み直したときの初期状態(全体表示)。
    func resetTimelineWindow() {
        timelineWindow = .full(assetDuration: draft.assetDuration)
    }

    /// アンカー未指定のズームは再生位置を中心にする。今見ているコマが画面から
    /// 逃げないので、拡大した後に迷子にならない。
    func zoomTimeline(by factor: Double, anchor: Double? = nil) {
        guard draft.assetDuration > 0 else {
            return
        }
        let anchorTime = anchor ?? clampedAnchor()
        timelineWindow = timelineWindow.zoomed(
            by: factor,
            anchor: anchorTime,
            assetDuration: draft.assetDuration
        )
    }

    func panTimeline(bySeconds delta: Double) {
        guard draft.assetDuration > 0 else {
            return
        }
        timelineWindow = timelineWindow.panned(
            bySeconds: delta,
            assetDuration: draft.assetDuration
        )
    }

    /// 表示範囲の中心を指定時刻へ移動する(全体バーのドラッグ)。
    func centerTimeline(on time: Double) {
        guard draft.assetDuration > 0, time.isFinite else {
            return
        }
        timelineWindow = TrimTimelineWindow(
            start: time - timelineWindow.duration / 2,
            duration: timelineWindow.duration
        )
        .clamped(assetDuration: draft.assetDuration)
    }

    /// タイムライン全体を映す。
    func zoomTimelineToFull() {
        resetTimelineWindow()
    }

    /// カット範囲を画面いっぱいに映す。長い動画から数秒を切り出すときの主導線。
    func zoomTimelineToSelection() {
        guard draft.assetDuration > 0 else {
            return
        }
        timelineWindow = .fitting(
            from: draft.trimStart,
            to: draft.effectiveTrimEnd,
            assetDuration: draft.assetDuration
        )
    }

    /// 拡大中に再生位置が窓の外へ出たら追いかける。`playheadTime` の didSet から
    /// 呼ばれる(再生中は0.1秒ごと)ため、窓が変わらないときは何も書き換えない
    /// — 毎回代入すると @Published が発火し続けて画面全体が再描画される。
    func followPlayheadIfNeeded() {
        guard draft.assetDuration > 0 else {
            return
        }
        let next = timelineWindow.following(
            playhead: playheadTime,
            assetDuration: draft.assetDuration
        )
        guard next != timelineWindow else {
            return
        }
        timelineWindow = next
    }

    private func clampedAnchor() -> Double {
        let anchor = playheadTime.isFinite ? playheadTime : timelineWindow.start
        guard timelineWindow.contains(anchor) else {
            // 再生位置が画面外なら、今見えている真ん中を軸にする。
            return timelineWindow.start + timelineWindow.duration / 2
        }
        return anchor
    }

    // MARK: - キーフレーム吸着

    /// 吸着の許容誤差。画面上の見た目の距離(約8pt)を秒へ換算するので、
    /// 拡大するほど厳しく、引くほど緩くなる — どのズーム率でも「掴んだ場所の
    /// すぐ近く」に吸い付く感触になる。
    var keyframeSnapTolerance: Double {
        let perPoint = timelineWindow.secondsPerPoint(width: scrubberWidth)
        guard perPoint > 0 else {
            return TrimKeyframeIndex.minimumTolerance
        }
        return min(
            max(perPoint * 8, TrimKeyframeIndex.minimumTolerance),
            TrimKeyframeIndex.maximumTolerance
        )
    }

    func snappedToKeyframe(_ time: Double) -> Double {
        guard snapsToKeyframes, !keyframeTimes.isEmpty else {
            return time
        }
        return TrimKeyframeIndex.snapped(
            time,
            to: keyframeTimes,
            tolerance: keyframeSnapTolerance
        )
    }

    /// 索引はトリム編集を実際に開いていて、吸着がONのときだけ作る。
    /// 走査はデコードなしとはいえ長尺では数百ms かかるので、タブを開いた
    /// だけの人に払わせない。
    func loadKeyframesIfNeeded() {
        guard isActive, isSubModeActive, snapsToKeyframes else {
            return
        }
        guard let path = resolvedVideoPath(), !path.isEmpty else {
            return
        }
        guard keyframeIndexedPath != path else {
            return
        }
        keyframeLoadTask?.cancel()
        isLoadingKeyframes = true
        keyframeLoadTask = Task { [weak self] in
            let times = await TrimKeyframeIndex.loadKeyframeTimes(path: path)
            guard let self, !Task.isCancelled, resolvedVideoPath() == path else {
                return
            }
            keyframeTimes = times
            keyframeIndexedPath = path
            isLoadingKeyframes = false
        }
    }
}

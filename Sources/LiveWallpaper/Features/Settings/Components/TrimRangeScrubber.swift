import AppKit
import SwiftUI

/// トリム編集用のタイムラインスクラバー。既存コードにレンジスライダー相当の部品が
/// ないため新規実装する。trimStart/trimEnd と、任意の loopStart(途中ループ)の
/// 最大3ハンドルをドラッグで操作し、実際の値の計算・クランプは呼び出し側
/// (WallpaperEditorController)に委譲する。
///
/// 秒 ↔︎ x座標 の変換はアセット全体ではなく `window`(今映している範囲)に対して
/// 行う。長い動画でもズームすればフレーム単位の操作ができる。
struct TrimRangeScrubber: View {
    let videoPath: String
    let assetDuration: Double
    /// 今映している時間範囲。
    let window: TrimTimelineWindow
    let trimStart: Double
    let trimEnd: Double
    /// 「途中からループする」がOFFなら nil(ハンドルを描かない)。
    let loopStart: Double?
    let playhead: Double
    /// キーフレーム時刻。窓の中に入るものだけを目盛りとして薄く描く。
    let keyframeTimes: [Double]
    let showsKeyframeMarkers: Bool
    let startHandleAccessibilityLabel: String
    let endHandleAccessibilityLabel: String
    let loopStartHandleAccessibilityLabel: String
    let onTrimStartChanged: (Double, Bool) -> Void
    let onTrimEndChanged: (Double, Bool) -> Void
    let onLoopStartChanged: (Double, Bool) -> Void
    let onScrub: (Double) -> Void
    /// ドラッグが終わった(= Undoの1手の区切り)。
    let onInteractionEnded: () -> Void
    /// トラックの実測幅。吸着の許容誤差を秒へ換算するのに使う。
    let onWidthChanged: (Double) -> Void
    /// ピンチによるズーム。倍率と、指の下にある時刻。
    let onZoom: (Double, Double) -> Void

    private enum Handle: Equatable {
        case start
        case end
        case loopStart
    }

    private let handleWidth: CGFloat = 12
    private let trackHeight: CGFloat = 36
    /// ハンドルは上下に少しはみ出して描く。ジェスチャーの当たり判定も同じだけ
    /// 広げないと、はみ出した部分を掴めない。
    private let handleOverhang: CGFloat = 5
    /// ハンドル同士が接近していても、ドラッグ開始位置に最も近いハンドルへ
    /// 確実にロックできるだけの当たり判定半径。
    private let handleHitRadius: CGFloat = 16

    @State private var activeDrag: TrimHandleTarget?
    @State private var filmstrip: [CGImage?] = []
    /// 今表示しているフィルムストリップが、どの動画のどの範囲のものか。
    /// 動画を切り替えた直後に前の動画のコマを見せ続けないための照合キー。
    @State private var filmstripKey: FilmstripRequest?
    @State private var magnifyBase: CGFloat = 1

    /// フィルムストリップの生成条件。`.task(id:)` に渡して、条件が変わるたびに
    /// 前の生成をキャンセルさせる(= ドラッグ中の連続再生成を自然に間引く)。
    private struct FilmstripRequest: Equatable {
        let path: String
        let start: Double
        let duration: Double
        let widthBucket: Int
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                trackBackground

                filmstripOverlay(width: width)

                keyframeTicks(width: width)

                selectedRangeOverlay(width: width)

                introRangeOverlay(width: width)

                playheadIndicator(width: width)

                handleView(
                    .start, color: .accentColor, time: trimStart, width: width,
                    label: startHandleAccessibilityLabel
                )

                handleView(
                    .end, color: .accentColor, time: trimEnd, width: width,
                    label: endHandleAccessibilityLabel
                )

                if let loopStart {
                    handleView(
                        .loopStart, color: .orange, time: loopStart, width: width,
                        label: loopStartHandleAccessibilityLabel
                    )
                }
            }
            .frame(height: trackHeight)
            // ハンドルのはみ出しぶんまで当たり判定を広げる。
            .padding(.vertical, handleOverhang)
            .contentShape(Rectangle())
            .gesture(unifiedDragGesture(width: width))
            .simultaneousGesture(magnifyGesture(width: width))
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    updateCursor(near: location.x, width: width)
                case .ended:
                    NSCursor.arrow.set()
                }
            }
            .onDisappear {
                NSCursor.arrow.set()
            }
            .onAppear {
                onWidthChanged(Double(width))
            }
            .onChange(of: width) { newWidth in
                onWidthChanged(Double(newWidth))
            }
            .task(id: filmstripRequest(width: width)) {
                await loadFilmstrip(request: filmstripRequest(width: width))
            }
        }
        .frame(height: trackHeight + handleOverhang * 2)
    }

    private var trackBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.18))
            .frame(height: trackHeight)
            .allowsHitTesting(false)
    }

    // MARK: - フィルムストリップ

    private func filmstripRequest(width: CGFloat) -> FilmstripRequest {
        FilmstripRequest(
            path: videoPath,
            start: window.start,
            duration: window.duration,
            // 幅は20ptごとに丸める。ウィンドウのリサイズ中に1ptごとの再生成が
            // 走るのを防ぐ。
            widthBucket: Int(width / 20)
        )
    }

    private func filmstripOverlay(width: CGFloat) -> some View {
        // 別の動画・別の範囲のコマは出さない(切替直後に前の動画が残らない)。
        let isCurrent = filmstripKey == filmstripRequest(width: width)
        let images = isCurrent ? filmstrip : []
        let count = max(images.count, 1)
        let tileWidth = max(width / CGFloat(count), 1)
        return HStack(spacing: 0) {
            ForEach(0 ..< images.count, id: \.self) { index in
                if let cgImage = images[index] {
                    Image(decorative: cgImage, scale: 1, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: tileWidth, height: trackHeight)
                        .clipped()
                } else {
                    Color.clear.frame(width: tileWidth, height: trackHeight)
                }
            }
        }
        .frame(width: width, height: trackHeight, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .opacity(images.isEmpty ? 0 : 1)
        .animation(.easeInOut(duration: 0.25), value: images.isEmpty)
        .allowsHitTesting(false)
    }

    private func loadFilmstrip(request: FilmstripRequest) async {
        guard window.duration > 0 else {
            return
        }
        // 条件が変わり続けている間(ドラッグ・ズーム中)は生成に入らない。
        // `.task(id:)` が古い Task をキャンセルするので、落ち着いた最後の
        // 1回だけが生き残る。
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard !Task.isCancelled else {
            return
        }
        let width = Double(max(request.widthBucket, 1) * 20)
        let frameCount = max(4, Int(width / 40))
        let images = await TrimFilmstripGenerator.generateFilmstrip(
            path: request.path,
            startTime: request.start,
            duration: request.duration,
            frameCount: frameCount,
            thumbnailHeight: trackHeight
        )
        guard !Task.isCancelled else {
            return
        }
        filmstrip = images
        filmstripKey = request
    }

    // MARK: - オーバーレイ

    /// キーフレーム位置の目盛り。吸着がONのとき、どこに吸い付くのかを見せる。
    @ViewBuilder
    private func keyframeTicks(width: CGFloat) -> some View {
        if showsKeyframeMarkers {
            // 拡大していないと目盛りが密集して黒帯になるだけなので、
            // 画面上で6pt以上離れているときだけ描く。
            let spacingPoints = averageKeyframeSpacingPoints(width: width)
            if spacingPoints >= 6 {
                ZStack(alignment: .leading) {
                    ForEach(visibleKeyframes(), id: \.self) { time in
                        if let x = xPosition(for: time, width: width) {
                            Rectangle()
                                .fill(Color.white.opacity(0.28))
                                .frame(width: 1, height: 6)
                                .offset(x: x, y: -trackHeight / 2 + 3)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func visibleKeyframes() -> [Double] {
        keyframeTimes.filter { $0 >= window.start && $0 <= window.end }
    }

    private func averageKeyframeSpacingPoints(width: CGFloat) -> Double {
        let visible = visibleKeyframes()
        guard visible.count > 1 else {
            return .greatestFiniteMagnitude
        }
        return Double(width) / Double(visible.count - 1)
    }

    private func selectedRangeOverlay(width: CGFloat) -> some View {
        let startX = clampedX(for: trimStart, width: width)
        let endX = clampedX(for: trimEnd, width: width)
        return RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor.opacity(0.28))
            .frame(width: max(endX - startX, 0), height: trackHeight)
            .offset(x: startX)
            .allowsHitTesting(false)
    }

    /// 初回だけ再生される区間(カット開始位置 ... ループ開始位置)。2周目以降は
    /// 通らないことが一目で分かるよう、ループ区間とは違う色で薄く重ねる。
    @ViewBuilder
    private func introRangeOverlay(width: CGFloat) -> some View {
        if let loopStart, loopStart > trimStart {
            let startX = clampedX(for: trimStart, width: width)
            let endX = clampedX(for: loopStart, width: width)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.22))
                .frame(width: max(endX - startX, 0), height: trackHeight)
                .offset(x: startX)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func playheadIndicator(width: CGFloat) -> some View {
        if let x = xPosition(for: playhead, width: width) {
            Rectangle()
                .fill(Color.white.opacity(0.9))
                .frame(width: 2, height: trackHeight + 6)
                .offset(x: x - 1, y: -3)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func handleView(
        _ handle: Handle,
        color: Color,
        time: Double,
        width: CGFloat,
        label: String
    ) -> some View {
        if let x = xPosition(for: time, width: width) {
            handleShape(for: handle)
                .fill(color)
                .frame(width: handleWidth, height: trackHeight + handleOverhang * 2)
                .shadow(radius: 1)
                .offset(x: x - handleWidth / 2)
                .accessibilityElement()
                .accessibilityLabel(label)
                .accessibilityValue(timeAccessibilityValue(for: handle))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment:
                        nudge(handle, by: nudgeStep)
                    case .decrement:
                        nudge(handle, by: -nudgeStep)
                    @unknown default:
                        break
                    }
                }
        }
    }

    /// Final Cut Pro的な「選択範囲の内側がフラット・外側が丸い」ブラケット形状にして、
    /// start/endを色だけでなく形でも区別できるようにする。ループ開始位置は範囲の
    /// 境界ではなく区間内のマーカーなので、左右対称の丸いつまみにする。
    private func handleShape(for handle: Handle) -> UnevenRoundedRectangle {
        let round = handleWidth / 2
        let flat: CGFloat = 3
        switch handle {
        case .loopStart:
            return UnevenRoundedRectangle(
                topLeadingRadius: round,
                bottomLeadingRadius: round,
                bottomTrailingRadius: round,
                topTrailingRadius: round
            )
        case .start:
            return UnevenRoundedRectangle(
                topLeadingRadius: round,
                bottomLeadingRadius: round,
                bottomTrailingRadius: flat,
                topTrailingRadius: flat
            )
        case .end:
            return UnevenRoundedRectangle(
                topLeadingRadius: flat,
                bottomLeadingRadius: flat,
                bottomTrailingRadius: round,
                topTrailingRadius: round
            )
        }
    }

    // MARK: - 座標変換

    /// 窓の外にある時刻は nil。ハンドルを端に貼り付けて描くと、実際とは違う
    /// 位置にあるように見えてドラッグ先も嘘になるため、いっそ描かない
    /// (全体を見たければズームアウトするか、上の全体バーを使う)。
    private func xPosition(for time: Double, width: CGFloat) -> CGFloat? {
        guard time.isFinite, window.duration > 0 else {
            return nil
        }
        let ratio = window.ratio(forTime: time)
        guard ratio >= -0.001, ratio <= 1.001 else {
            return nil
        }
        return CGFloat(min(max(ratio, 0), 1)) * width
    }

    /// 帯(選択範囲)の描画用。こちらは窓の外でも端でクランプしてよい
    /// — 範囲が画面いっぱいに続いていることを示すのが正しい表現なので。
    private func clampedX(for time: Double, width: CGFloat) -> CGFloat {
        guard time.isFinite, window.duration > 0 else {
            return 0
        }
        return CGFloat(min(max(window.ratio(forTime: time), 0), 1)) * width
    }

    private func time(atX x: CGFloat, width: CGFloat) -> Double {
        let ratio = min(max(Double(x / max(width, 1)), 0), 1)
        return min(max(window.time(atRatio: ratio), 0), max(assetDuration, 0))
    }

    private func currentValue(for handle: Handle) -> Double {
        switch handle {
        case .start: return trimStart
        case .end: return trimEnd
        case .loopStart: return loopStart ?? trimStart
        }
    }

    private func timeAccessibilityValue(for handle: Handle) -> String {
        let seconds = max(currentValue(for: handle), 0)
        let minutes = Int(seconds) / 60
        let secs = seconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%d:%04.1f", minutes, secs)
    }

    // MARK: - ジェスチャー

    /// トラック全体に1本だけ付けるドラッグジェスチャー。ドラッグ開始位置に最も
    /// 近いハンドルをその場で確定して以後の移動全てをロックするため、ハンドル同士が
    /// 重なっていても z-order に関係なく意図したハンドルだけを動かせる
    /// (以前は各ハンドルが個別に `.gesture` を持ち、重なった領域は常に最後に
    /// 描画されたハンドルへ吸われて掴めなかった)。
    private func unifiedDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard assetDuration > 0, width > 0 else {
                    return
                }
                let target = activeDrag ?? resolveDragTarget(
                    at: value.startLocation.x,
                    width: width
                )
                if activeDrag == nil {
                    activeDrag = target
                    NSCursor.resizeLeftRight.set()
                }
                let time = time(atX: value.location.x, width: width)
                switch target {
                case .start:
                    onTrimStartChanged(time, true)
                case .end:
                    onTrimEndChanged(time, true)
                case .loopStart:
                    onLoopStartChanged(time, true)
                case .track:
                    onScrub(time)
                }
            }
            .onEnded { value in
                activeDrag = nil
                onInteractionEnded()
                updateCursor(near: value.location.x, width: width)
            }
    }

    /// トラックボードのピンチでズーム。指の下の時刻を軸にする。
    private func magnifyGesture(width: CGFloat) -> some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                guard assetDuration > 0, scale.isFinite, scale > 0 else {
                    return
                }
                let factor = Double(scale / max(magnifyBase, 0.01))
                magnifyBase = scale
                guard factor.isFinite, abs(factor - 1) > 0.001 else {
                    return
                }
                onZoom(factor, playheadAnchor())
            }
            .onEnded { _ in
                magnifyBase = 1
            }
    }

    /// ピンチの軸。マウス位置は MagnificationGesture からは取れないので、
    /// 窓の中に再生位置があればそれを、無ければ窓の中心を使う。
    private func playheadAnchor() -> Double {
        window.contains(playhead) ? playhead : window.start + window.duration / 2
    }

    private func resolveDragTarget(at x: CGFloat, width: CGFloat) -> TrimHandleTarget {
        TrimHandleHitTester.resolve(
            at: x,
            trimStartX: xPosition(for: trimStart, width: width),
            trimEndX: xPosition(for: trimEnd, width: width),
            loopStartX: loopStart.flatMap { xPosition(for: $0, width: width) },
            hitRadius: handleHitRadius
        )
    }

    private func updateCursor(near x: CGFloat, width: CGFloat) {
        if resolveDragTarget(at: x, width: width) == .track {
            NSCursor.arrow.set()
        } else {
            NSCursor.resizeLeftRight.set()
        }
    }

    // MARK: - VoiceOver 値調整

    /// VoiceOver の値調整1ステップ。表示中の窓の1/200 を目安にしつつ、
    /// 細かすぎ/粗すぎにならない範囲へ収める。
    private var nudgeStep: Double {
        min(max(window.duration / 200, 1.0 / 120.0), 1.0)
    }

    private func nudge(_ handle: Handle, by delta: Double) {
        switch handle {
        case .start:
            onTrimStartChanged(trimStart + delta, false)
        case .end:
            onTrimEndChanged(trimEnd + delta, false)
        case .loopStart:
            onLoopStartChanged((loopStart ?? trimStart) + delta, false)
        }
        onInteractionEnded()
    }
}

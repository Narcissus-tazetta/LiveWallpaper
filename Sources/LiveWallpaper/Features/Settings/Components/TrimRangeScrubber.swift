import AppKit
import SwiftUI

/// トリム編集用のタイムラインスクラバー。既存コードにレンジスライダー相当の部品が
/// ないため新規実装する。trimStart/trimEnd と、任意の loopStart(途中ループ)の
/// 最大3ハンドルをドラッグで操作し、実際の値の計算・クランプは呼び出し側
/// (WallpaperEditorController)に委譲する。
struct TrimRangeScrubber: View {
    let videoPath: String
    let duration: Double
    let trimStart: Double
    let trimEnd: Double
    /// 「途中からループする」がOFFなら nil(ハンドルを描かない)。
    let loopStart: Double?
    let playhead: Double
    let startHandleAccessibilityLabel: String
    let endHandleAccessibilityLabel: String
    let loopStartHandleAccessibilityLabel: String
    let onTrimStartChanged: (Double) -> Void
    let onTrimEndChanged: (Double) -> Void
    let onLoopStartChanged: (Double) -> Void
    let onScrub: (Double) -> Void

    private enum Handle: Equatable {
        case start
        case end
        case loopStart
    }

    private let handleWidth: CGFloat = 12
    private let trackHeight: CGFloat = 36
    /// ハンドル同士が接近していても、ドラッグ開始位置に最も近いハンドルへ
    /// 確実にロックできるだけの当たり判定半径。
    private let handleHitRadius: CGFloat = 16
    /// VoiceOver の値調整1ステップ(≒1フレーム)。
    private let nudgeStep: Double = 1.0 / 30.0

    @State private var activeDrag: TrimHandleTarget?
    @State private var filmstrip: [CGImage?] = []

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                trackBackground

                filmstripOverlay(width: width)

                selectedRangeOverlay(width: width)

                introRangeOverlay(width: width)

                playheadIndicator(width: width)

                handleView(
                    .start, color: .accentColor, x: xPosition(for: trimStart, width: width),
                    label: startHandleAccessibilityLabel
                )

                handleView(
                    .end, color: .accentColor, x: xPosition(for: trimEnd, width: width),
                    label: endHandleAccessibilityLabel
                )

                if let loopStart {
                    handleView(
                        .loopStart, color: .orange, x: xPosition(for: loopStart, width: width),
                        label: loopStartHandleAccessibilityLabel
                    )
                }
            }
            .frame(height: trackHeight)
            .contentShape(Rectangle())
            .gesture(unifiedDragGesture(width: width))
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
            .task(id: videoPath) {
                await loadFilmstrip(width: width)
            }
        }
        .frame(height: trackHeight)
    }

    private var trackBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.18))
            .frame(height: trackHeight)
            .allowsHitTesting(false)
    }

    private func filmstripOverlay(width: CGFloat) -> some View {
        let count = max(filmstrip.count, 1)
        let tileWidth = max(width / CGFloat(count), 1)
        return HStack(spacing: 0) {
            ForEach(0 ..< filmstrip.count, id: \.self) { index in
                if let cgImage = filmstrip[index] {
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
        .opacity(filmstrip.isEmpty ? 0 : 1)
        .animation(.easeInOut(duration: 0.25), value: filmstrip.isEmpty)
        .allowsHitTesting(false)
    }

    private func selectedRangeOverlay(width: CGFloat) -> some View {
        let startX = xPosition(for: trimStart, width: width)
        let endX = xPosition(for: trimEnd, width: width)
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
            let startX = xPosition(for: trimStart, width: width)
            let endX = xPosition(for: loopStart, width: width)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.22))
                .frame(width: max(endX - startX, 0), height: trackHeight)
                .offset(x: startX)
                .allowsHitTesting(false)
        }
    }

    private func playheadIndicator(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.9))
            .frame(width: 2, height: trackHeight + 6)
            .offset(x: xPosition(for: playhead, width: width) - 1, y: -3)
            .allowsHitTesting(false)
    }

    private func handleView(
        _ handle: Handle,
        color: Color,
        x: CGFloat,
        label: String
    ) -> some View {
        handleShape(for: handle)
            .fill(color)
            .frame(width: handleWidth, height: trackHeight + 10)
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

    private func xPosition(for time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else {
            return 0
        }
        let ratio = min(max(time / duration, 0), 1)
        return CGFloat(ratio) * width
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
                guard duration > 0, width > 0 else {
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
                let ratio = min(max(value.location.x / width, 0), 1)
                let time = ratio * duration
                switch target {
                case .start:
                    onTrimStartChanged(time)
                case .end:
                    onTrimEndChanged(time)
                case .loopStart:
                    onLoopStartChanged(time)
                case .track:
                    onScrub(time)
                }
            }
            .onEnded { value in
                activeDrag = nil
                updateCursor(near: value.location.x, width: width)
            }
    }

    private func resolveDragTarget(at x: CGFloat, width: CGFloat) -> TrimHandleTarget {
        TrimHandleHitTester.resolve(
            at: x,
            trimStartX: xPosition(for: trimStart, width: width),
            trimEndX: xPosition(for: trimEnd, width: width),
            loopStartX: loopStart.map { xPosition(for: $0, width: width) },
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

    private func nudge(_ handle: Handle, by delta: Double) {
        switch handle {
        case .start:
            onTrimStartChanged(trimStart + delta)
        case .end:
            onTrimEndChanged(trimEnd + delta)
        case .loopStart:
            onLoopStartChanged((loopStart ?? trimStart) + delta)
        }
    }

    // MARK: - フィルムストリップ

    private func loadFilmstrip(width: CGFloat) async {
        guard duration > 0 else {
            return
        }
        let frameCount = max(4, Int(width / 40))
        let images = await TrimFilmstripGenerator.generateFilmstrip(
            path: videoPath,
            duration: duration,
            frameCount: frameCount,
            thumbnailHeight: trackHeight
        )
        guard !Task.isCancelled else {
            return
        }
        filmstrip = images
    }
}

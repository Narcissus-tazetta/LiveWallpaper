import SwiftUI

/// トリム編集用のタイムラインスクラバー。既存コードにレンジスライダー相当の部品が
/// ないため新規実装する。trimStart/trimEnd/loopStart(任意)の3ハンドルをドラッグで
/// 操作し、実際の値の計算・クランプは呼び出し側(WallpaperEditorController)に委譲する。
struct TrimRangeScrubber: View {
    let duration: Double
    let trimStart: Double
    let trimEnd: Double
    let loopStart: Double?
    let playhead: Double
    let onTrimStartChanged: (Double) -> Void
    let onTrimEndChanged: (Double) -> Void
    let onLoopStartChanged: (Double) -> Void

    private let handleWidth: CGFloat = 12
    private let trackHeight: CGFloat = 36

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: trackHeight)

                selectedRangeOverlay(width: width)

                playheadIndicator(width: width)

                handle(color: .accentColor, x: xPosition(for: trimStart, width: width))
                    .gesture(dragGesture(width: width) { time in
                        onTrimStartChanged(time)
                    })

                handle(color: .accentColor, x: xPosition(for: trimEnd, width: width))
                    .gesture(dragGesture(width: width) { time in
                        onTrimEndChanged(time)
                    })

                if let loopStart {
                    handle(color: .orange, x: xPosition(for: loopStart, width: width))
                        .gesture(dragGesture(width: width) { time in
                            onLoopStartChanged(time)
                        })
                }
            }
            .frame(height: trackHeight)
        }
        .frame(height: trackHeight)
    }

    private func selectedRangeOverlay(width: CGFloat) -> some View {
        let startX = xPosition(for: trimStart, width: width)
        let endX = xPosition(for: trimEnd, width: width)
        return RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor.opacity(0.28))
            .frame(width: max(endX - startX, 0), height: trackHeight)
            .offset(x: startX)
    }

    private func playheadIndicator(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.9))
            .frame(width: 2, height: trackHeight + 6)
            .offset(x: xPosition(for: playhead, width: width) - 1, y: -3)
            .allowsHitTesting(false)
    }

    private func handle(color: Color, x: CGFloat) -> some View {
        Capsule()
            .fill(color)
            .frame(width: handleWidth, height: trackHeight + 10)
            .shadow(radius: 1)
            .offset(x: x - handleWidth / 2)
            .contentShape(Rectangle().size(width: handleWidth + 12, height: trackHeight + 10))
    }

    private func xPosition(for time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else {
            return 0
        }
        let ratio = min(max(time / duration, 0), 1)
        return CGFloat(ratio) * width
    }

    private func dragGesture(width: CGFloat, onChange: @escaping (Double) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard duration > 0, width > 0 else {
                    return
                }
                let ratio = min(max(value.location.x / width, 0), 1)
                onChange(ratio * duration)
            }
    }
}

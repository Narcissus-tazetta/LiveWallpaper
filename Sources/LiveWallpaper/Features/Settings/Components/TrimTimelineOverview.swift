import SwiftUI

/// タイムラインを拡大しているときに出す、動画全体の俯瞰バー。
///
/// 拡大すると「今どのあたりを見ているのか」「カット範囲は画面外のどこにあるのか」
/// が分からなくなる。全体を1本の帯として常に見せ、ドラッグで一気に移動できる
/// ようにすることで、ズームを実用的な機能にするための相棒。
struct TrimTimelineOverview: View {
    let assetDuration: Double
    let window: TrimTimelineWindow
    let trimStart: Double
    let trimEnd: Double
    let loopStart: Double?
    let playhead: Double
    let accessibilityLabel: String
    /// 表示範囲の中心をこの時刻へ移動する。
    let onCenter: (Double) -> Void

    private let barHeight: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.18))

                // カット範囲
                Rectangle()
                    .fill(Color.accentColor.opacity(0.45))
                    .frame(width: max(x(trimEnd, width) - x(trimStart, width), 1))
                    .offset(x: x(trimStart, width))

                if let loopStart {
                    Rectangle()
                        .fill(Color.orange.opacity(0.8))
                        .frame(width: 2)
                        .offset(x: x(loopStart, width) - 1)
                }

                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 1)
                    .offset(x: x(playhead, width))

                // 今映している範囲
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.primary.opacity(0.75), lineWidth: 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(0.12))
                    )
                    .frame(width: max(x(window.end, width) - x(window.start, width), 6))
                    .offset(x: x(window.start, width))
            }
            .frame(height: barHeight)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard assetDuration > 0 else {
                            return
                        }
                        let ratio = min(max(Double(value.location.x / width), 0), 1)
                        onCenter(ratio * assetDuration)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabel)
        }
        .frame(height: barHeight)
    }

    private func x(_ time: Double, _ width: CGFloat) -> CGFloat {
        guard assetDuration > 0, time.isFinite else {
            return 0
        }
        return CGFloat(min(max(time / assetDuration, 0), 1)) * width
    }
}

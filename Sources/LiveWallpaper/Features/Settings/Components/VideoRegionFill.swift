import SwiftUI

extension View {
    /// Lays out a view of the whole video so that `region` (video UV, origin top-left)
    /// fills the available space, as on a screen with the same crop.
    func showingVideoRegion(_ region: CGRect, videoAspectRatio: Double) -> some View {
        GeometryReader { geo in
            let regionWidth = max(Double(region.width) * videoAspectRatio, 0.0001)
            let regionHeight = max(Double(region.height), 0.0001)
            let scale = max(Double(geo.size.width) / regionWidth, Double(geo.size.height) / regionHeight)
            let size = CGSize(width: videoAspectRatio * scale, height: scale)
            self
                .frame(width: size.width, height: size.height)
                .offset(
                    x: geo.size.width / 2 - region.midX * size.width,
                    y: geo.size.height / 2 - region.midY * size.height
                )
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .clipped()
    }
}

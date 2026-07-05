import SwiftUI

struct WebWallpaperThumbnailView: View {
    let source: WebWallpaperSource
    let isActive: Bool
    @ObservedObject var thumbnailStore: WebWallpaperThumbnailStore
    var width: CGFloat = 64
    var height: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))

            if let image = thumbnailStore.image(for: source.id) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isActive ? .accentColor : .secondary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .onAppear {
            thumbnailStore.loadIfNeeded(for: source)
        }
    }
}

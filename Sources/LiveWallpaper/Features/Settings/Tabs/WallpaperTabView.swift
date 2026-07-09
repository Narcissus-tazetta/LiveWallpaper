import SwiftUI

struct WallpaperTabView<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        Section {
            content
        }
    }
}

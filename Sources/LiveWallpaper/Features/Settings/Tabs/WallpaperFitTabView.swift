import SwiftUI

struct WallpaperFitTabView<Editor: View, Library: View>: View {
    let title: String
    @ViewBuilder let editor: Editor
    @ViewBuilder let library: Library

    var body: some View {
        Section {
            editor
            library
        }
    }
}

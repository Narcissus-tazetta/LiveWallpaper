import SwiftUI

struct WallpaperTabView<Library: View, Playlist: View>: View {
    let title: String
    @ViewBuilder let library: Library
    @ViewBuilder let playlist: Playlist

    var body: some View {
        Section(header: Label(title, systemImage: "photo.on.rectangle")) {
            library
            playlist
        }
    }
}

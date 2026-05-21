import SwiftUI

struct SettingsRootView: View {
    @ObservedObject var model: WallpaperModel

    var body: some View {
        SettingsView(model: model)
            .environment(\.locale, model.appLocale)
    }
}

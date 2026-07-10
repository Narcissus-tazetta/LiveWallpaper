import SwiftUI

extension SettingsView {
    var webWallpaperSettingsSection: some View {
        Section(header: Label(model.localizedString("Web壁紙"), systemImage: "globe")) {
            Toggle(
                model.localizedString("Web壁紙機能を有効にする"),
                isOn: webWallpaperFeatureBinding
            )

            Text(model.localizedString("オンにすると壁紙タブの一覧にWeb壁紙を追加できるようになります。実験的な機能です。"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    func submitWebWallpaperURL() {
        do {
            _ = try model.addWebWallpaper(urlString: webURLInput)
            webURLInput = ""
            isWebWallpaperURLPopoverPresented = false
        } catch {
            if let urlError = error as? WebWallpaperURLError {
                model.webWallpaperErrorMessage = model.localizedString(
                    urlError.errorDescription ?? error.localizedDescription
                )
            } else {
                model.webWallpaperErrorMessage = error.localizedDescription
            }
        }
    }
}

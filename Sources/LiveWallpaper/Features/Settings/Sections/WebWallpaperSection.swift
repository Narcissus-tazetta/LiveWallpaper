import AppKit
import SwiftUI

extension SettingsView {
    static let webWallpaperSearchKeywords: [String] = [
        "Web壁紙",
        "Web壁紙機能を有効にする",
        "URL",
    ]

    var webWallpaperSettingsSection: some View {
        Section(header: SettingsSectionHeader(title: model.localizedString("Web壁紙"))) {
            Toggle(
                model.localizedString("Web壁紙機能を有効にする"),
                isOn: webWallpaperFeatureBinding
            )

            Text(model.localizedString("オンにすると壁紙タブの一覧にWeb壁紙を追加できるようになります。実験的な機能です。"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    func chooseWebWallpaperFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if await model.addLocalWebWallpaper(folder: url) {
                    isWebWallpaperURLPopoverPresented = false
                    isEmptyStateWebPopoverPresented = false
                }
            }
        }
    }

    func submitWebWallpaperURL() {
        do {
            _ = try model.addWebWallpaper(urlString: webURLInput)
            webURLInput = ""
            isWebWallpaperURLPopoverPresented = false
            isEmptyStateWebPopoverPresented = false
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

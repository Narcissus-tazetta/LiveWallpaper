import SwiftUI

extension SettingsView {
    func submitWebWallpaperURL() {
        do {
            _ = try model.addWebWallpaper(urlString: webURLInput)
            webURLInput = ""
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

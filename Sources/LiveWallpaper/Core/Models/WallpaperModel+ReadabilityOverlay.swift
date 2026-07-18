import Foundation

@MainActor
extension WallpaperModel {
    func setDesktopReadabilityDimOpacity(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        guard abs(desktopReadabilityDimOpacity - clamped) > 0.001 else {
            return
        }
        desktopReadabilityDimOpacity = clamped
        UserDefaults.standard.set(clamped, forKey: "desktopReadabilityDimOpacity")
        applyDesktopReadabilityDimState()
    }

    func applyDesktopReadabilityDimState() {
        let opacity = CGFloat(desktopReadabilityDimOpacity)
        for index in playerViews.indices {
            playerViews[index].readabilityDimOpacity = opacity
        }
        for index in webPlayerViews.indices {
            webPlayerViews[index].readabilityDimOpacity = opacity
        }
    }
}

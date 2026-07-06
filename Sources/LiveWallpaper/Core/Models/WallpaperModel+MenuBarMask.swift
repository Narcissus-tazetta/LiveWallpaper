import AppKit
import Foundation

@MainActor
extension WallpaperModel {
    func setMenuBarOpaqueEnabled(_ enabled: Bool) {
        guard menuBarOpaqueEnabled != enabled else {
            return
        }
        UserDefaults.standard.set(enabled, forKey: "menuBarOpaqueEnabled")
        menuBarOpaqueEnabled = enabled
        applyMenuBarMaskState()
    }

    func refreshMenuBarAutoHideState() {
        // Goes through applyMenuBarMaskState() rather than just updating the published flag,
        // so the on-screen mask strip is reconciled immediately instead of waiting for the
        // next unrelated window rebuild.
        applyMenuBarMaskState()
    }

    func isMenuBarAutoHideEnabled() -> Bool {
        // "_HIHideMenuBar" is the same NSGlobalDomain key backing
        // `defaults read -g _HIHideMenuBar`; UserDefaults.standard cascades into the
        // global domain so this stays within public API even though the key is private.
        UserDefaults.standard.bool(forKey: "_HIHideMenuBar")
    }

    // Bakes the "opaque menu bar" strip into the existing wallpaper windows' own content
    // instead of layering a separate NSWindow on top: a standalone window would have to
    // compete with the real menu bar's own status-item windows for the same window level
    // (and can end up drawn in front of the clock/icons), and closing/recreating such a
    // window turned out to be a use-after-free hazard. Painting inside the wallpaper's own
    // desktop-level window sidesteps both problems since it never changes window ordering.
    func applyMenuBarMaskState() {
        menuBarAutoHideDetected = isMenuBarAutoHideEnabled()
        let maskEnabled = menuBarOpaqueEnabled && !menuBarAutoHideDetected
        let screens = targetScreens()

        for index in playerViews.indices {
            let screen = index < screens.count ? screens[index] : nil
            playerViews[index].menuBarMaskHeight = menuBarMaskHeight(for: screen, enabled: maskEnabled)
        }
        for index in webPlayerViews.indices {
            let screen = index < screens.count ? screens[index] : nil
            webPlayerViews[index].menuBarMaskHeight = menuBarMaskHeight(for: screen, enabled: maskEnabled)
        }
    }

    private func menuBarMaskHeight(for screen: NSScreen?, enabled: Bool) -> CGFloat {
        guard enabled, let screen else {
            return 0
        }
        return max(screen.frame.maxY - screen.visibleFrame.maxY, 0)
    }
}

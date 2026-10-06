import Foundation

/// User pause (menu, global shortcut, URL scheme).
///
/// Implemented like Reduce Motion: a whole-screen freeze is added on top of the
/// coverage result, so freeze frames, deep suspend, web wallpapers and dedicated
/// per-display players all stop through their existing paths. Not persisted: the
/// wallpaper plays again after a relaunch.
@MainActor
extension WallpaperModel {
    func setManualPauseActive(_ paused: Bool) {
        guard manualPauseActive != paused else {
            return
        }
        manualPauseActive = paused
        AppLog.suspend.debug("manual pause -> \(paused)")
        evaluateForegroundCoverageState()
    }

    func toggleManualPause() {
        setManualPauseActive(!manualPauseActive)
    }

    /// Reasons to freeze every screen regardless of coverage (Reduce Motion, user
    /// pause, the battery freeze policy). They override the per-display
    /// "never auto-pause" exclusions.
    func forcedFreezeDisplayIDs() -> Set<String> {
        forcedFreezeActive ? allWallpaperDisplayIDs() : []
    }

    var forcedFreezeActive: Bool {
        reduceMotionFreezeActive || manualPauseActive || batteryFreezeActive
    }
}

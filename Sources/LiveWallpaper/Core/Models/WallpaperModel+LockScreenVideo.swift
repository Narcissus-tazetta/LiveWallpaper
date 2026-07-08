import Foundation

@MainActor
extension WallpaperModel {
    private static let lockScreenVideoPathKey = "lockScreenVideoPath"
    private static let lockScreenVideoPathMigratedKey = "lockScreenVideoPathMigrated"

    var effectiveLockScreenVideoPath: String? {
        Self.validatedVideoPath(lockScreenVideoPath)
    }

    func restoreLockScreenVideoPath() {
        migrateLockScreenVideoPathIfNeeded()
    }

    func migrateLockScreenVideoPathIfNeeded() {
        if UserDefaults.standard.bool(forKey: Self.lockScreenVideoPathMigratedKey) {
            if let saved = UserDefaults.standard.string(forKey: Self.lockScreenVideoPathKey) {
                lockScreenVideoPath = Self.validatedVideoPath(saved)
                if lockScreenVideoPath == nil {
                    UserDefaults.standard.removeObject(forKey: Self.lockScreenVideoPathKey)
                }
            } else {
                lockScreenVideoPath = nil
            }
            return
        }

        if UserDefaults.standard.object(forKey: Self.lockScreenVideoPathKey) == nil,
           let desktopPath = currentVideoPath,
           let validatedDesktop = Self.validatedVideoPath(desktopPath)
        {
            lockScreenVideoPath = validatedDesktop
            UserDefaults.standard.set(validatedDesktop, forKey: Self.lockScreenVideoPathKey)
        } else if let saved = UserDefaults.standard.string(forKey: Self.lockScreenVideoPathKey),
                  let validated = Self.validatedVideoPath(saved)
        {
            lockScreenVideoPath = validated
        } else {
            lockScreenVideoPath = nil
            UserDefaults.standard.removeObject(forKey: Self.lockScreenVideoPathKey)
        }

        UserDefaults.standard.set(true, forKey: Self.lockScreenVideoPathMigratedKey)
    }

    func selectLockScreenVideo(path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        guard let validated = Self.validatedVideoPath(trimmed) else {
            clearLockScreenVideoIfMissing(path: trimmed)
            return
        }
        lockScreenVideoPath = validated
        UserDefaults.standard.set(validated, forKey: Self.lockScreenVideoPathKey)
        if lockScreenSyncEnabled {
            syncCurrentVideoToLockScreen()
        }
    }

    // Lock-screen sync always reads `currentVideoPath` (the original file), never a
    // lightweight-mode proxy — the lock screen should keep full source quality
    // regardless of the desktop wallpaper's lightweight setting.
    func applyLockScreenVideoSameAsDesktop() {
        guard let desktopPath = currentVideoPath,
              let validated = Self.validatedVideoPath(desktopPath)
        else {
            return
        }
        selectLockScreenVideo(path: validated)
    }

    func clearLockScreenVideoIfMissing(path: String) {
        guard lockScreenVideoPath == path else {
            return
        }
        lockScreenVideoPath = nil
        UserDefaults.standard.removeObject(forKey: Self.lockScreenVideoPathKey)
        releaseLockScreenBorrowIfNeeded()
    }

    nonisolated static func validatedVideoPath(_ path: String?) -> String? {
        guard let path,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              FileManager.default.fileExists(atPath: path)
        else {
            return nil
        }
        return path
    }
}

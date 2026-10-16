import Foundation

/// Wallpapers that a running provider app lends to the desktop. They ride on the
/// dedicated-player override path (`resolvedOverridePath`) instead of the library, so
/// nothing about them reaches the saved state, the lock screen or the screen saver, and
/// the user's own choice comes back untouched when the provider goes away.
@MainActor
extension WallpaperModel {
    func startExternalWallpaperMonitoring() {
        importedExternalWallpaperPaths = UserDefaults.standard
            .dictionary(forKey: PrefsKey.importedExternalWallpapers) as? [String: String] ?? [:]
        let monitor = ExternalWallpaperProviderMonitor { [weak self] wallpapers in
            self?.updateExternalWallpapers(wallpapers)
        }
        externalWallpaperMonitor = monitor
        monitor.start()
    }

    var activeExternalWallpaper: ExternalWallpaper? {
        guard let id = activeExternalWallpaperID else {
            return nil
        }
        return externalWallpapers.first { $0.id == id }
    }

    /// Overrides apply only to video windows; a web wallpaper has no player to swap.
    var canShowExternalWallpaper: Bool {
        !isWebWallpaperActive
    }

    /// The library copy of an external wallpaper, while the user keeps it.
    func libraryPath(forExternalWallpaperID id: String) -> String? {
        guard let path = importedExternalWallpaperPaths[id], libraryVideoPaths.contains(path) else {
            return nil
        }
        return path
    }

    /// Copies the wallpaper into the app's own folder and registers it like any other
    /// video, so it stays after the provider quits.
    @discardableResult
    func importExternalWallpaper(id: String) async -> Bool {
        guard importingExternalWallpaperID == nil,
              libraryPath(forExternalWallpaperID: id) == nil,
              let wallpaper = externalWallpapers.first(where: { $0.id == id })
        else {
            return false
        }
        importingExternalWallpaperID = id
        failedExternalWallpaperImportID = nil
        defer { importingExternalWallpaperID = nil }
        guard let localURL =
            await importVideoToAppSupport(from: URL(fileURLWithPath: wallpaper.path)),
            addVideoPathToLibrary(localURL.path, preferredDisplayName: wallpaper.name)
        else {
            AppLog.externalWallpapers.error("could not add \(id, privacy: .public) to the library")
            failedExternalWallpaperImportID = id
            return false
        }
        importedExternalWallpaperPaths[id] = localURL.path
        UserDefaults.standard.set(
            importedExternalWallpaperPaths,
            forKey: PrefsKey.importedExternalWallpapers
        )
        stopExternalWallpaper()
        selectRegisteredVideo(path: localURL.path)
        return true
    }

    func showExternalWallpaper(id: String) {
        guard canShowExternalWallpaper, externalWallpapers.contains(where: { $0.id == id }),
              activeExternalWallpaperID != id
        else {
            return
        }
        let previousPath = activeExternalWallpaper?.path
        performDisplayAssignmentTransition {
            activeExternalWallpaperID = id
            if let previousPath {
                evictExternalSlots(path: previousPath)
            }
            applySuspensionStateToPlayers()
            scheduleDedicatedWarmWindowReconciliation()
        }
    }

    func stopExternalWallpaper() {
        guard activeExternalWallpaperID != nil else {
            return
        }
        let path = activeExternalWallpaper?.path
        performDisplayAssignmentTransition {
            activeExternalWallpaperID = nil
            if let path {
                evictExternalSlots(path: path)
            }
            applySuspensionStateToPlayers()
            scheduleDedicatedWarmWindowReconciliation()
        }
    }

    func updateExternalWallpapers(_ wallpapers: [ExternalWallpaper]) {
        guard wallpapers != externalWallpapers else {
            return
        }
        let active = activeExternalWallpaper
        if let active, !wallpapers.contains(active) {
            performDisplayAssignmentTransition {
                externalWallpapers = wallpapers
                activeExternalWallpaperID = nil
                evictExternalSlots(path: active.path)
                applySuspensionStateToPlayers()
                scheduleDedicatedWarmWindowReconciliation()
            }
        } else {
            externalWallpapers = wallpapers
        }
    }

    /// Drops the dedicated players opened for an external wallpaper, except on screens
    /// whose own saved assignment happens to be the same file.
    private func evictExternalSlots(path: String) {
        for screenID in Array(dedicatedSlotsByScreenID.keys)
            where resolvedSavedOverridePath(forScreenID: screenID) != path
        {
            if dedicatedSlotsByScreenID[screenID]?[path] != nil {
                evictDedicatedSlot(forScreenID: screenID, path: path)
            }
        }
    }
}

import Foundation

/// Wallpapers that a running provider app lends to the desktop. They ride on the
/// dedicated-player override path (`resolvedOverridePath`) instead of the library, so
/// nothing about them reaches the saved state, the lock screen or the screen saver, and
/// the user's own choice comes back untouched when the provider goes away.
@MainActor
extension WallpaperModel {
    func startExternalWallpaperMonitoring() {
        // Bakes from the last run belong to providers that are gone or will offer
        // them again; either way they are made afresh.
        removeBakedExternalScenes(at: ExternalWallpaperProviderMonitor.bakedScenesDirectoryURL)
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

    /// A scene can be shown or added once LiveWallpaper has baked it.
    func isExternalWallpaperReady(_ wallpaper: ExternalWallpaper) -> Bool {
        !wallpaper.isScene || readyExternalScenes[wallpaper.id] == wallpaper.sceneRevision
    }

    func isPreparingExternalScene(_ wallpaper: ExternalWallpaper) -> Bool {
        wallpaper.isScene && externalScenePreparations[wallpaper.id] != nil
    }

    func didFailToPrepareExternalScene(_ wallpaper: ExternalWallpaper) -> Bool {
        wallpaper.isScene && failedExternalScenes[wallpaper.id] == wallpaper.sceneRevision
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
              let wallpaper = externalWallpapers.first(where: { $0.id == id }),
              isExternalWallpaperReady(wallpaper)
        else {
            return false
        }
        importingExternalWallpaperID = id
        failedExternalWallpaperImportID = nil
        defer { importingExternalWallpaperID = nil }
        guard let localURL = await importVideoToAppSupport(from: URL(fileURLWithPath: wallpaper.path)) else {
            AppLog.externalWallpapers.error("could not add \(id, privacy: .public) to the library")
            failedExternalWallpaperImportID = id
            return false
        }
        // The scene goes in beside the copied video before the library sees it, so
        // the library never holds the video without its scene.
        var scene: SceneDocument?
        if wallpaper.isScene {
            do {
                scene = try SceneStore.importScene(
                    from: SceneStore.folderURL(forVideoPath: wallpaper.path), videoPath: localURL.path
                )
            } catch {
                AppLog.externalWallpapers.error(
                    "could not copy the scene of \(id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                removeLeftovers(of: [localURL, SceneStore.folderURL(forVideoPath: localURL.path)])
                failedExternalWallpaperImportID = id
                return false
            }
        }
        guard addVideoPathToLibrary(localURL.path, preferredDisplayName: wallpaper.name) else {
            AppLog.externalWallpapers.error("could not add \(id, privacy: .public) to the library")
            removeLeftovers(of: [localURL, SceneStore.folderURL(forVideoPath: localURL.path)])
            failedExternalWallpaperImportID = id
            return false
        }
        if let scene {
            registerImportedScene(scene, path: localURL.path)
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
        guard canShowExternalWallpaper,
              let wallpaper = externalWallpapers.first(where: { $0.id == id }), isExternalWallpaperReady(wallpaper),
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
        reconcileExternalScenes()
    }

    // MARK: - Scenes

    /// Bakes each offered scene that is not baked at its current revision, and drops
    /// the bakes of scenes no longer offered as they are.
    private func reconcileExternalScenes() {
        let offered = Dictionary(
            externalWallpapers.filter(\.isScene).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let known = Set(readyExternalScenes.keys).union(externalScenePreparations.keys).union(failedExternalScenes.keys)
        AppLog.externalWallpapers.info(
            "reconcile scenes offered=\(offered.mapValues { $0.sceneRevision?.timeIntervalSince1970 ?? 0 }.description, privacy: .public) ready=\(self.readyExternalScenes.mapValues(\.timeIntervalSince1970).description, privacy: .public) preparing=\(self.externalScenePreparations.count) failed=\(self.failedExternalScenes.count)"
        )
        for id in known {
            let revision = offered[id]?.sceneRevision
            let current = readyExternalScenes[id] ?? externalScenePreparations[id]?.revision ?? failedExternalScenes[id]
            if revision == nil || (current != nil && current != revision) {
                discardExternalScene(id: id)
            }
        }
        for wallpaper in offered.values
            where readyExternalScenes[wallpaper.id] == nil && externalScenePreparations[wallpaper.id] == nil
            && failedExternalScenes[wallpaper.id] == nil
        {
            prepareExternalScene(wallpaper)
        }
    }

    private func prepareExternalScene(_ wallpaper: ExternalWallpaper) {
        guard let folder = wallpaper.sceneFolderPath, let revision = wallpaper.sceneRevision else {
            return
        }
        let id = wallpaper.id
        let videoPath = wallpaper.path
        let task = Task { @MainActor [weak self] in
            do {
                // Copying tens of megabytes of images stays off the main thread.
                let document = try await Task.detached(priority: .utility) {
                    let bakeFolder = URL(fileURLWithPath: videoPath).deletingLastPathComponent()
                    if FileManager.default.fileExists(atPath: bakeFolder.path) {
                        try FileManager.default.removeItem(at: bakeFolder)
                    }
                    try FileManager.default.createDirectory(at: bakeFolder, withIntermediateDirectories: true)
                    return try SceneStore.importScene(from: URL(fileURLWithPath: folder, isDirectory: true), videoPath: videoPath)
                }.value
                try Task.checkCancellation()
                guard let self else { return }
                try await self.bakeSceneOutsideLibrary(document, videoPath: videoPath)
                try Task.checkCancellation()
                self.registerImportedScene(document, path: videoPath)
                self.readyExternalScenes[id] = revision
                AppLog.externalWallpapers.info("scene ready \(id, privacy: .public)")
            } catch is CancellationError {
                // discardExternalScene cancelled it and cleans up.
                return
            } catch {
                AppLog.externalWallpapers.error(
                    "scene \(id, privacy: .public) could not be prepared: \(error.localizedDescription, privacy: .public)"
                )
                self?.failedExternalScenes[id] = revision
            }
            self?.externalScenePreparations.removeValue(forKey: id)
            self?.objectWillChange.send()
        }
        externalScenePreparations[id] = (revision, task)
        objectWillChange.send()
    }

    private func discardExternalScene(id: String) {
        externalScenePreparations.removeValue(forKey: id)?.task.cancel()
        readyExternalScenes.removeValue(forKey: id)
        failedExternalScenes.removeValue(forKey: id)
        let videoPath = ExternalWallpaperProviderMonitor.bakedScenePath(forID: id)
        sceneDocumentsByPath.removeValue(forKey: videoPath)
        sceneBakedTimesOfDay.removeValue(forKey: videoPath)
        sceneBakeProgress.removeValue(forKey: videoPath)
        removeBakedExternalScenes(at: URL(fileURLWithPath: videoPath).deletingLastPathComponent())
        objectWillChange.send()
    }

    private func removeBakedExternalScenes(at folder: URL) {
        guard FileManager.default.fileExists(atPath: folder.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            AppLog.externalWallpapers.error(
                "could not remove baked scenes at \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
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

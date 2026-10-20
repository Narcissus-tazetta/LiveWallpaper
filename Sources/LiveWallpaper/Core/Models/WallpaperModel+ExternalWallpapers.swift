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

    var canShowExternalWallpaper: Bool { true }

    /// A scene can be shown or added once LiveWallpaper has baked it.
    func isExternalWallpaperReady(_ wallpaper: ExternalWallpaper) -> Bool {
        if !wallpaper.isScene { return true }
        guard readyExternalScenes[wallpaper.id] == wallpaper.sceneRevision else { return false }
        return FileManager.default.fileExists(atPath: wallpaper.path)
    }

    func isPreparingExternalScene(_ wallpaper: ExternalWallpaper) -> Bool {
        wallpaper.isScene && externalScenePreparations[wallpaper.id] != nil
    }

    func didFailToPrepareExternalScene(_ wallpaper: ExternalWallpaper) -> Bool {
        wallpaper.isScene && failedExternalScenes[wallpaper.id] == wallpaper.sceneRevision
    }

    /// The library copy of an external wallpaper, while the user keeps it.
    func libraryPath(forExternalWallpaperID id: String) -> String? {
        guard let path = importedExternalWallpaperPaths[id],
              libraryVideoPaths.contains(path) || webWallpaperSources.contains(where: { $0.localFolderPath != nil && $0.url.path == path })
        else {
            return nil
        }
        return path
    }

    /// External wallpapers are licensed only for local, personal use by the subscriber.
    func isExternalOrImportedWallpaper(path: String) -> Bool {
        if importedExternalWallpaperPaths.values.contains(path) {
            return true
        }
        if externalWallpapers.contains(where: {
            $0.path == path || $0.sceneFolderPath == path || $0.webSource?.localFolderPath == path
        }) {
            return true
        }
        if path.contains("/we-import/") || path.contains("/we-") {
            return true
        }
        return false
    }

    var shareableVideoPaths: [String] {
        libraryVideoPaths.filter { !isExternalOrImportedWallpaper(path: $0) }
    }

    /// Copies the wallpaper into the app's own folder and registers it like any other
    /// video, so it stays after the provider quits.
    @discardableResult
    func importExternalWallpaper(id: String) async -> Bool {
        guard importingExternalWallpaperID == nil,
              libraryPath(forExternalWallpaperID: id) == nil,
              let wallpaper = externalWallpapers.first(where: { $0.id == id })
        else {
            AppLog.externalWallpapers.warning("importExternalWallpaper skipped id=\(id, privacy: .public): busy or already imported")
            return false
        }
        guard isExternalWallpaperReady(wallpaper) else {
            AppLog.externalWallpapers.warning("importExternalWallpaper skipped id=\(id, privacy: .public): wallpaper not ready")
            return false
        }
        importingExternalWallpaperID = id
        failedExternalWallpaperImportID = nil
        defer { importingExternalWallpaperID = nil }
        if let source = wallpaper.webSource {
            return await importExternalWebWallpaper(source, externalID: id)
        }
        guard let localURL = await importVideoToAppSupport(from: URL(fileURLWithPath: wallpaper.path)) else {
            AppLog.externalWallpapers.error("could not add \(id, privacy: .public) to the library: video copy failed")
            failedExternalWallpaperImportID = id
            return false
        }
        // The scene goes in beside the copied video before the library sees it, so
        // the library never holds the video without its scene.
        var scene: SceneDocument?
        if wallpaper.isScene {
            let sourceFolder: URL
            if let originalFolder = wallpaper.sceneFolderPath,
               FileManager.default.fileExists(atPath: URL(fileURLWithPath: originalFolder).appendingPathComponent("scene.json").path) {
                sourceFolder = URL(fileURLWithPath: originalFolder, isDirectory: true)
            } else {
                sourceFolder = SceneStore.folderURL(forVideoPath: wallpaper.path)
            }
            do {
                let videoIsOutOfDate = SceneStore.isNewerThanVideo(videoPath: wallpaper.path)
                scene = try await Task.detached(priority: .userInitiated) {
                    try SceneStore.importScene(from: sourceFolder, videoPath: localURL.path, videoIsOutOfDate: videoIsOutOfDate)
                }.value
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
            AppLog.externalWallpapers.error("could not add \(id, privacy: .public) to the library: registration failed")
            removeLeftovers(of: [localURL, SceneStore.folderURL(forVideoPath: localURL.path)])
            failedExternalWallpaperImportID = id
            return false
        }
        if let scene {
            SceneScriptPermissions.carry(scene, from: wallpaper.path, to: localURL.path)
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
              let wallpaper = externalWallpapers.first(where: { $0.id == id })
        else {
            return
        }
        guard isExternalWallpaperReady(wallpaper) else {
            pendingShowExternalWallpaperID = id
            return
        }
        pendingShowExternalWallpaperID = nil
        guard activeExternalWallpaperID != id else { return }
        let previousPath = activeExternalWallpaper?.path
        let changesWeb = isWebWallpaperActive || wallpaper.webSource != nil
        let change = {
            if changesWeb { self.stopWebWallpaper() }
            self.activeExternalWallpaperID = id
            if wallpaper.webSource != nil { self.sharedPlayer?.pause() }
            if let previousPath { self.evictExternalSlots(path: previousPath) }
            if changesWeb { self.scheduleWindowRebuild(delay: 0.05) }
            self.applySuspensionStateToPlayers()
            self.scheduleDedicatedWarmWindowReconciliation()
        }
        if let source = wallpaper.webSource {
            performSharedWallpaperTransition(to: .web(source.id), change)
        } else if changesWeb {
            performSharedWallpaperTransition(to: .video(wallpaper.path), change)
        } else {
            performDisplayAssignmentTransition(change)
        }
    }

    func stopExternalWallpaper() {
        guard activeExternalWallpaperID != nil else { return }
        let path = activeExternalWallpaper?.path
        let changesWeb = isWebWallpaperActive || wallpaperKind == .web
        if changesWeb { stopWebWallpaper() }
        performDisplayAssignmentTransition {
            activeExternalWallpaperID = nil
            if let path { evictExternalSlots(path: path) }
            // A video-to-web fade transfers the outgoing player to its overlay.
            // Once that overlay is gone, returning needs a new shared player.
            if changesWeb, !isWebWallpaperActive, sharedPlayer?.currentItem == nil,
               let savedPath = currentVideoPath, FileManager.default.fileExists(atPath: savedPath) {
                playRegisteredVideo(path: savedPath)
            }
            if changesWeb { scheduleWindowRebuild(delay: 0.05) }
            applySuspensionStateToPlayers()
            scheduleDedicatedWarmWindowReconciliation()
        }
    }

    func updateExternalWallpapers(_ wallpapers: [ExternalWallpaper]) {
        guard wallpapers != externalWallpapers else { return }
        if let active = activeExternalWallpaper, !wallpapers.contains(active) {
            stopExternalWallpaper()
        }
        let removedWebFolders = externalWallpapers.compactMap { old -> String? in
            guard !wallpapers.contains(where: { $0.webSource?.localFolderPath == old.webSource?.localFolderPath }) else { return nil }
            return old.webSource?.localFolderPath
        }
        for folder in removedWebFolders { localWebWallpaperServer.remove(folder: URL(fileURLWithPath: folder)) }
        externalWallpapers = wallpapers
        reconcileExternalScenes()
    }

    private func importExternalWebWallpaper(_ source: WebWallpaperSource, externalID: String) async -> Bool {
        let folder = URL(fileURLWithPath: source.localFolderPath!, isDirectory: true)
        let destination = LocalWebWallpaperPackage.libraryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try await Task.detached(priority: .userInitiated) {
                try LocalWebWallpaperPackage.copy(from: folder, to: destination)
            }.value
            let package = try LocalWebWallpaperPackage.load(folder: destination)
            let saved = WebWallpaperSource(url: destination.appendingPathComponent(package.entryPoint),
                                           displayName: source.displayName, localFolderPath: destination.path,
                                           warnings: package.warnings,
                                           thumbnailPath: package.preview.map { destination.appendingPathComponent($0).path })
            try LocalWebSettings.load(id: source.id).save(id: saved.id)
            webWallpaperSources.append(saved)
            importedExternalWallpaperPaths[externalID] = saved.url.path
            UserDefaults.standard.set(importedExternalWallpaperPaths, forKey: PrefsKey.importedExternalWallpapers)
            setWebWallpaperFeatureEnabled(true)
            syncActivePlaylistPaths()
            stopExternalWallpaper()
            selectWebWallpaper(id: saved.id)
            persistWebWallpaperState()
            return true
        } catch {
            removeLeftovers(of: [destination])
            failedExternalWallpaperImportID = externalID
            webWallpaperErrorMessage = error.localizedDescription
            AppLog.externalWallpapers.error("could not import web package: \(error.localizedDescription, privacy: .public)")
            return false
        }
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
            let path = offered[id]?.path
            let missingBakedVideo = readyExternalScenes[id] != nil && (path == nil || !FileManager.default.fileExists(atPath: path!))
            if revision == nil || (current != nil && current != revision) || missingBakedVideo {
                discardExternalScene(id: id)
            }
        }
        for wallpaper in offered.values
            where readyExternalScenes[wallpaper.id] == nil && externalScenePreparations[wallpaper.id] == nil
            && failedExternalScenes[wallpaper.id] == nil
        {
            if canReuseBakedScene(wallpaper) {
                reuseBakedScene(wallpaper)
            } else {
                prepareExternalScene(wallpaper)
            }
        }
    }

    private func canReuseBakedScene(_ wallpaper: ExternalWallpaper) -> Bool {
        guard let revision = wallpaper.sceneRevision,
              FileManager.default.fileExists(atPath: wallpaper.path),
              SceneStore.hasScene(videoPath: wallpaper.path)
        else {
            return false
        }
        let metaURL = ExternalWallpaperProviderMonitor.bakedSceneMetaURL(forID: wallpaper.id)
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(ExternalWallpaperProviderMonitor.BakedSceneMeta.self, from: data)
        else {
            return false
        }
        return meta.sceneRevision == revision && meta.appSignature == ExternalWallpaperProviderMonitor.currentAppSignature
    }

    private func reuseBakedScene(_ wallpaper: ExternalWallpaper) {
        guard let revision = wallpaper.sceneRevision,
              let document = try? SceneStore.load(videoPath: wallpaper.path)
        else {
            prepareExternalScene(wallpaper)
            return
        }
        registerImportedScene(document, path: wallpaper.path)
        readyExternalScenes[wallpaper.id] = revision
        AppLog.externalWallpapers.info("reused cached baked scene \(wallpaper.id, privacy: .public)")
        objectWillChange.send()
        if pendingShowExternalWallpaperID == wallpaper.id {
            showExternalWallpaper(id: wallpaper.id)
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
                // A still stands in for the video: the desktop draws the scene live, and
                // a full loop is baked only once it goes on the lock screen or screen saver.
                try await self.bakeSceneOutsideLibrary(document, videoPath: videoPath, stillOnly: true)
                if document.isAnimated {
                    try SceneStore.markVideoOutOfDate(videoPath: videoPath)
                }
                try Task.checkCancellation()
                self.registerImportedScene(document, path: videoPath)
                self.requestSceneScriptApproval(id: id, name: wallpaper.name, path: videoPath)
                let meta = ExternalWallpaperProviderMonitor.BakedSceneMeta(
                    sceneRevision: revision,
                    appSignature: ExternalWallpaperProviderMonitor.currentAppSignature
                )
                if let metaData = try? JSONEncoder().encode(meta) {
                    try? metaData.write(
                        to: ExternalWallpaperProviderMonitor.bakedSceneMetaURL(forID: id),
                        options: .atomic
                    )
                }
                self.readyExternalScenes[id] = revision
                AppLog.externalWallpapers.info("scene ready \(id, privacy: .public)")
                if self.pendingShowExternalWallpaperID == id {
                    self.showExternalWallpaper(id: id)
                }
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
        if pendingShowExternalWallpaperID == id {
            pendingShowExternalWallpaperID = nil
        }
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

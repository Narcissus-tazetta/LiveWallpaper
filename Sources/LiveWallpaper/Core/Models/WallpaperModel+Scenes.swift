import AppKit
import Foundation

enum SceneAIWork: Equatable {
    case separating
    case downloadingModel(Double)
    case estimatingDepth
}

extension Notification.Name {
    /// object: the video path whose baked video was rewritten.
    static let sceneDidBake = Notification.Name("SceneDidBake")
}

/// Still-image wallpapers built from layers. A scene is baked into an ordinary video
/// at its library path, so every feature that plays videos (lock screen, screen
/// saver, thumbnails, playlists, schedules) uses it unchanged, while the desktop
/// draws the scene live on top of that video to react to the cursor.
@MainActor
extension WallpaperModel {
    /// Seconds after the last edit before the baked video is rewritten.
    private static let sceneBakeDelay: TimeInterval = 1.5
    /// Time for a reloaded video to show its first frame.
    private static let sceneHandOverDelay: TimeInterval = 1.0

    func isScene(path: String) -> Bool {
        sceneDocumentsByPath[path] != nil
    }

    /// Scenes only ever live in the app's own folder, so this reads local files only
    /// (restoreState must not stat external volumes).
    func restoreScenes() {
        guard let cacheDirectory = cacheDirectoryURL()?.path else {
            return
        }
        var restored: [String: SceneDocument] = [:]
        var unbaked: [String] = []
        for path in libraryVideoPaths where path.hasPrefix(cacheDirectory) {
            do {
                if let document = try SceneStore.load(videoPath: path) {
                    restored[path] = document
                    if SceneStore.isNewerThanVideo(videoPath: path) {
                        unbaked.append(path)
                    }
                }
            } catch {
                AppLog.windowRefresh.error(
                    "scene unreadable path=\(path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
        sceneDocumentsByPath = restored
        // The app quit before an edit was baked.
        for path in unbaked {
            scheduleSceneBake(path: path)
        }
    }

    /// Makes a one-layer scene from a still image and bakes it. Returns the video path
    /// to register, or nil after reporting the failure.
    func importStillImageAsScene(from sourceURL: URL, targetDirectory: URL) async -> URL? {
        let videoURL = targetDirectory.appendingPathComponent("wallpaper-\(UUID().uuidString).mp4")
        mediaImportErrorMessage = nil
        mediaImportProgress = 0
        isImportingMedia = true
        defer {
            isImportingMedia = false
        }
        do {
            let (layer, size) = try SceneStore.importImage(at: sourceURL, videoPath: videoURL.path)
            let document = SceneDocument(
                canvasWidth: Int(size.width), canvasHeight: Int(size.height), layers: [layer]
            )
            try SceneStore.save(document, videoPath: videoURL.path)
            try await bakeScene(document, videoPath: videoURL.path)
            sceneDocumentsByPath[videoURL.path] = document
            mediaImportProgress = 1
            return videoURL
        } catch {
            AppLog.windowRefresh.error("still import failed: \(error.localizedDescription, privacy: .public)")
            removeLeftovers(of: [SceneStore.folderURL(forVideoPath: videoURL.path), videoURL])
            mediaImportErrorMessage = localizedString("画像を壁紙にできませんでした。")
                + " " + error.localizedDescription
            return nil
        }
    }

    /// A scene that arrived in a package, next to its already imported baked video.
    func registerImportedScene(_ document: SceneDocument, path: String) {
        sceneDocumentsByPath[path] = document
        refreshCursorEffects()
    }

    // MARK: - Editing

    func updateScene(_ document: SceneDocument, path: String) {
        guard sceneDocumentsByPath[path] != document else {
            return
        }
        do {
            try SceneStore.save(document, videoPath: path)
        } catch {
            sceneErrorMessage = error.localizedDescription
            AppLog.windowRefresh.error("scene save failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        sceneErrorMessage = nil
        sceneDocumentsByPath[path] = document
        pruneSceneFiles(document, path: path)
        // Marks the video stale first, so the desktop draws the edit live until the
        // new video is baked.
        scheduleSceneBake(path: path)
        refreshCursorEffects()
    }

    /// Adds the image as the new top layer.
    func addSceneLayer(from imageURL: URL, path: String) {
        guard var document = sceneDocumentsByPath[path] else {
            return
        }
        do {
            let (layer, _) = try SceneStore.importImage(at: imageURL, videoPath: path)
            document.layers.append(layer)
            updateScene(document, path: path)
        } catch {
            sceneErrorMessage = error.localizedDescription
        }
    }

    func addSceneParticleLayer(_ preset: SceneParticlePreset, name: String, path: String) -> UUID? {
        guard var document = sceneDocumentsByPath[path] else {
            return nil
        }
        let layer = SceneLayer(name: name, particles: SceneParticles(preset: preset))
        document.layers.append(layer)
        updateScene(document, path: path)
        return layer.id
    }

    // MARK: - AI

    /// Splits the layer into its subject (a new layer above) and the background with
    /// the subject's place filled in (this layer).
    func separateSceneForeground(layerID: UUID, path: String) {
        guard sceneAIWork[layerID] == nil,
              let layer = sceneDocumentsByPath[path]?.layers.first(where: { $0.id == layerID }),
              layer.kind == .image
        else {
            return
        }
        let imageURL = SceneStore.imageURL(layer, videoPath: path)
        let foregroundName = String(format: localizedString("%@(前景)"), layer.name)
        let backgroundName = String(format: localizedString("%@(背景)"), layer.name)
        sceneAIWork[layerID] = .separating
        Task { [weak self] in
            do {
                let (foregroundFile, backgroundFile) = try await Task.detached(priority: .userInitiated) {
                    let separation = try SceneAI.separateForeground(imageURL: imageURL)
                    return try (
                        SceneStore.writeImage(separation.foreground, prefix: "layer", videoPath: path),
                        SceneStore.writeImage(separation.background, prefix: "layer", videoPath: path)
                    )
                }.value
                guard let self else {
                    return
                }
                self.sceneAIWork[layerID] = nil
                guard var document = self.sceneDocumentsByPath[path],
                      let index = document.layers.firstIndex(where: { $0.id == layerID })
                else {
                    return
                }
                document.layers[index].imageFile = backgroundFile
                document.layers[index].name = backgroundName
                var foreground = SceneLayer(name: foregroundName, imageFile: foregroundFile)
                foreground.blendMode = document.layers[index].blendMode
                document.layers.insert(foreground, at: index + 1)
                self.updateScene(document, path: path)
            } catch {
                self?.sceneAIWork[layerID] = nil
                self?.sceneErrorMessage = error.localizedDescription
                AppLog.windowRefresh.error("foreground separation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Estimates a depth map for the layer, downloading the model the first time.
    func estimateSceneDepth(layerID: UUID, path: String) {
        guard sceneAIWork[layerID] == nil,
              let layer = sceneDocumentsByPath[path]?.layers.first(where: { $0.id == layerID }),
              layer.kind == .image
        else {
            return
        }
        let imageURL = SceneStore.imageURL(layer, videoPath: path)
        Task { [weak self] in
            do {
                if !SceneAI.isDepthModelInstalled {
                    self?.sceneAIWork[layerID] = .downloadingModel(0)
                    try await SceneAI.installDepthModel { value in
                        Task { @MainActor in
                            if case .downloadingModel = self?.sceneAIWork[layerID] {
                                self?.sceneAIWork[layerID] = .downloadingModel(value)
                            }
                        }
                    }
                }
                self?.sceneAIWork[layerID] = .estimatingDepth
                let file = try await Task.detached(priority: .userInitiated) {
                    try SceneStore.writeImage(SceneAI.estimateDepth(imageURL: imageURL), prefix: "depth", videoPath: path)
                }.value
                guard let self else {
                    return
                }
                self.sceneAIWork[layerID] = nil
                guard var document = self.sceneDocumentsByPath[path],
                      let index = document.layers.firstIndex(where: { $0.id == layerID })
                else {
                    return
                }
                document.layers[index].depthFile = file
                self.updateScene(document, path: path)
            } catch {
                self?.sceneAIWork[layerID] = nil
                self?.sceneErrorMessage = error.localizedDescription
                AppLog.windowRefresh.error("depth estimation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func removeSceneLayer(id: UUID, path: String) {
        guard var document = sceneDocumentsByPath[path],
              let index = document.layers.firstIndex(where: { $0.id == id }),
              document.layers.count > 1
        else {
            return
        }
        document.layers.remove(at: index)
        updateScene(document, path: path)
    }

    /// Points the effect at a newly painted mask or flow file (nil: whole layer / still).
    func setScenePaintFile(
        _ fileName: String?,
        kind: ScenePaintOverride.Target,
        effectID: UUID,
        layerID: UUID,
        path: String
    ) {
        guard var document = sceneDocumentsByPath[path],
              let layerIndex = document.layers.firstIndex(where: { $0.id == layerID })
        else {
            return
        }
        // A particle layer's own area uses the layer's id.
        if effectID == layerID, document.layers[layerIndex].particles != nil {
            document.layers[layerIndex].particles?.maskFile = fileName
            updateScene(document, path: path)
            return
        }
        guard let effectIndex = document.layers[layerIndex].effects.firstIndex(where: { $0.id == effectID }) else {
            return
        }
        switch kind {
        case .mask:
            document.layers[layerIndex].effects[effectIndex].maskFile = fileName
        case .flow:
            document.layers[layerIndex].effects[effectIndex].flowFile = fileName
        }
        updateScene(document, path: path)
    }

    /// Deletes images in the scene folder that the scene no longer uses: removed
    /// layers, and masks replaced by a newer stroke.
    private func pruneSceneFiles(_ document: SceneDocument, path: String) {
        let folder = SceneStore.folderURL(forVideoPath: path)
        var used: Set<String> = ["scene.json"]
        for layer in document.layers {
            used.insert(layer.imageFile)
            layer.particles?.maskFile.map { used.insert($0) }
            layer.depthFile.map { used.insert($0) }
            for effect in layer.effects {
                effect.maskFile.map { used.insert($0) }
                effect.flowFile.map { used.insert($0) }
            }
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            AppLog.windowRefresh.error("scene folder unreadable: \(error.localizedDescription, privacy: .public)")
            return
        }
        removeLeftovers(of: names.filter { !used.contains($0) }.map { folder.appendingPathComponent($0) })
    }

    private func scheduleSceneBake(path: String) {
        sceneBakeWorkItems[path]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.startSceneBake(path: path)
            }
        }
        sceneBakeWorkItems[path] = workItem
        scenesBaking.insert(path)
        sceneStaleVideoPaths.insert(path)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sceneBakeDelay, execute: workItem)
    }

    private func startSceneBake(path: String) {
        sceneBakeWorkItems[path] = nil
        guard let document = sceneDocumentsByPath[path] else {
            scenesBaking.remove(path)
            return
        }
        sceneBakeTasks[path]?.cancel()
        sceneBakeTasks[path] = Task { [weak self] in
            guard let self else {
                return
            }
            let succeeded: Bool
            do {
                try await self.bakeScene(document, videoPath: path)
                succeeded = true
            } catch is CancellationError {
                return
            } catch {
                self.sceneErrorMessage = error.localizedDescription
                AppLog.windowRefresh.error("scene bake failed: \(error.localizedDescription, privacy: .public)")
                succeeded = false
            }
            guard !Task.isCancelled else {
                return
            }
            self.sceneBakeTasks[path] = nil
            self.sceneBakeProgress[path] = nil
            if self.sceneBakeWorkItems[path] == nil {
                self.scenesBaking.remove(path)
            }
            guard succeeded else {
                // The desktop keeps drawing the scene live, so it still shows the edit.
                return
            }
            NotificationCenter.default.post(name: .sceneDidBake, object: path)
            if self.lockScreenSyncEnabled, self.effectiveLockScreenVideoPath == path {
                self.syncCurrentVideoToLockScreen()
            }
            self.reloadPlayback(forRewrittenPath: path)
            // Hand the screen back to the video once the new file is playing, so the
            // live layer does not drop out before the first new frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.sceneHandOverDelay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.scenesBaking.contains(path) else {
                        return
                    }
                    self.sceneStaleVideoPaths.remove(path)
                    self.refreshCursorEffects()
                }
            }
        }
    }

    /// Writes the scene's video at `videoPath`: one seamless loop when anything moves,
    /// otherwise a short still.
    private func bakeScene(_ document: SceneDocument, videoPath: String) async throws {
        let output = URL(fileURLWithPath: videoPath)
        if document.isAnimated {
            sceneBakeProgress[videoPath] = 0
            let throttle = MediaImportProgressThrottle()
            try await SceneVideoBaker.bake(document: document, videoPath: videoPath, to: output) { value in
                guard throttle.shouldReport(value) else {
                    return
                }
                Task { @MainActor [weak self] in
                    if self?.sceneBakeProgress[videoPath] != nil {
                        self?.sceneBakeProgress[videoPath] = value
                    }
                }
            }
            return
        }
        let image = try SceneRenderer(document: document, videoPath: videoPath).renderStill()
        let stillURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scene-\(UUID().uuidString).png")
        guard let destination = CGImageDestinationCreateWithURL(stillURL as CFURL, "public.png" as CFString, 1, nil)
        else {
            throw SceneStore.StoreError.unreadableImage(stillURL.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SceneStore.StoreError.unreadableImage(stillURL.lastPathComponent)
        }
        defer {
            removeLeftovers(of: [stillURL])
        }
        try Task.checkCancellation()
        try await Task.detached(priority: .userInitiated) {
            try await AnimatedImageTranscoder.transcode(imageURL: stillURL, to: output)
        }.value
    }

    private func removeLeftovers(of urls: [URL]) {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                AppLog.windowRefresh.error(
                    "scene cleanup failed path=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    // MARK: - Desktop

    /// Shows or hides the live scene on each screen to match what it plays. Called
    /// from refreshCursorEffects, which runs on every change of what screens show.
    ///
    /// The baked video already shows everything that does not react to the cursor,
    /// at the cost of any other video, so the scene is drawn live only when it reacts
    /// to the cursor or its video is out of date.
    func refreshSceneHosts() {
        let maximumFramesPerSecond: Float? = switch frameRateLimit {
        case .off: nil
        case .fps30: 30
        case .fps60: 60
        }
        for view in playerViews {
            guard let window = view.window, let displayID = displayIDByWindow[ObjectIdentifier(window)],
                  !isWebWallpaperActive,
                  let path = resolvedOverridePath(forScreenID: displayID) ?? currentVideoPath,
                  let document = sceneDocumentsByPath[path]
            else {
                view.hideScene()
                continue
            }
            let isStale = sceneStaleVideoPaths.contains(path)
            guard document.usesCursor || isStale else {
                if view.isShowingScene {
                    AppLog.windowRefresh.info("scene video display=\(displayID, privacy: .public)")
                }
                view.hideScene()
                continue
            }
            do {
                if !view.isShowingScene {
                    AppLog.windowRefresh.info(
                        "scene live display=\(displayID, privacy: .public) stale=\(isStale, privacy: .public)"
                    )
                }
                try view.showScene(
                    document, videoPath: path, freeClock: isStale, maximumFramesPerSecond: maximumFramesPerSecond
                )
            } catch {
                AppLog.windowRefresh.error("scene show failed: \(error.localizedDescription, privacy: .public)")
                view.hideScene()
            }
        }
    }
}

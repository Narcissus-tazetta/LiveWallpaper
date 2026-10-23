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
    /// Seconds after the last edit before the baked video is rewritten. A bake of a
    /// 4K loop takes tens of seconds and an edit cancels it, so it waits for a real
    /// pause; leaving the scene in the editor starts it at once (bakeSceneNowIfPending).
    private static let sceneBakeDelay: TimeInterval = 5
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
        let externalDirectory = ExternalWallpaperProviderMonitor.bakedScenesDirectoryURL.path
        var restored: [String: SceneDocument] = [:]
        var unbaked: [String] = []
        var candidatePaths = Set(libraryVideoPaths)
        if let current = currentVideoPath {
            candidatePaths.insert(current)
        }
        for path in videoOverrideByScreenID.values {
            candidatePaths.insert(path)
        }
        for path in candidatePaths where path.hasPrefix(cacheDirectory) || path.hasPrefix(externalDirectory) {
            do {
                if let loaded = try SceneStore.load(videoPath: path) {
                    let document = SceneScriptPermissions.restored(loaded, path: path)
                    restored[path] = document
                    if SceneStore.isNewerThanVideo(videoPath: path) {
                        if document.hasUnapprovedScripts {
                            sceneVideosAwaitingScriptApproval.insert(path)
                        } else {
                            unbaked.append(path)
                        }
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
        startSceneTimeOfDayUpdates()
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
            activeMediaImportTask = nil
        }
        // Held in activeMediaImportTask so the import's cancel button stops the bake.
        let task = Task { () -> Result<URL, Error> in
            do {
                // Off the main thread: downscaling a large photo takes seconds.
                let (layer, size) = try await Task.detached(priority: .userInitiated) {
                    try SceneStore.importImage(at: sourceURL, videoPath: videoURL.path)
                }.value
                try Task.checkCancellation()
                let document = SceneDocument(
                    canvasWidth: Int(size.width), canvasHeight: Int(size.height), layers: [layer]
                )
                try SceneStore.save(document, videoPath: videoURL.path)
                try await bakeScene(document, videoPath: videoURL.path)
                sceneDocumentsByPath[videoURL.path] = document
                return .success(videoURL)
            } catch {
                return .failure(error)
            }
        }
        activeMediaImportTask = task
        switch await task.value {
        case let .success(url):
            mediaImportProgress = 1
            return url
        case let .failure(error):
            removeLeftovers(of: [SceneStore.folderURL(forVideoPath: videoURL.path), videoURL])
            if error is CancellationError {
                mediaImportErrorMessage = localizedString("変換をキャンセルしました")
                return nil
            }
            AppLog.windowRefresh.error("still import failed: \(error.localizedDescription, privacy: .public)")
            mediaImportErrorMessage = localizedString("画像を壁紙にできませんでした。")
                + " " + error.localizedDescription
            return nil
        }
    }

    /// A scene that arrived in a package, next to its already imported baked video.
    /// A new effect for the editor. An effect that reads a tiling pattern gets one
    /// written into the scene folder; nil (with the reason shown) when that fails.
    func makeSceneEffect(_ kind: SceneEffectKind, path: String) -> SceneEffect? {
        var effect = SceneEffect(kind: kind)
        guard let pattern = ScenePatternGenerator.pattern(for: kind) else {
            return effect
        }
        do {
            effect.patternFile = try SceneStore.writeImage(
                ScenePatternGenerator.image(pattern), prefix: "pattern", videoPath: path
            )
        } catch {
            AppLog.windowRefresh.error("scene pattern not written: \(error.localizedDescription, privacy: .public)")
            sceneErrorMessage = error.localizedDescription
            return nil
        }
        return effect
    }

    /// `asksAgain`: a package someone sent replaced the scene, so its scripts and its
    /// sound reaction wait for the user again. Otherwise scripts the user allowed
    /// (the same code at this path) keep running.
    func registerImportedScene(_ document: SceneDocument, path: String, asksAgain: Bool = false) {
        if asksAgain {
            SceneScriptPermissions.revoke(document, path: path)
            SceneSoundReaction.setEnabled(false, videoPath: path)
        }
        let document = SceneScriptPermissions.restored(document, path: path)
        sceneDocumentsByPath[path] = document
        if SceneStore.isNewerThanVideo(videoPath: path) {
            sceneStaleVideoPaths.insert(path)
        }
        refreshCursorEffects()
        if document.usesTimeOfDay {
            scheduleNextSceneTimeOfDayUpdate(after: Date())
        }
    }

    // MARK: - Editing

    /// `coalescing` lets a run of edits to the same fields (a slider drag) become one
    /// undo step; pass false for edits that must always be a step of their own.
    func updateScene(_ document: SceneDocument, path: String, coalescing: Bool = true) {
        guard let previous = sceneDocumentsByPath[path], previous != document else {
            return
        }
        let key: String?
        do {
            key = coalescing ? try document.changeKey(from: previous) : nil
        } catch {
            sceneErrorMessage = error.localizedDescription
            AppLog.windowRefresh.error("scene diff failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        sceneHistories[path, default: EditHistory()].record(previous, coalescingKey: key)
        applyEditedScene(document, path: path)
    }

    func canUndoScene(path: String) -> Bool {
        sceneHistories[path]?.canUndo ?? false
    }

    func canRedoScene(path: String) -> Bool {
        sceneHistories[path]?.canRedo ?? false
    }

    func undoScene(path: String) {
        stepSceneHistory(path: path) { history, current in history.undo(current: current) }
    }

    func redoScene(path: String) {
        stepSceneHistory(path: path) { history, current in history.redo(current: current) }
    }

    /// Ends the current drag or key repeat, so the next edit is a new undo step.
    func breakSceneHistoryCoalescing() {
        for path in sceneHistories.keys {
            sceneHistories[path]?.breakCoalescing()
        }
    }

    private func stepSceneHistory(
        path: String,
        _ step: (inout EditHistory<SceneDocument>, SceneDocument) -> SceneDocument?
    ) {
        guard var history = sceneHistories[path], let current = sceneDocumentsByPath[path],
              let restored = step(&history, current)
        else {
            return
        }
        sceneHistories[path] = history
        applyEditedScene(restored, path: path)
    }

    /// The preview and the desktop follow the edit at once; writing scene.json and
    /// baking wait for the edits to pause.
    private func applyEditedScene(_ document: SceneDocument, path: String) {
        sceneErrorMessage = nil
        let previous = sceneDocumentsByPath[path]
        sceneDocumentsByPath[path] = document
        sceneScriptIssues[path] = []
        scheduleSceneSave(path: path)
        refreshScenePresetTrial(path: path)
        if previous?.usesTimeOfDay != document.usesTimeOfDay || previous?.timeBands != document.timeBands {
            scheduleNextSceneTimeOfDayUpdate(after: Date())
        }
        guard previous.map({ !document.rendersSame(as: $0) }) ?? true else {
            return
        }
        // Marks the video stale first, so the desktop draws the edit live until the
        // new video is baked.
        scheduleSceneBake(path: path)
        refreshCursorEffects()
    }

    // MARK: - Saving

    /// Seconds after the last edit before scene.json is written. A drag sends an edit
    /// per frame; writing each one cost more main thread time than drawing it.
    private static let sceneSaveDelay: TimeInterval = 0.4
    /// Serial, so writes land in the order the edits were made.
    private static let sceneSaveQueue = DispatchQueue(label: "com.sakana.livewallpaper.scene-save", qos: .utility)

    private func scheduleSceneSave(path: String) {
        sceneSaveWorkItems.removeValue(forKey: path)?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.writeScene(path: path)
            }
        }
        sceneSaveWorkItems[path] = workItem
        scenesSaving.insert(path)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sceneSaveDelay, execute: workItem)
    }

    private func writeScene(path: String) {
        sceneSaveWorkItems[path] = nil
        guard let document = sceneDocumentsByPath[path] else {
            scenesSaving.remove(path)
            return
        }
        let generation = UUID()
        sceneSaveGenerations[path] = generation
        let data: Data
        do {
            data = try SceneStore.encode(document)
        } catch {
            finishSceneSave(path: path, generation: generation, error: error)
            return
        }
        Self.sceneSaveQueue.async { [weak self] in
            let failure: Error?
            do {
                try SceneStore.write(data, videoPath: path)
                failure = nil
            } catch {
                failure = error
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishSceneSave(path: path, generation: generation, error: failure)
                }
            }
        }
        pruneSceneFiles(document, path: path)
    }

    private func finishSceneSave(path: String, generation: UUID, error: Error?) {
        guard sceneSaveGenerations[path] == generation else {
            return
        }
        sceneSaveGenerations[path] = nil
        if let error {
            sceneSaveFailures[path] = error.localizedDescription
            AppLog.windowRefresh.error("scene save failed: \(error.localizedDescription, privacy: .public)")
        } else {
            sceneSaveFailures[path] = nil
        }
        if sceneSaveWorkItems[path] == nil {
            scenesSaving.remove(path)
        }
    }

    /// Writes pending edits now and waits for them to reach the disk: before quitting,
    /// and before anything reads scene.json.
    func flushSceneSave(path: String) {
        if sceneSaveWorkItems.removeValue(forKey: path)?.cancel() != nil {
            writeScene(path: path)
        }
        Self.sceneSaveQueue.sync {}
    }

    func flushAllSceneSaves() {
        for path in Array(sceneSaveWorkItems.keys) {
            sceneSaveWorkItems.removeValue(forKey: path)?.cancel()
            writeScene(path: path)
        }
        Self.sceneSaveQueue.sync {}
    }

    func retrySceneSave(path: String) {
        guard sceneDocumentsByPath[path] != nil else {
            return
        }
        sceneSaveWorkItems.removeValue(forKey: path)?.cancel()
        scenesSaving.insert(path)
        writeScene(path: path)
    }

    /// Drops unsaved edits of a scene being removed, so a late write does not
    /// recreate its folder.
    func discardSceneSave(path: String) {
        sceneSaveWorkItems.removeValue(forKey: path)?.cancel()
        sceneSaveGenerations[path] = nil
        Self.sceneSaveQueue.sync {}
        scenesSaving.remove(path)
        sceneSaveFailures[path] = nil
    }

    /// Adds the images above the existing layers in the order given, as one edit.
    /// Returns the id of the topmost new layer, or nil when none could be added.
    func addSceneLayers(from imageURLs: [URL], path: String) async -> UUID? {
        guard sceneDocumentsByPath[path] != nil, !imageURLs.isEmpty else {
            return nil
        }
        sceneLayerImportCounts[path, default: 0] += 1
        defer {
            sceneLayerImportCounts[path, default: 1] -= 1
            if sceneLayerImportCounts[path] == 0 {
                sceneLayerImportCounts[path] = nil
            }
        }
        // Downscaling a large photo takes seconds, so it runs off the main thread.
        let stagingVideoPath = Self.sceneStagingVideoPath()
        let stagingFolder = SceneStore.folderURL(forVideoPath: stagingVideoPath)
        defer {
            removeLeftovers(of: [stagingFolder])
        }
        // One at a time: decoding several huge photos at once multiplies peak memory.
        let results = await Task.detached(priority: .userInitiated) {
            imageURLs.map { imageURL in
                Result { try SceneStore.importImage(at: imageURL, videoPath: stagingVideoPath).0 }
            }
        }.value

        guard var document = sceneDocumentsByPath[path] else {
            return nil
        }
        var added: [SceneLayer] = []
        var failure: Error?
        for result in results {
            do {
                let layer = try result.get()
                try adoptStagedSceneFile(layer.imageFile, from: stagingFolder, path: path)
                added.append(layer)
            } catch {
                failure = error
                AppLog.windowRefresh.error("adding scene layer failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let failure {
            sceneErrorMessage = failure.localizedDescription
        }
        guard !added.isEmpty else {
            return nil
        }
        document.layers.append(contentsOf: added)
        updateScene(document, path: path, coalescing: false)
        return added.last?.id
    }

    func addSceneParticleLayer(_ preset: SceneParticlePreset, name: String, path: String) -> UUID? {
        guard var document = sceneDocumentsByPath[path] else {
            return nil
        }
        let layer = SceneLayer(name: name, particles: SceneParticles(preset: preset))
        document.layers.append(layer)
        updateScene(document, path: path, coalescing: false)
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
        let stagingVideoPath = Self.sceneStagingVideoPath()
        let stagingFolder = SceneStore.folderURL(forVideoPath: stagingVideoPath)
        sceneAIWork[layerID] = .separating
        retainSceneFile(imageURL)
        Task { [weak self] in
            defer {
                self?.releaseSceneFile(imageURL)
                self?.removeLeftovers(of: [stagingFolder])
            }
            do {
                let (foregroundFile, backgroundFile) = try await Task.detached(priority: .userInitiated) {
                    let separation = try SceneAI.separateForeground(imageURL: imageURL)
                    return try (
                        SceneStore.writeImage(separation.foreground, prefix: "layer", videoPath: stagingVideoPath),
                        SceneStore.writeImage(separation.background, prefix: "layer", videoPath: stagingVideoPath)
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
                try self.adoptStagedSceneFile(foregroundFile, from: stagingFolder, path: path)
                try self.adoptStagedSceneFile(backgroundFile, from: stagingFolder, path: path)
                document.layers[index].imageFile = backgroundFile
                document.layers[index].name = backgroundName
                let foreground = document.layers[index].separatedForeground(name: foregroundName, imageFile: foregroundFile)
                document.layers.insert(foreground, at: index + 1)
                document.linkLayer(foreground.id, likeLayer: layerID)
                self.updateScene(document, path: path, coalescing: false)
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
        let stagingVideoPath = Self.sceneStagingVideoPath()
        let stagingFolder = SceneStore.folderURL(forVideoPath: stagingVideoPath)
        retainSceneFile(imageURL)
        Task { [weak self] in
            defer {
                self?.releaseSceneFile(imageURL)
                self?.removeLeftovers(of: [stagingFolder])
            }
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
                    try SceneStore.writeImage(
                        SceneAI.estimateDepth(imageURL: imageURL), prefix: "depth", videoPath: stagingVideoPath
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
                try self.adoptStagedSceneFile(file, from: stagingFolder, path: path)
                document.layers[index].depthFile = file
                self.updateScene(document, path: path, coalescing: false)
            } catch {
                self?.sceneAIWork[layerID] = nil
                self?.sceneErrorMessage = error.localizedDescription
                AppLog.windowRefresh.error("depth estimation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Moves the effect's painted area onto a layer of its own right above, taking the
    /// effect with it, and fills that place in this layer from its surroundings. Moving
    /// a separate layer moves the area's outline too, where an effect painted in place
    /// only bends what is inside. Returns the new layer's id.
    func moveScenePaintedAreaToOwnLayer(effectID: UUID, layerID: UUID, path: String) async -> UUID? {
        guard sceneAIWork[layerID] == nil,
              let layer = sceneDocumentsByPath[path]?.layers.first(where: { $0.id == layerID }),
              layer.kind == .image,
              let maskFile = layer.effects.first(where: { $0.id == effectID })?.maskFile
        else {
            return nil
        }
        let folder = SceneStore.folderURL(forVideoPath: path)
        let imageURL = SceneStore.imageURL(layer, videoPath: path)
        let maskURL = folder.appendingPathComponent(maskFile)
        let areaName = String(format: localizedString("%@(切り出し)"), layer.name)
        let stagingVideoPath = Self.sceneStagingVideoPath()
        let stagingFolder = SceneStore.folderURL(forVideoPath: stagingVideoPath)
        sceneAIWork[layerID] = .separating
        retainSceneFile(imageURL)
        retainSceneFile(maskURL)
        defer {
            sceneAIWork[layerID] = nil
            releaseSceneFile(imageURL)
            releaseSceneFile(maskURL)
            removeLeftovers(of: [stagingFolder])
        }
        do {
            let (areaFile, restFile, bounds) = try await Task.detached(priority: .userInitiated) {
                let separation = try SceneAI.separateArea(imageURL: imageURL, maskURL: maskURL)
                let small = try SceneStore.readPaintImage(maskFile, width: 256, height: 256, target: .mask, videoPath: path)
                return try (
                    SceneStore.writeImage(separation.foreground, prefix: "layer", videoPath: stagingVideoPath),
                    SceneStore.writeImage(separation.background, prefix: "layer", videoPath: stagingVideoPath),
                    SceneAreaBounds.of(small, width: 256, height: 256)
                )
            }.value
            guard var document = sceneDocumentsByPath[path],
                  let index = document.layers.firstIndex(where: { $0.id == layerID }),
                  let effectIndex = document.layers[index].effects.firstIndex(where: { $0.id == effectID })
            else {
                return nil
            }
            // Repainted or undone meanwhile: the cut-out no longer matches the area.
            guard document.layers[index].effects[effectIndex].maskFile == maskFile,
                  document.layers[index].imageFile == layer.imageFile
            else {
                sceneErrorMessage = localizedString("切り出している間に範囲が変わったので、中止しました。もう一度お試しください。")
                return nil
            }
            try adoptStagedSceneFile(areaFile, from: stagingFolder, path: path)
            try adoptStagedSceneFile(restFile, from: stagingFolder, path: path)

            let rest = document.layers[index]
            // The other effects stay on both, so the area looks as it did before.
            var area = rest.duplicated(name: areaName)
            area.imageFile = areaFile
            var moved = rest.effects[effectIndex]
            moved.maskFile = nil
            moved.areaBounds = bounds
            area.effects[effectIndex] = moved
            document.layers[index].imageFile = restFile
            document.layers[index].effects.remove(at: effectIndex)
            document.layers.insert(area, at: index + 1)
            document.linkLayer(area.id, likeLayer: layerID)
            updateScene(document, path: path, coalescing: false)
            return area.id
        } catch {
            sceneErrorMessage = error.localizedDescription
            AppLog.windowRefresh.error("moving painted area failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Puts an independent copy right above the layer and returns its id.
    func duplicateSceneLayer(id: UUID, path: String) -> UUID? {
        guard var document = sceneDocumentsByPath[path],
              let index = document.layers.firstIndex(where: { $0.id == id })
        else {
            return nil
        }
        let layer = document.layers[index]
        let copy = layer.duplicated(name: String(format: localizedString("%@ のコピー"), layer.name))
        document.layers.insert(copy, at: index + 1)
        document.linkLayer(copy.id, likeLayer: id)
        updateScene(document, path: path, coalescing: false)
        return copy.id
    }

    /// Moves the layer to `destination` (an index into the layers, bottom to top).
    func moveSceneLayer(id: UUID, to destination: Int, path: String) {
        guard var document = sceneDocumentsByPath[path],
              let index = document.layers.firstIndex(where: { $0.id == id }),
              document.layers.indices.contains(destination), destination != index
        else {
            return
        }
        let layer = document.layers.remove(at: index)
        document.layers.insert(layer, at: destination)
        updateScene(document, path: path, coalescing: false)
    }

    /// Keeps the state the editor compares the scene against.
    func recordSceneComparison(path: String) {
        guard let document = sceneDocumentsByPath[path] else {
            return
        }
        sceneComparisonSnapshots[path] = document
    }

    func removeSceneLayer(id: UUID, path: String) {
        guard var document = sceneDocumentsByPath[path],
              let index = document.layers.firstIndex(where: { $0.id == id }),
              document.layers.count > 1
        else {
            return
        }
        document.layers.remove(at: index)
        updateScene(document, path: path, coalescing: false)
    }

    /// Points the effect at a newly painted mask or flow file (nil: whole layer / still).
    /// `bounds` is the painted area of a mask.
    func setScenePaintFile(
        _ fileName: String?,
        kind: ScenePaintOverride.Target,
        effectID: UUID,
        layerID: UUID,
        path: String,
        bounds: SceneAreaBounds? = nil
    ) {
        guard var document = sceneDocumentsByPath[path],
              let layerIndex = document.layers.firstIndex(where: { $0.id == layerID })
        else {
            return
        }
        // A particle layer's own area uses the layer's id.
        if effectID == layerID, document.layers[layerIndex].particles != nil {
            document.layers[layerIndex].particles?.maskFile = fileName
            updateScene(document, path: path, coalescing: false)
            return
        }
        guard let effectIndex = document.layers[layerIndex].effects.firstIndex(where: { $0.id == effectID }) else {
            return
        }
        switch kind {
        case .mask:
            document.layers[layerIndex].effects[effectIndex].maskFile = fileName
            document.layers[layerIndex].effects[effectIndex].areaBounds = fileName == nil ? nil : bounds
        case .timeOffset:
            document.layers[layerIndex].effects[effectIndex].timeOffsetFile = fileName
        case .flow:
            document.layers[layerIndex].effects[effectIndex].flowFile = fileName
        }
        updateScene(document, path: path, coalescing: false)
    }

    /// Deletes images in the scene folder that neither the scene, its undo history,
    /// its comparison state nor a running task uses: removed layers, and masks replaced by a newer stroke.
    func pruneSceneFiles(_ document: SceneDocument, path: String) {
        let folder = SceneStore.folderURL(forVideoPath: path)
        var used = SceneStore.referencedFiles(of: document)
        used.insert("scene.json")
        for snapshot in (sceneHistories[path]?.snapshots ?? []) + [sceneComparisonSnapshots[path]].compactMap({ $0 }) {
            used.formUnion(SceneStore.referencedFiles(of: snapshot))
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            AppLog.windowRefresh.error("scene folder unreadable: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Dot files are writes in progress (SceneStore.write), possibly on another thread.
        removeLeftovers(of: names.filter { !used.contains($0) && !$0.hasPrefix(".") }
            .map { folder.appendingPathComponent($0) }
            .filter { sceneFilesInUse[$0.path] == nil })
    }

    /// Files written off the main thread go here first, then into the scene folder
    /// once the scene names them: an edit meanwhile prunes files the scene does not name.
    private static func sceneStagingVideoPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("scene-staging-\(UUID().uuidString).mp4").path
    }

    private func adoptStagedSceneFile(_ name: String, from stagingFolder: URL, path: String) throws {
        try FileManager.default.moveItem(
            at: stagingFolder.appendingPathComponent(name),
            to: SceneStore.folderURL(forVideoPath: path).appendingPathComponent(name)
        )
    }

    func retainSceneFile(_ url: URL) {
        sceneFilesInUse[url.path, default: 0] += 1
    }

    func releaseSceneFile(_ url: URL) {
        sceneFilesInUse[url.path, default: 1] -= 1
        if sceneFilesInUse[url.path] == 0 {
            sceneFilesInUse[url.path] = nil
        }
    }

    /// A scene's video is needed when it plays on the lock screen or screen saver, or
    /// when the desktop plays it without live interaction (cursor, audio, media).
    func sceneVideoIsWanted(path: String) -> Bool {
        lockScreenVideoPath == path || screenSaverVideoPath == path
            || currentVideoPath == path
            || videoOverrideByScreenID.values.contains(path)
    }

    func hasPlayableBakedVideo(forPath path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard !SceneStore.isNewerThanVideo(videoPath: path) else { return false }
        // External import providers generate a tiny 0.5fps placeholder video before
        // the real bake completes; scenes must stay live until the full loop is ready.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64, size > 1_000_000
        else {
            return false
        }
        return true
    }

    /// Bakes a scene whose video lags behind its edits, once it is chosen for the
    /// lock screen or the screen saver.
    func bakeSceneVideoIfOutOfDate(path: String?) {
        guard let path, sceneDocumentsByPath[path] != nil, sceneBakeWorkItems[path] == nil,
              !scenesBakeRunning.contains(path),
              sceneStaleVideoPaths.contains(path) || SceneStore.isNewerThanVideo(videoPath: path)
        else { return }
        scheduleSceneBake(path: path)
    }

    func scheduleSceneBake(path: String) {
        cancelSceneBake(path: path)
        guard sceneDocumentsByPath[path]?.hasUnapprovedScripts != true else {
            sceneVideosAwaitingScriptApproval.insert(path)
            return
        }
        sceneVideosAwaitingScriptApproval.remove(path)
        sceneBakeFailures[path] = nil
        // The video is out of date either way: the desktop draws the scene live, and
        // scene.json, saved after the edit, stays newer than the video until a bake.
        sceneStaleVideoPaths.insert(path)
        guard sceneVideoIsWanted(path: path) else {
            AppLog.windowRefresh.info("scene bake deferred, not on the lock screen or screen saver path=\(path, privacy: .public)")
            refreshCursorEffects()
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.startSceneBake(path: path)
            }
        }
        sceneBakeWorkItems[path] = workItem
        scenesBaking.insert(path)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sceneBakeDelay, execute: workItem)
    }

    /// Starts a bake that is waiting for edits to pause, e.g. when the editor moves
    /// to another wallpaper or closes.
    func bakeSceneNowIfPending(path: String) {
        guard let workItem = sceneBakeWorkItems[path] else {
            return
        }
        workItem.cancel()
        startSceneBake(path: path)
    }

    func bakeAllScenesNowIfPending() {
        for path in Array(sceneBakeWorkItems.keys) {
            bakeSceneNowIfPending(path: path)
        }
    }

    func retrySceneBake(path: String) {
        guard sceneDocumentsByPath[path] != nil else {
            return
        }
        scheduleSceneBake(path: path)
        bakeSceneNowIfPending(path: path)
    }

    func cancelSceneBake(path: String) {
        sceneBakingTimesOfDay[path] = nil
        sceneBakeWorkItems.removeValue(forKey: path)?.cancel()
        sceneBakeTasks.removeValue(forKey: path)?.cancel()
        sceneBakeProgress.removeValue(forKey: path)
        sceneBakeGenerations.removeValue(forKey: path)
        scenesBaking.remove(path)
        scenesBakeRunning.remove(path)
    }

    private func startSceneBake(path: String) {
        sceneBakeWorkItems[path] = nil
        guard let document = sceneDocumentsByPath[path], !document.hasUnapprovedScripts else {
            scenesBaking.remove(path)
            return
        }
        let generation = UUID()
        let timeOfDay = document.timeOfDay(at: Date())
        sceneBakeGenerations[path] = generation
        sceneBakingTimesOfDay[path] = timeOfDay
        scenesBakeRunning.insert(path)
        AppLog.windowRefresh.info("scene bake start path=\(path, privacy: .public)")
        sceneBakeTasks[path] = Task { [weak self] in
            guard let self else {
                return
            }
            let succeeded: Bool
            do {
                try await self.bakeScene(document, videoPath: path, timeOfDay: timeOfDay, generation: generation)
                succeeded = true
            } catch is CancellationError {
                return
            } catch {
                self.sceneBakeFailures[path] = error.localizedDescription
                AppLog.windowRefresh.error("scene bake failed: \(error.localizedDescription, privacy: .public)")
                succeeded = false
            }
            guard !Task.isCancelled else {
                return
            }
            self.sceneBakeTasks[path] = nil
            self.sceneBakeProgress[path] = nil
            self.sceneBakingTimesOfDay[path] = nil
            self.scenesBakeRunning.remove(path)
            if self.sceneBakeWorkItems[path] == nil {
                self.scenesBaking.remove(path)
            }
            guard succeeded else {
                // The desktop keeps drawing the scene live, so it still shows the edit.
                return
            }
            NotificationCenter.default.post(name: .sceneDidBake, object: path)
            // A part of the day may have started while this one was baking.
            if document.usesTimeOfDay, document.timeOfDay(at: Date()) != timeOfDay {
                self.updateSceneTimesOfDay()
            }
            if self.lockScreenSyncEnabled, self.effectiveLockScreenVideoPath == path {
                self.syncCurrentVideoToLockScreen()
            }
            self.reloadPlayback(forRewrittenPath: path)
            // Hand the screen back to the video once the new file is playing, so the
            // live layer does not drop out before the first new frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.sceneHandOverDelay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.sceneBakeGenerations[path] == generation,
                          !self.scenesBaking.contains(path)
                    else {
                        return
                    }
                    self.sceneStaleVideoPaths.remove(path)
                    self.refreshCursorEffects()
                }
            }
        }
    }

    /// Bakes a scene that is not in the library (one an external app offers), with
    /// its progress in sceneBakeProgress like any bake.
    func bakeSceneOutsideLibrary(_ document: SceneDocument, videoPath: String, stillOnly: Bool = false) async throws {
        defer { sceneBakeProgress.removeValue(forKey: videoPath) }
        try await bakeScene(document, videoPath: videoPath, stillOnly: stillOnly)
    }

    /// Writes the scene's video at `videoPath`: one seamless loop when anything moves,
    /// otherwise a short still.
    private func bakeScene(
        _ document: SceneDocument,
        videoPath: String,
        timeOfDay: SceneTimeOfDay? = nil,
        generation: UUID? = nil,
        stillOnly: Bool = false
    ) async throws {
        let timeOfDay = timeOfDay ?? document.timeOfDay(at: Date())
        try Task.checkCancellation()
        let output = URL(fileURLWithPath: videoPath)
        let stagedOutput = output.deletingLastPathComponent().appendingPathComponent(".scene-\(UUID().uuidString).mp4")
        defer { removeLeftovers(of: [stagedOutput]) }
        if document.isAnimated, !stillOnly {
            sceneBakeProgress[videoPath] = 0
        }
        let throttle = MediaImportProgressThrottle()
        try await SceneVideoBaker.bake(
            document: document, videoPath: videoPath, timeOfDay: timeOfDay, stillOnly: stillOnly, to: stagedOutput
        ) { [weak self] value in
            guard throttle.shouldReport(value) else { return }
            Task { @MainActor [weak self] in
                if let self, self.sceneBakeGenerations[videoPath] == generation,
                   self.sceneBakeProgress[videoPath] != nil
                {
                    self.sceneBakeProgress[videoPath] = value
                }
            }
        }
        // Edits and cancellation run on this actor too: no obsolete bake can
        // replace the library file between the check and the atomic rename.
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: stagedOutput)
        } else {
            try FileManager.default.moveItem(at: stagedOutput, to: output)
        }
        sceneBakedTimesOfDay[videoPath] = timeOfDay
    }

    func removeLeftovers(of urls: [URL]) {
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
    /// Display numbers can change when screens are reconnected; scripts' per-screen
    /// values follow the display's UUID instead.
    static func storageScreen(forDisplayID displayID: String) -> String {
        guard let number = UInt32(displayID), let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else {
            return displayID
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

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
                  let path = resolvedOverridePath(forScreenID: displayID)
                  ?? (isWebWallpaperActive ? nil : currentVideoPath),
                  let document = sceneDocumentsByPath[path]
            else {
                view.hideScene()
                continue
            }
            let hasBakedVideo = hasPlayableBakedVideo(forPath: path)
            let isStale = sceneStaleVideoPaths.contains(path) || !hasBakedVideo
            guard !document.hasUnapprovedScripts else {
                view.hideScene()
                continue
            }
            guard document.hasLiveInteraction || isStale else {
                if view.isShowingScene {
                    AppLog.windowRefresh.info(
                        "scene video display=\(displayID, privacy: .public) path=\(URL(fileURLWithPath: path).pathComponents.suffix(2).joined(separator: "/"), privacy: .public)"
                    )
                }
                view.hideScene()
                continue
            }
            do {
                if !view.isShowingScene {
                    AppLog.windowRefresh.info(
                        "scene live display=\(displayID, privacy: .public) stale=\(isStale, privacy: .public) realTime=\(document.requiresRealTimePlayback, privacy: .public) path=\(URL(fileURLWithPath: path).pathComponents.suffix(2).joined(separator: "/"), privacy: .public)"
                    )
                }
                try view.showScene(
                    document, videoPath: path, freeClock: isStale || document.requiresRealTimePlayback,
                    timeOfDay: document.timeOfDay(at: Date()),
                    maximumFramesPerSecond: maximumFramesPerSecond,
                    storageScreen: Self.storageScreen(forDisplayID: displayID)
                )
                view.setSceneScriptIssueHandler { [weak self] issues in
                    guard let self, self.sceneScriptIssues[path] != issues else { return }
                    self.sceneScriptIssues[path] = issues
                }
            } catch {
                AppLog.windowRefresh.error("scene show failed: \(error.localizedDescription, privacy: .public)")
                view.hideScene()
            }
        }
    }
}

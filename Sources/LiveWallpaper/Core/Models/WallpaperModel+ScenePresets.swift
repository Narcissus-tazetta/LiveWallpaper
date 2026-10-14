import Foundation

/// A preset on show in the editor. The scene itself is untouched until it is applied.
struct ScenePresetTrial: Equatable {
    let path: String
    let preset: ScenePreset
    let layerID: UUID
    /// Stored name → copy in the scene folder, held by sceneFilesInUse meanwhile.
    let fileNames: [String: String]
    var document: SceneDocument
}

@MainActor
extension WallpaperModel {
    func loadUserScenePresetsIfNeeded() {
        guard userScenePresets == nil else {
            return
        }
        guard let store = scenePresetStore else {
            userScenePresets = []
            return
        }
        do {
            userScenePresets = try store.loadAll()
        } catch {
            userScenePresets = []
            sceneErrorMessage = error.localizedDescription
            AppLog.persistence.error("scene presets unreadable: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Trying

    /// Shows the preset applied to the layer on the editor's preview.
    func beginScenePresetTrial(_ preset: ScenePreset, layerID: UUID, path: String) {
        endScenePresetTrial()
        guard let document = sceneDocumentsByPath[path] else {
            return
        }
        let folder = SceneStore.folderURL(forVideoPath: path)
        var fileNames: [String: String] = [:]
        if !preset.referencedFiles.isEmpty {
            guard let store = scenePresetStore else {
                return
            }
            do {
                fileNames = try store.copyFiles(of: preset, into: folder)
            } catch {
                sceneErrorMessage = error.localizedDescription
                AppLog.persistence.error("scene preset files not copied: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        // The copies are named by nothing in the scene yet: saving an edit
        // meanwhile would prune them from under the preview.
        for name in fileNames.values {
            retainSceneFile(folder.appendingPathComponent(name))
        }
        guard let applied = preset.applied(to: document, layerID: layerID, fileNames: fileNames) else {
            releaseTrialFiles(fileNames, path: path)
            return
        }
        scenePresetTrial = ScenePresetTrial(
            path: path, preset: preset, layerID: layerID, fileNames: fileNames, document: applied.document
        )
    }

    /// Follows edits, undo and redo made while a preset is on show.
    func refreshScenePresetTrial(path: String) {
        guard let trial = scenePresetTrial, trial.path == path else {
            return
        }
        guard let document = sceneDocumentsByPath[path],
              let applied = trial.preset.applied(to: document, layerID: trial.layerID, fileNames: trial.fileNames)
        else {
            endScenePresetTrial()
            return
        }
        scenePresetTrial?.document = applied.document
    }

    func endScenePresetTrial() {
        guard let trial = scenePresetTrial else {
            return
        }
        scenePresetTrial = nil
        releaseTrialFiles(trial.fileNames, path: trial.path)
    }

    /// Applies the preset on show as one undo step.
    func applyScenePresetTrial() {
        guard let trial = scenePresetTrial, let document = sceneDocumentsByPath[trial.path],
              let applied = trial.preset.applied(to: document, layerID: trial.layerID, fileNames: trial.fileNames)
        else {
            endScenePresetTrial()
            return
        }
        scenePresetTrial = nil
        updateScene(applied.document, path: trial.path, coalescing: false)
        scenePresetGuides[trial.path] = applied.guide.steps.isEmpty ? nil : applied.guide
        // The scene names the copies now, so ordinary pruning keeps them.
        releaseTrialFiles(trial.fileNames, path: trial.path)
    }

    private func releaseTrialFiles(_ fileNames: [String: String], path: String) {
        guard !fileNames.isEmpty else {
            return
        }
        let folder = SceneStore.folderURL(forVideoPath: path)
        for name in fileNames.values {
            releaseSceneFile(folder.appendingPathComponent(name))
        }
        if let document = sceneDocumentsByPath[path] {
            pruneSceneFiles(document, path: path)
        }
    }

    // MARK: - The user's presets

    /// Saves the layer's look, with the scene's particle layers when asked.
    func saveUserScenePreset(
        name: String,
        layerID: UUID,
        path: String,
        includingPaint: Bool,
        includingParticles: Bool
    ) -> Bool {
        guard let document = sceneDocumentsByPath[path],
              let layer = document.layers.first(where: { $0.id == layerID }),
              let store = scenePresetStore
        else {
            return false
        }
        loadUserScenePresetsIfNeeded()
        let preset = ScenePreset.capture(
            name: name,
            layer: layer,
            particleLayers: includingParticles ? document.layers.filter { $0.kind == .particles } : [],
            includingPaint: includingPaint
        )
        do {
            try store.save(preset, filesFrom: SceneStore.folderURL(forVideoPath: path))
        } catch {
            sceneErrorMessage = error.localizedDescription
            AppLog.persistence.error("scene preset not saved: \(error.localizedDescription, privacy: .public)")
            return false
        }
        userScenePresets?.append(preset)
        return true
    }

    func deleteUserScenePreset(_ id: UUID) {
        guard let store = scenePresetStore else {
            return
        }
        if scenePresetTrial?.preset.id == id {
            endScenePresetTrial()
        }
        do {
            try store.delete(id)
        } catch {
            sceneErrorMessage = error.localizedDescription
            AppLog.persistence.error("scene preset not deleted: \(error.localizedDescription, privacy: .public)")
            return
        }
        userScenePresets?.removeAll { $0.id == id }
    }
}

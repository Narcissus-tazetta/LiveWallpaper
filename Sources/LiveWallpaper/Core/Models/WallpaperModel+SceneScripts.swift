import Foundation

@MainActor
extension WallpaperModel {
    func receiveSceneScriptLogs(_ logs: [UUID: String], path: String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - (sceneScriptLogTimes[path] ?? 0) >= 0.5, sceneScriptLogs[path] != logs else { return }
        sceneScriptLogTimes[path] = now
        sceneScriptLogs[path] = logs
    }
    func applySceneScript(_ proposed: SceneScript, path: String, input: SceneFrameInput, timeOfDay: SceneTimeOfDay) async throws {
        guard let original = sceneDocumentsByPath[path], original.scripts.contains(where: { $0.id == proposed.id }) else { return }
        guard SceneScript.supports(version: proposed.version) else {
            throw SceneScriptIssue(scriptID: proposed.id, name: proposed.name, message: "Unsupported script API version: \(proposed.version)")
        }
        let targets = proposed.targetLayerIDs(in: original.layers)
        guard !targets.isEmpty, targets.count <= 128, proposed.source.utf8.count <= 65536, !proposed.source.contains("\0"),
              proposed.params.count <= 64, proposed.params.allSatisfy({ $0.key.utf8.count <= 128 && $0.value.isFinite })
        else { throw SceneScriptIssue(scriptID: proposed.id, name: proposed.name, message: "Select targets and use source / parameters within the supported limits") }
        var candidate = proposed
        candidate.version = SceneScript.apiVersion
        candidate.executionRevision += 1
        candidate.isAuthorized = true
        candidate.isEnabled = true
        var validation = original
        validation.scripts = [candidate]
        _ = try await Task.detached(priority: .userInitiated) {
            try SceneFrameEvaluator().evaluate(validation, input: input, timeOfDay: timeOfDay)
        }.value
        guard var document = sceneDocumentsByPath[path], let index = document.scripts.firstIndex(where: { $0.id == candidate.id }) else { return }
        // Validation suspends: do not replace a script somebody edited or undid meanwhile.
        guard document.scripts[index] == original.scripts.first(where: { $0.id == candidate.id }) else {
            throw SceneScriptIssue(scriptID: proposed.id, name: proposed.name, message: "Script changed during validation. Run it again.")
        }
        SceneScriptPermissions.authorize(candidate, path: path)
        sceneScriptIssues[path] = []
        document.scripts[index] = candidate
        updateScene(document, path: path, coalescing: false)
    }

    func addSceneScript(_ sample: SceneScriptSample, path: String, layerID: UUID?) -> UUID? {
        guard var document = sceneDocumentsByPath[path], document.scripts.count < SceneScript.maximumCount else { return nil }
        var script = SceneScript(source: sample.source, layerIDs: layerID.map { [$0] } ?? document.layers.map(\.id))
        script.name = localizedString(sample.title)
        script.isEnabled = false
        script.usesTime = sample.usesTime
        script.usesCursor = sample.usesCursor
        script.usesTimeOfDay = sample.usesTimeOfDay
        if sample == .blank { script.params = [:] }
        script.targetsAllLayers = sample == .blank || sample == .master
        document.scripts.append(script)
        updateScene(document, path: path, coalescing: false)
        return script.id
    }

    func removeSceneScript(_ id: UUID, path: String) {
        guard var document = sceneDocumentsByPath[path] else { return }
        document.scripts.removeAll { $0.id == id }
        updateScene(document, path: path, coalescing: false)
    }

    func stopSceneScript(_ id: UUID, path: String) {
        guard var document = sceneDocumentsByPath[path], let index = document.scripts.firstIndex(where: { $0.id == id }) else { return }
        document.scripts[index].isEnabled = false
        updateScene(document, path: path, coalescing: false)
    }
}

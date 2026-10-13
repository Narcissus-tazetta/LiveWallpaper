import SwiftUI

@MainActor
final class SceneScriptEditorController: ObservableObject {
    struct Draft {
        var script: SceneScript
        var paramsText: String
        var error: String?
        var isValidating = false
        var baseline: SceneScript
    }
    @Published private(set) var drafts: [String: [UUID: Draft]] = [:]

    func draft(for script: SceneScript, path: String) -> Draft {
        drafts[path]?[script.id] ?? Draft(script: script, paramsText: parameters(script.params), baseline: script)
    }

    func edit(_ script: SceneScript, path: String, change: (inout Draft) -> Void) {
        var value = draft(for: script, path: path)
        change(&value)
        drafts[path, default: [:]][script.id] = value
    }

    func discard(_ script: SceneScript, path: String) {
        drafts[path]?[script.id] = nil
    }

    func isDirty(_ script: SceneScript, path: String) -> Bool {
        let value = draft(for: script, path: path)
        return value.script != script || value.paramsText != parameters(script.params)
    }

    func run(_ script: SceneScript, path: String, model: WallpaperModel, input: SceneFrameInput, timeOfDay: SceneTimeOfDay) async {
        var value = draft(for: script, path: path)
        guard !value.isValidating else { return }
        value.isValidating = true
        value.error = nil
        drafts[path, default: [:]][script.id] = value
        let submitted = value
        do {
            value.script.params = try JSONDecoder().decode([String: Double].self, from: Data(value.paramsText.utf8))
            try await model.applySceneScript(value.script, path: path, input: input, timeOfDay: timeOfDay)
            // Keep text entered while validation was running as a new unapplied draft.
            if let latest = drafts[path]?[script.id], latest.script == submitted.script,
               latest.paramsText == submitted.paramsText {
                drafts[path]?[script.id] = nil
            } else {
                drafts[path]?[script.id]?.isValidating = false
                drafts[path]?[script.id]?.baseline = model.sceneDocumentsByPath[path]?.scripts.first { $0.id == script.id } ?? script
            }
        } catch {
            drafts[path]?[script.id]?.error = error.localizedDescription
            drafts[path]?[script.id]?.isValidating = false
        }
    }

    private func parameters(_ values: [String: Double]) -> String {
        // This text is a user-editable boundary; sorted keys keep unchanged drafts stable.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { return String(decoding: try encoder.encode(values), as: UTF8.self) }
        catch { preconditionFailure("Non-finite script parameters reached the editor: \(error)") }
    }
}

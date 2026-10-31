import SwiftUI

/// Which scene the editor window shows. One window edits one scene at a time; opening
/// another scene switches it.
@MainActor
final class SceneEditorSession: ObservableObject {
    static let shared = SceneEditorSession()

    @Published private(set) var path: String?

    /// Shows the editor window on `path`; AppDelegate owns the window. Without
    /// `bringToFront` an open window only switches scenes.
    func open(path: String, bringToFront: Bool = true) {
        self.path = path
        if bringToFront {
            NotificationCenter.default.post(name: .openSceneEditor, object: nil)
        }
    }

    func close() {
        path = nil
    }
}

struct SceneEditorRootView: View {
    @ObservedObject var model: WallpaperModel
    @ObservedObject var session: SceneEditorSession

    var body: some View {
        Group {
            if let path = session.path {
                // A new identity per scene, so selection, tools and the preview start over.
                SceneEditorView(model: model, path: path)
                    .id(path)
            }
        }
        .environment(\.locale, model.appLocale)
    }
}

enum SceneInspectorTab: Hashable {
    case layer, motion, links, scene
}

struct SceneEditorView: View {
    @ObservedObject var model: WallpaperModel
    let path: String

    @State var selectedSceneLayerID: UUID?
    @State var selectedSceneEffectID: UUID?
    @State var sceneEditorTool: SceneEditorTool?
    @State var selectedScenePinID: UUID?
    @State var selectedSceneKeyframeID: UUID?
    @StateObject var sceneMaskPainter = SceneMaskPainter()
    @StateObject var scenePreviewController = ScenePreviewController()
    @StateObject var sceneScriptEditor = SceneScriptEditorController()
    @State var renamingSceneLayerID: UUID?
    @State var sceneLayerNameDraft = ""
    @State var draggedSceneLayerID: UUID?
    @State var isSavingScenePreset = false
    @State var scenePresetNameDraft = ""
    @State var scenePresetIncludesPaint = false
    @State var scenePresetIncludesParticles = true
    @State var scenePresetPendingDeletion: ScenePreset?
    @State var selectedSceneLinkID: UUID?
    @State var inspectorTab: SceneInspectorTab = .layer
    @State var hoveredSceneLayerID: UUID?
    @AppStorage("sceneEditorShowsHints") var showsSceneHints = false

    var body: some View {
        wallpaperSceneEditorPanel
            .environment(\.sceneShowsHints, showsSceneHints)
    }

    /// Whether the window still shows this view's scene. An import that finishes after
    /// the user moved to another scene must not select anything there.
    var isStillEditing: Bool {
        SceneEditorSession.shared.path == path
    }

    /// Grey text is an explanation and follows the hints setting; a colored one is a
    /// warning and always shows.
    @ViewBuilder
    func settingsFootnote(_ text: String, color: Color = .secondary) -> some View {
        if color == .secondary {
            SceneHintText(text: text)
        } else {
            Text(text)
                .font(.caption)
                .foregroundColor(color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

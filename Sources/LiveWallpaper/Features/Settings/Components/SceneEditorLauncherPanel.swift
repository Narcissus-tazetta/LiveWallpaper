import SwiftUI

extension SettingsView {
    /// The scene editor lives in its own window; this tab only opens it.
    var sceneEditorLauncherPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let path = fitEditor.resolvedVideoPath(), model.sceneDocumentsByPath[path] != nil {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.registeredVideoDisplayName(for: path))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(model.localizedString("レイヤー・エフェクト・動きを、大きなプレビューを見ながら編集します。"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button(model.localizedString("シーンエディタを開く")) {
                        SceneEditorSession.shared.open(path: path)
                    }
                }
            } else {
                Text(model.localizedString("下の壁紙一覧から画像の壁紙を選択すると、レイヤーを編集できます"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCardBackground()
    }
}

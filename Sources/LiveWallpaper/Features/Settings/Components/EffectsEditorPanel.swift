import SwiftUI

extension SettingsView {
  /// Cursor effects for one wallpaper, overriding the app-wide ones in Settings.
  var wallpaperEffectsEditorPanel: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let path = wallpaperEditor.resolvedVideoPath(), !path.isEmpty {
        Text(model.registeredVideoDisplayName(for: path))
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)

        Toggle(
          model.localizedString("この壁紙だけの設定を使う"),
          isOn: Binding(
            get: { model.cursorEffectsOverride(path: path) != nil },
            set: { model.setCursorEffectsOverride($0 ? model.cursorEffects : nil, path: path) }
          )
        )

        if model.cursorEffectsOverride(path: path) != nil {
          VStack(alignment: .leading, spacing: 10) {
            cursorEffectControls(.wallpaper(path))
          }
          settingsFootnote(
            model.localizedString(
              "変更はすぐに壁紙へ反映されます。この設定は、壁紙の書き出しや Store への投稿にも含まれます。"
            )
          )
        } else {
          settingsFootnote(
            model.localizedString("設定の「カーソルのエフェクト」に従います。")
          )
        }
      } else {
        Text(model.localizedString("下の壁紙一覧から動画を選択すると、この壁紙だけのカーソルのエフェクトを設定できます"))
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .settingsCardBackground()
  }
}

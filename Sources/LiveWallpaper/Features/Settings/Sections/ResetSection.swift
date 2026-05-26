import SwiftUI

extension SettingsView {
  var resetSettingsSection: some View {
    Section(header: Label(model.localizedString("設定"), systemImage: "arrow.counterclockwise")) {
      HStack(spacing: 10) {
        Button(model.localizedString("再生をリフレッシュ")) {
          NotificationCenter.default.post(name: .refreshPlayback, object: nil)
        }
        .buttonStyle(.bordered)

        Button(model.localizedString("設定をリセット"), role: .destructive) {
          isResetSettingsDialogPresented = true
        }
        .buttonStyle(.bordered)
        Spacer()
      }

      Text(model.localizedString("再生表示が崩れたときはリフレッシュを使って再初期化できます。設定リセットは表示・再生設定を初期値に戻します"))
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }
}

import SwiftUI

extension SettingsView {
  var videoSettingsSection: some View {
    Section(header: Label(model.localizedString("動画"), systemImage: "film")) {
      Toggle(model.localizedString("クリック貫通を有効にする"), isOn: clickThroughBinding)
      Toggle(model.localizedString("ログイン時に自動起動する"), isOn: launchAtLoginBinding)
      Toggle(model.localizedString("音声を再生する"), isOn: audioEnabledBinding)

      HStack(spacing: 10) {
        Text(model.localizedString("音量"))
          .frame(width: 150, alignment: .leading)

        Slider(value: audioVolumeBinding, in: 0...1)
          .disabled(!model.audioEnabled)
          .frame(minWidth: 180, maxWidth: .infinity)

        TextField("", text: $volumeInput)
          .textFieldStyle(.roundedBorder)
          .controlSize(.small)
          .multilineTextAlignment(.trailing)
          .frame(width: 44)
          .disabled(!model.audioEnabled)
          .focused($isVolumeInputFocused)
          .onSubmit { commitVolumeInput() }
          .onChange(of: volumeInput) { newValue in
            let filtered = String(newValue.filter(\.isNumber).prefix(3))
            if filtered != newValue {
              volumeInput = filtered
            }
          }

        Text(model.localizedString("%"))
          .foregroundColor(.secondary)
      }
    }
  }
}

import SwiftUI

extension SettingsView {
  static let videoSearchKeywords: [String] = [
    "動画",
    "メディアを追加",
    "GIF",
    "WebP",
    "APNG",
    "アニメ画像",
    "クリック貫通を有効にする",
    "ログイン時に自動起動する",
    "音声を再生する",
    "音量",
  ]

  var videoSettingsSection: some View {
    Section(header: SettingsSectionHeader(title: model.localizedString("動画"))) {
      Toggle(model.localizedString("クリック貫通を有効にする"), isOn: clickThroughBinding)
      Toggle(model.localizedString("ログイン時に自動起動する"), isOn: launchAtLoginBinding)
      Toggle(model.localizedString("音声を再生する"), isOn: audioEnabledBinding)

      LabeledContent(model.localizedString("音量")) {
        HStack(spacing: 8) {
          Image(systemName: "speaker.fill")
            .foregroundStyle(.secondary)
          Slider(value: audioVolumeBinding, in: 0...1)
            .frame(maxWidth: 240)
          Image(systemName: "speaker.wave.3.fill")
            .foregroundStyle(.secondary)
        }
        .font(.caption)
      }
      .disabled(!model.audioEnabled)
    }
  }
}

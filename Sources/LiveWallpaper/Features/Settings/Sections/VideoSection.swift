import ApplicationServices
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
    "壁紙内のボタンをクリックで操作する",
    "ログイン時に自動起動する",
    "音声を再生する",
    "音量",
    "書き出し画質",
    "画質",
    "最高",
    "高",
    "標準",
  ]

  var videoSettingsSection: some View {
    Section(header: SettingsSectionHeader(title: model.localizedString("動画"))) {
      Toggle(model.localizedString("クリック貫通を有効にする"), isOn: clickThroughBinding)
      Toggle(model.localizedString("壁紙内のボタンをクリックで操作する"), isOn: webInteractionBinding)
        .disabled(!model.clickThrough)
      if model.webInteractionEnabled, !AXIsProcessTrusted() {
        Text(model.localizedString("アクセシビリティの許可が必要です。システム設定のプライバシーとセキュリティで許可してください。"))
          .font(.caption)
          .foregroundStyle(.secondary)
        PermissionRepairHelp(model: model)
      }
      Toggle(model.localizedString("ログイン時に自動起動する"), isOn: launchAtLoginBinding)
      Toggle(model.localizedString("音声を再生する"), isOn: audioEnabledBinding)

      LabeledContent(model.localizedString("音量")) {
        HStack(spacing: 8) {
          Image(systemName: "speaker.fill")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          Slider(value: audioVolumeBinding, in: 0...1)
            .frame(maxWidth: 240)
            .accessibilityLabel(model.localizedString("音量"))
            .accessibilityValue("\(Int((model.audioVolume * 100).rounded()))%")
          Image(systemName: "speaker.wave.3.fill")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          Text("\(Int((model.audioVolume * 100).rounded()))%")
            .accessibilityHidden(true)
            .font(.body)
            .monospacedDigit()
            .foregroundColor(.secondary)
            .frame(width: 40, alignment: .trailing)
        }
        .font(.caption)
      }
      .disabled(!model.audioEnabled)

      Picker(model.localizedString("書き出し画質"), selection: bakeQualityBinding) {
        Text(model.localizedString("最高")).tag(BakeQuality.maximum)
        Text(model.localizedString("高")).tag(BakeQuality.high)
        Text(model.localizedString("標準")).tag(BakeQuality.standard)
      }
      .pickerStyle(.menu)

      Text(model.localizedString("変更は次回以降の書き出しに適用。既存の動画は変わりません"))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

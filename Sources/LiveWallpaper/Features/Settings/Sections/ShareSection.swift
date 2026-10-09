import SwiftUI

extension SettingsView {
  static let shareSearchKeywords: [String] = [
    "共有",
    "高度な共有を有効にする",
    ".lwpkg",
  ]

  var shareSettingsSection: some View {
    Section(header: SettingsSectionHeader(title: model.localizedString("共有"))) {
      Toggle(model.localizedString("高度な共有を有効にする"), isOn: advancedSharingBinding)

      Text(model.localizedString("オフのときは動画ファイルだけを共有します。オンにすると配置情報を含む .lwpkg も一緒に共有します。"))
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }
}

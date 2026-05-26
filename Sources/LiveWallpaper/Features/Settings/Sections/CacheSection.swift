import SwiftUI

extension SettingsView {
  var cacheSettingsSection: some View {
    Section(header: Label(model.localizedString("キャッシュ"), systemImage: "externaldrive")) {
      HStack(spacing: 10) {
        Button(model.localizedString("保存先を開く")) {
          NotificationCenter.default.post(name: .openCacheFolder, object: nil)
        }
        .buttonStyle(.bordered)

        Button(model.localizedString("キャッシュ削除")) {
          NotificationCenter.default.post(name: .clearCache, object: nil)
        }
        .buttonStyle(.bordered)

        Spacer()
      }
    }
  }
}

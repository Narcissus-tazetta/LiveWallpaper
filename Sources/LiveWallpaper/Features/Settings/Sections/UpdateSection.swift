import SwiftUI

extension SettingsView {
  static let updateSearchKeywords: [String] = [
    "アップデート",
    "アップデートを自動で確認する（起動時にも通知）",
    "今すぐ確認",
    "手動ダウンロード",
  ]

  var updateSettingsSection: some View {
    Section(
      header: Label(
        model.localizedString("アップデート"),
        systemImage: "arrow.triangle.2.circlepath"
      )
    ) {
      Toggle(model.localizedString("アップデートを自動で確認する（起動時にも通知）"), isOn: autoUpdateBinding)

      HStack {
        Button(model.localizedString("今すぐ確認")) {
          NotificationCenter.default.post(name: .checkUpdatesNow, object: nil)
        }
        .buttonStyle(.bordered)

        Button(model.localizedString("手動ダウンロード")) {
          NotificationCenter.default.post(name: .openReleasePage, object: nil)
        }
        .buttonStyle(.bordered)
        Spacer()
      }

      Text(
        model
          .localizedString(
            "更新が失敗する場合は、Releasesから最新版を取得して /Applications の LiveWallpaper.app を置き換えてください"
          )
      )
      .font(.caption)
      .foregroundColor(.secondary)
    }
  }
}

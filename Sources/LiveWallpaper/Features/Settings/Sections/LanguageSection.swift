import SwiftUI

extension SettingsView {
  static let languageSearchKeywords: [String] = [
    "言語",
    "アプリの言語",
  ]

  var languageSettingsSection: some View {
    LanguageSettingsView(model: model)
  }
}

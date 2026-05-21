import SwiftUI

struct LanguageSettingsView: View {
    @ObservedObject var model: WallpaperModel

    var body: some View {
        Section(header: Label(model.localizedString("言語"), systemImage: "globe")) {
            HStack {
                Text(model.localizedString("アプリの言語"))
                Spacer()
                Menu {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Button(action: { model.setAppLanguage(language) }) {
                            HStack {
                                Text(languageDisplayName(language))
                                if model.appLanguage == language {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(languageDisplayName(model.appLanguage))
                        .foregroundColor(.accentColor)
                }
            }
        }
    }

    private func languageDisplayName(_ language: AppLanguage) -> String {
        switch language {
        case .automatic:
            return model.localizedString("自動（システム設定に従う）")
        case .japanese:
            return model.localizedString("日本語")
        case .english:
            return model.localizedString("English")
        }
    }
}

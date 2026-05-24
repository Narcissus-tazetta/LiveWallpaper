import SwiftUI

struct LanguageSettingsView: View {
    @ObservedObject var model: WallpaperModel

    var body: some View {
        Section(header: Label(model.localizedString("言語"), systemImage: "globe")) {
            HStack {
                Text(model.localizedString("アプリの言語"))
                Spacer()
                Menu {
                    ForEach(AppLanguage.selectableLanguages, id: \.self) { language in
                        Button(action: { model.setAppLanguage(language) }) {
                            HStack {
                                Text(model.localizedString(language.displayNameKey))
                                if model.appLanguage == language {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(model.localizedString(model.appLanguage.displayNameKey))
                        .foregroundColor(.accentColor)
                }
            }
        }
    }

}

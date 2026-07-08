import Foundation

enum AppLocalization {
    private static func resolveBundle(for languageCode: String) -> Bundle? {
        if let path = Bundle.main.path(forResource: languageCode, ofType: "lproj") {
            return Bundle(path: path)
        }
        if let resourceURL = Bundle.main.resourceURL {
            let alt = resourceURL.appendingPathComponent("\(languageCode).lproj").path
            if let bundle = Bundle(path: alt) {
                return bundle
            }
        }
        let cwd = FileManager.default.currentDirectoryPath
        let altPath = cwd + "/Sources/LiveWallpaper/Resources/\(languageCode).lproj"
        return Bundle(path: altPath)
    }

    static func localizedString(_ key: String, languageCode: String) -> String {
        guard languageCode != "ja" else { return key }
        guard let bundle = resolveBundle(for: languageCode) else {
            return key
        }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
}

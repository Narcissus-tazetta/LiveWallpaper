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
        NSLog("[AppLocalization] lookup key='\(key)' lang='\(languageCode)'")
        guard languageCode != "ja" else { return key }
        let bundle = resolveBundle(for: languageCode)
        guard let bundle = bundle else {
            NSLog("[AppLocalization] bundle not found for lang=\(languageCode)")
            return key
        }
        let result = bundle.localizedString(forKey: key, value: key, table: "Localizable")
        NSLog("[AppLocalization] result='\(result)' for key='\(key)' lang='\(languageCode)'")
        return result
    }
}
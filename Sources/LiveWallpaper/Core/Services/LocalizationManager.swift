import Foundation
import ObjectiveC.runtime

enum LocalizationManager {
    static var bundle: Bundle?

    static func swizzle() {
        let original = class_getInstanceMethod(
            Bundle.self,
            #selector(Bundle.localizedString(forKey:value:table:))
        )
        let swizzled = class_getInstanceMethod(
            Bundle.self,
            #selector(Bundle.lw_localizedString(forKey:value:table:))
        )
        if let o = original, let s = swizzled {
            method_exchangeImplementations(o, s)
        }
    }

    /// "ja" also gets an explicit bundle: falling back to Bundle.main would pick the
    /// system's preferred localization (e.g. en) even though the user chose Japanese.
    static func setLanguage(_ code: String) {
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let b = Bundle(path: path)
        {
            bundle = b
            return
        }
        if let resourceURL = Bundle.main.resourceURL {
            let alt = resourceURL.appendingPathComponent("\(code).lproj").path
            if let b = Bundle(path: alt) {
                bundle = b
                return
            }
        }
        bundle = nil
    }
}

private extension Bundle {
    @objc func lw_localizedString(
        forKey key: String,
        value: String?,
        table tableName: String?
    ) -> String {
        if let b = LocalizationManager.bundle {
            return b.lw_localizedString(forKey: key, value: value, table: tableName)
        }
        return lw_localizedString(forKey: key, value: value, table: tableName)
    }
}

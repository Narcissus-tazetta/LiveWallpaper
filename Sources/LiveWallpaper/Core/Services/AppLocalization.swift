import Foundation

enum AppLocalization {
    private final class BundleToken {}

    private static let resourceBundleName = "LiveWallpaper_LiveWallpaper.bundle"

    /// The packaged .app keeps the .lproj folders in Contents/Resources. A bare executable
    /// (`swift run`, Xcode, `swift test`) has them only inside the SwiftPM resource bundle
    /// next to it, which the packaged .app does not ship, so `Bundle.module` (which traps
    /// when the bundle is missing) cannot be used.
    static func bundle(for languageCode: String) -> Bundle? {
        if let path = Bundle.main.path(forResource: languageCode, ofType: "lproj") {
            return Bundle(path: path)
        }
        let searchDirectories = [
            Bundle.main.bundleURL,
            Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent(),
        ]
        for directory in searchDirectories {
            guard let resources = Bundle(url: directory.appendingPathComponent(resourceBundleName)),
                  let path = resources.path(forResource: languageCode, ofType: "lproj")
            else {
                continue
            }
            return Bundle(path: path)
        }
        return nil
    }

    static func localizedString(_ key: String, languageCode: String) -> String {
        guard languageCode != "ja" else { return key }
        guard let bundle = bundle(for: languageCode) else {
            return key
        }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
}

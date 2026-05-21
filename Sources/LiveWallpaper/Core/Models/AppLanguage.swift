import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case automatic
    case japanese
    case english

    var id: String {
        rawValue
    }

    static var systemLanguageCode: String {
        let preferred = Locale.preferredLanguages.first ?? Locale.current.identifier
        let canonical = Locale.canonicalLanguageIdentifier(from: preferred)
        let code = canonical.split(separator: "-").first.map(String.init) ?? "ja"
        return code.isEmpty ? "ja" : code
    }

    var effectiveLanguageCode: String {
        switch self {
        case .automatic:
            return Self.systemLanguageCode == "en" ? "en" : "ja"
        case .japanese:
            return "ja"
        case .english:
            return "en"
        }
    }
}
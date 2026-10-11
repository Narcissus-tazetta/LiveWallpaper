import Foundation

struct LanguageOption: Hashable {
    let language: AppLanguage
    let code: String
    let displayNameKey: String
    let aliases: [String]
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case automatic
    case japanese
    case english
    case simplifiedChinese
    case traditionalChinese
    case korean
    case spanish
    case french
    case german
    case brazilianPortuguese
    case vietnamese
    case turkish

    var id: String {
        rawValue
    }

    static var selectableLanguages: [AppLanguage] {
        [.automatic] + supportedOptions.map(\.language)
    }

    static var supportedOptions: [LanguageOption] {
        [
            LanguageOption(
                language: .japanese,
                code: "ja",
                displayNameKey: "日本語",
                aliases: ["ja", "ja-JP"]
            ),
            LanguageOption(
                language: .english,
                code: "en",
                displayNameKey: "English",
                aliases: ["en", "en-US", "en-GB", "en-AU", "en-CA"]
            ),
            LanguageOption(
                language: .simplifiedChinese,
                code: "zh-Hans",
                displayNameKey: "简体中文",
                aliases: ["zh-Hans", "zh-CN", "zh-SG", "zh-CHS"]
            ),
            LanguageOption(
                language: .traditionalChinese,
                code: "zh-Hant",
                displayNameKey: "繁體中文",
                aliases: ["zh-Hant", "zh-TW", "zh-HK", "zh-MO", "zh-CHT"]
            ),
            LanguageOption(
                language: .korean,
                code: "ko",
                displayNameKey: "한국어",
                aliases: ["ko", "ko-KR"]
            ),
            LanguageOption(
                language: .spanish,
                code: "es",
                displayNameKey: "Español",
                aliases: ["es", "es-ES", "es-419", "es-MX"]
            ),
            LanguageOption(
                language: .french,
                code: "fr",
                displayNameKey: "Français",
                aliases: ["fr", "fr-FR", "fr-CA"]
            ),
            LanguageOption(
                language: .german,
                code: "de",
                displayNameKey: "Deutsch",
                aliases: ["de", "de-DE", "de-AT", "de-CH"]
            ),
            LanguageOption(
                language: .brazilianPortuguese,
                code: "pt-BR",
                displayNameKey: "Português (Brasil)",
                aliases: ["pt", "pt-BR", "pt-PT"]
            ),
            LanguageOption(
                language: .vietnamese,
                code: "vi",
                displayNameKey: "Tiếng Việt",
                aliases: ["vi", "vi-VN"]
            ),
            LanguageOption(
                language: .turkish,
                code: "tr",
                displayNameKey: "Türkçe",
                aliases: ["tr", "tr-TR"]
            ),
        ]
    }

    static var systemLanguageCode: String {
        resolvePreferredLanguageCode(Locale.preferredLanguages)
    }

    var displayNameKey: String {
        switch self {
        case .automatic:
            return "自動（システム設定に従う）"
        default:
            return Self.optionByLanguage[self]?.displayNameKey ?? "English"
        }
    }

    var effectiveLanguageCode: String {
        switch self {
        case .automatic:
            return Self.systemLanguageCode
        default:
            return Self.optionByLanguage[self]?.code ?? "en"
        }
    }
}

extension AppLanguage {
    fileprivate static var optionByLanguage: [AppLanguage: LanguageOption] {
        Dictionary(uniqueKeysWithValues: supportedOptions.map { ($0.language, $0) })
    }

    fileprivate static func resolvePreferredLanguageCode(_ preferred: [String]) -> String {
        for identifier in preferred {
            if let option = resolveSupportedOption(identifier) {
                return option.code
            }
        }
        return optionByLanguage[.english]?.code ?? "en"
    }

    fileprivate static func resolveSupportedOption(_ identifier: String) -> LanguageOption? {
        let normalized = normalizeIdentifier(identifier)
        if normalized.isEmpty {
            return nil
        }

        for option in supportedOptions {
            if normalizeIdentifier(option.code) == normalized {
                return option
            }
            if option.aliases.contains(where: { normalizeIdentifier($0) == normalized }) {
                return option
            }
        }

        if let base = normalized.split(separator: "-").first {
            let baseCode = String(base)
            if baseCode == "zh" {
                return optionByLanguage[usesTraditionalChinese(normalized) ? .traditionalChinese : .simplifiedChinese]
            }
            for option in supportedOptions {
                if normalizeIdentifier(option.code) == baseCode {
                    return option
                }
                if option.aliases.contains(where: { normalizeIdentifier($0) == baseCode }) {
                    return option
                }
            }
        }

        return nil
    }

    /// Identifiers such as "zh-Hant-JP" or "zh-TW" carry the script or region only as a
    /// suffix, so they miss the exact aliases above.
    fileprivate static func usesTraditionalChinese(_ normalized: String) -> Bool {
        let parts = normalized.split(separator: "-").dropFirst()
        if parts.contains("hans") {
            return false
        }
        return parts.contains { ["hant", "tw", "hk", "mo"].contains($0) }
    }

    fileprivate static func normalizeIdentifier(_ identifier: String) -> String {
        let canonical = Locale.canonicalLanguageIdentifier(from: identifier)
        return canonical.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}

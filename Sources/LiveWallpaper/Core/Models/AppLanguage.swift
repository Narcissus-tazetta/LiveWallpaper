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
    case traditionalChinese
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
                language: .traditionalChinese,
                code: "zh-Hant",
                displayNameKey: "繁體中文",
                aliases: [
                    "zh-Hant",
                    "zh-TW",
                    "zh-HK",
                    "zh-MO",
                    "zh-CHT",
                    "zh-Hant-TW",
                    "zh-Hant-HK",
                    "zh-Hant-MO",
                    "zh-Hant-CHT",
                    "zh-Hans",
                    "zh-CN",
                    "zh-SG",
                    "zh-CHS",
                ]
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
                return optionByLanguage[.traditionalChinese]
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

    fileprivate static func normalizeIdentifier(_ identifier: String) -> String {
        let canonical = Locale.canonicalLanguageIdentifier(from: identifier)
        return canonical.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}

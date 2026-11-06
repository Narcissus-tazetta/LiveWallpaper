import Foundation
import XCTest

/// The Japanese source strings are the keys, so a language missing a key silently shows
/// Japanese, and a translation whose format specifiers differ from the key's makes
/// `String(format:)` read the wrong argument type.
final class LocalizationCatalogTests: XCTestCase {
    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/LiveWallpaper/Resources", isDirectory: true)

    /// ja holds only the entries whose wording differs from the key.
    private static let sourceLanguage = "ja"
    private static let referenceLanguage = "en"

    private func strings(_ language: String) throws -> [String: String] {
        let url = Self.resources.appendingPathComponent("\(language).lproj/Localizable.strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], url.path)
    }

    private func languages() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: Self.resources.path)
            .filter { $0.hasSuffix(".lproj") }
            .map { String($0.dropLast(".lproj".count)) }
            .sorted()
    }

    func testEveryLanguageHasTheReferenceKeys() throws {
        let reference = try Set(strings(Self.referenceLanguage).keys)
        let others = try languages()
            .filter { $0 != Self.referenceLanguage && $0 != Self.sourceLanguage }
        XCTAssertFalse(others.isEmpty)
        for language in others {
            let keys = try Set(strings(language).keys)
            XCTAssertEqual(reference.subtracting(keys).sorted(), [], "\(language) is missing keys")
            XCTAssertEqual(
                keys.subtracting(reference).sorted(),
                [],
                "\(language) has keys en does not"
            )
        }
        let sourceKeys = try Set(strings(Self.sourceLanguage).keys)
        XCTAssertEqual(
            sourceKeys.subtracting(reference).sorted(),
            [],
            "ja overrides keys en does not have"
        )
    }

    func testTranslationsKeepTheKeysFormatSpecifiers() throws {
        for language in try languages() {
            // A key without specifiers is never passed to String(format:), so a literal "10%"
            // in its translation is just text.
            for (key, value) in try strings(language)
                where !Self.formatSpecifiers(in: key).isEmpty
            {
                XCTAssertEqual(
                    Self.formatSpecifiers(in: value), Self.formatSpecifiers(in: key),
                    "\(language): \(key) → \(value)"
                )
            }
        }
    }

    /// Specifiers by argument position, so a translation may reorder them with `%1$@`.
    static func formatSpecifiers(in text: String) -> [String] {
        let specifier =
            #/%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j)?([@dDuUxXoOfeEgGcCsSpaA%])/#
        var sequential = 0
        var specifiers: [(position: Int, conversion: String)] = []
        for match in text.matches(of: specifier) {
            let (_, explicitPosition, length, conversion) = match.output
            guard conversion != "%" else { continue }
            let position: Int
            if let explicit = explicitPosition.flatMap({ Int($0) }) {
                position = explicit
            } else {
                sequential += 1
                position = sequential
            }
            specifiers.append((position, String(length ?? "") + conversion))
        }
        return specifiers.sorted { $0.position < $1.position }.map(\.conversion)
    }

    func testFormatSpecifierParsing() {
        XCTAssertEqual(Self.formatSpecifiers(in: "%@ / 上限%@"), ["@", "@"])
        XCTAssertEqual(Self.formatSpecifiers(in: "%2$@ then %1$lld"), ["lld", "@"])
        XCTAssertEqual(Self.formatSpecifiers(in: "100%% done %d"), ["d"])
    }
}

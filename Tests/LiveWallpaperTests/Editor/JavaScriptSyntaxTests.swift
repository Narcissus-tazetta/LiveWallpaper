import XCTest
@testable import LiveWallpaper

final class JavaScriptSyntaxTests: XCTestCase {
    func testCommentsStringsNumbersAndCallsRemainSeparate() {
        let source = "// 日本語 😀\nconst value = 1.25e-3; const text = '/* not a comment */'; return wave(value); const re = /[a-z/]+/gi;"
        let text = source as NSString
        let tokens = JavaScriptSyntax.tokens(in: source)
        func contains(_ value: String, _ kind: JavaScriptSyntax.Kind) -> Bool {
            tokens.contains { text.substring(with: $0.range) == value && $0.kind == kind }
        }
        XCTAssertTrue(contains("// 日本語 😀", .comment))
        XCTAssertTrue(contains("const", .keyword))
        XCTAssertTrue(contains("1.25e-3", .number))
        XCTAssertTrue(contains("'/* not a comment */'", .string))
        XCTAssertTrue(contains("wave", .function))
        XCTAssertTrue(contains("/[a-z/]+/gi", .regex))
        XCTAssertFalse(tokens.contains { $0.kind == .comment && text.substring(with: $0.range).hasPrefix("/*") })
    }

    func testIncompleteDraftAndLargeInputHaveBoundedRanges() {
        for source in ["/* unfinished", "`template\n${value}`", "const s = 'unfinished\nreturn 1;", String(repeating: "const x = 1;\n", count: 20000)] {
            let length = (source as NSString).length
            for token in JavaScriptSyntax.tokens(in: source) {
                XCTAssertGreaterThan(token.range.length, 0)
                XCTAssertLessThanOrEqual(NSMaxRange(token.range), min(length, 131072))
            }
        }
    }
}

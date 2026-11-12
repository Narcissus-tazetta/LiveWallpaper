import Foundation
@testable import LiveWallpaper
import QuickJS
import XCTest

/// A script's result must reach the app as the same values whether the bridge hands it
/// over directly or as JSON text.
final class SceneScriptOutputTests: XCTestCase {
    private func evaluate(_ source: String) throws -> (Any, isDirect: Bool) {
        var error: UnsafeMutablePointer<CChar>?
        let program = try XCTUnwrap(
            source.withCString { lwjs_compile($0, &error) },
            error.map { String(cString: $0) } ?? ""
        )
        defer { lwjs_destroy(program) }
        let emptyObject: [UInt8] = [6, 0, 0, 0, 0]
        var length = 0
        let result = emptyObject.withUnsafeBufferPointer { lwjs_evaluate(
            program,
            $0.baseAddress!,
            1,
            &length,
            &error
        ) }
        guard let result else { throw NSError(
            domain: "script",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: String(cString: error!)]
        ) }
        defer { lwjs_free_string(result) }
        let bytes = UnsafeRawBufferPointer(start: result, count: length)
        if bytes.first == SceneScriptOutputReader.magic {
            return try (XCTUnwrap(SceneScriptOutputReader.read(bytes)), true)
        }
        return try (JSONSerialization.jsonObject(with: Data(bytes)), false)
    }

    private func assertSame(
        _ a: Any,
        _ b: Any,
        _ path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (a, b) {
        case (is NSNull, is NSNull):
            return
        case let (x as NSNumber, y as NSNumber):
            let boolA = CFGetTypeID(x) == CFBooleanGetTypeID(),
                boolB = CFGetTypeID(y) == CFBooleanGetTypeID()
            XCTAssertEqual(boolA, boolB, path, file: file, line: line)
            XCTAssertEqual(
                String(cString: x.objCType),
                String(cString: y.objCType),
                path,
                file: file,
                line: line
            )
            XCTAssertEqual(
                x.doubleValue.bitPattern,
                y.doubleValue.bitPattern,
                path,
                file: file,
                line: line
            )
            XCTAssertEqual(x.intValue, y.intValue, path, file: file, line: line)
            XCTAssertEqual(x as? Bool, y as? Bool, path, file: file, line: line)
        case let (x as String, y as String):
            XCTAssertEqual(x, y, path, file: file, line: line)
        case let (x as [Any], y as [Any]):
            XCTAssertEqual(x.count, y.count, path, file: file, line: line)
            for (i, pair) in zip(x, y).enumerated() {
                assertSame(
                    pair.0,
                    pair.1,
                    "\(path)[\(i)]",
                    file: file,
                    line: line
                )
            }
        case let (x as [String: Any], y as [String: Any]):
            XCTAssertEqual(Set(x.keys), Set(y.keys), path, file: file, line: line)
            for (key, value) in x where y[key] != nil {
                assertSame(
                    value,
                    y[key]!,
                    "\(path).\(key)",
                    file: file,
                    line: line
                )
            }
        default:
            XCTFail("\(path): \(type(of: a)) vs \(type(of: b))", file: file, line: line)
        }
    }

    private let plainValues = [
        "0", "-0", "1", "-5", "1.5", "0.1", "0.30000000000000004", "123456789.123456789", "1e21",
        "1e-7",
        "2**31", "2**53 - 1", "-(2**53 - 1)", "NaN", "Infinity", "-Infinity", "true", "false",
        "null",
        "''", "'日本語 ✓ 😀'", "'a\"b\\\\c\\n\\u0001\\u001f'",
        "[undefined, () => 1, Symbol('s'), 1]",
        "{a: 1, b: undefined, c: () => 1, 2: 'x', 1: 'y', [Symbol('k')]: 3, 'ключ': [[], {}]}",
        "Object.create(null)",
        "Object.defineProperty({v: 1}, 'hidden', {value: 2, enumerable: false})",
        "Array.from({length: 600}, (_, i) => ({id: 'x' + i, values: {offsetX: i / 7, order: i}}))"
    ]

    private let specialValues = [
        "{toJSON() { return 5 }}", "{get x() { return 3 }}", "new Proxy({a: 1}, {})",
        "new Boolean(true)",
        "new Number(3)", "new String('s')",
        "new Float32Array([1, 2])", "[1, , 3]", "Object.create({toJSON() { return 'p' }})", "2**60",
        "-(2**63)"
    ]

    func testDirectResultMatchesJSON() throws {
        for value in plainValues + specialValues {
            let direct = try evaluate("function update(c){ return [\(value)]; }")
            let json = try evaluate("""
            function update(c){ const r = [\(
                value
            )]; Object.defineProperty(r, 'toJSON', {value() { return this.slice(); }}); return r; }
            """)
            XCTAssertFalse(json.isDirect, value)
            XCTAssertEqual(direct.isDirect, plainValues.contains(value), value)
            assertSame(direct.0, json.0, value)
        }
    }

    func testResultsJSONRejectsAreStillRejected() {
        for value in ["10n", "'\\ud800'", "(() => { const a = []; a.push(a); return a; })()"] {
            XCTAssertThrowsError(try evaluate("function update(c){ return [\(value)]; }"), value)
        }
        XCTAssertThrowsError(
            try evaluate(
                "function update(c){ return Array.from({length: 40000}, () => 'abcdefgh'); }"
            )
        )
    }

    private func assertDecodesLikeJSON(
        _ type: (some Decodable).Type,
        _ value: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let direct = Result { try SceneScriptValueDecoder.decode(type, from: value) }
        let json = Result { try JSONDecoder().decode(
            type,
            from: JSONSerialization.data(withJSONObject: value)
        ) }
        switch (direct, json) {
        case let (.success(a as [String: Double]), .success(b as [String: Double])):
            XCTAssertEqual(
                a.mapValues(\.bitPattern),
                b.mapValues(\.bitPattern),
                "\(value)",
                file: file,
                line: line
            )
        case let (.success(a), .success(b)):
            XCTAssertEqual(
                String(describing: a),
                String(describing: b),
                "\(value)",
                file: file,
                line: line
            )
        case (.failure, .failure):
            break
        default:
            XCTFail("\(type) \(value): direct \(direct), JSON \(json)", file: file, line: line)
        }
    }

    func testValuesDecodeLikeJSONDecoder() {
        let numbers: [Any] = [
            NSNumber(value: Int64(3)),
            NSNumber(value: 3.0),
            NSNumber(value: 2.5),
            NSNumber(value: 0.1),
            NSNumber(value: 1e20),
            NSNumber(value: -0.0),
            NSNumber(value: true),
            NSNumber(value: false),
            "1",
            NSNull(),
            [String: Any](),
            NSDecimalNumber(string: "123456789.123456789")
        ]
        for value in numbers {
            assertDecodesLikeJSON(
                SceneScriptEffectValues.self,
                ["strength": value, "cycles": value, "isEnabled": value, "kind": value]
            )
            assertDecodesLikeJSON(SceneScriptEffectValues.self, ["cycles": value])
            assertDecodesLikeJSON(SceneScriptEffectValues.self, ["isEnabled": value])
            assertDecodesLikeJSON(
                SceneScriptEffectValues.self,
                ["direction": value, "values": ["a": value]]
            )
            assertDecodesLikeJSON(
                SceneScriptParticleValues.self,
                ["count": value, "color": ["red": value, "green": 0, "blue": 1, "alpha": 1]]
            )
            assertDecodesLikeJSON(SceneScriptTextValues.self, ["string": value])
            assertDecodesLikeJSON(
                SceneScriptTextValues.self,
                ["color": [
                    "red": value,
                    "green": NSNumber(value: 0.5),
                    "blue": NSNumber(value: Int64(1))
                ]]
            )
            assertDecodesLikeJSON(
                SceneScriptAppearanceValues.self,
                [
                    "isVisible": value,
                    "depthAutoCycles": value,
                    "tint": ["red": 1, "green": 1, "blue": 1, "alpha": value]
                ]
            )
            assertDecodesLikeJSON([String: Double].self, ["x": value, "y": NSNumber(value: 1.25)])
        }
        for kind in ["blur", "notAKind", ""] {
            assertDecodesLikeJSON(SceneScriptEffectValues.self, ["kind": kind, "fixedEdge": "top"])
        }
        assertDecodesLikeJSON(SceneScriptTextValues.self, ["color": ["red": 1, "green": 1]])
        assertDecodesLikeJSON(
            SceneScriptParticleValues.self,
            [
                "preset": "snow",
                "cursorMode": "attract",
                "seed": NSNumber(value: Int64(2_147_483_647)),
                "unknown": 1
            ]
        )
        assertDecodesLikeJSON(
            SceneScriptAppearanceValues.self,
            [
                "blendMode": "multiply",
                "cursorMask": ["mode": "reveal", "radius": 0.2],
                "clearCursorMask": false
            ]
        )
    }

    func testReaderBoundsCheckingDoesNotCrashOnCorruptedInput() {
        let emptyBytes: [UInt8] = []
        emptyBytes.withUnsafeBytes { buffer in
            XCTAssertNil(SceneScriptOutputReader.read(buffer))
        }
        let magicOnly: [UInt8] = [SceneScriptOutputReader.magic]
        magicOnly.withUnsafeBytes { buffer in
            XCTAssertNil(SceneScriptOutputReader.read(buffer))
        }
        // Tag 6 (array) with corrupted count 0xFFFF_FFFF and no data following
        let corruptedArray: [UInt8] = [SceneScriptOutputReader.magic, 6, 0xFF, 0xFF, 0xFF, 0xFF]
        corruptedArray.withUnsafeBytes { buffer in
            XCTAssertNil(SceneScriptOutputReader.read(buffer))
        }
        // Tag 5 (string) with truncated length
        let truncatedString: [UInt8] = [SceneScriptOutputReader.magic, 5, 0x10, 0x00, 0x00, 0x00, 0x61]
        truncatedString.withUnsafeBytes { buffer in
            XCTAssertNil(SceneScriptOutputReader.read(buffer))
        }
        // Unknown tag 99
        let unknownTag: [UInt8] = [SceneScriptOutputReader.magic, 99, 0x01, 0x02]
        unknownTag.withUnsafeBytes { buffer in
            XCTAssertNil(SceneScriptOutputReader.read(buffer))
        }
    }

    func testMipLevelCountBoundaryValues() {
        XCTAssertEqual(SceneRenderer.mipLevelCount(width: 0, height: 0), 1)
        XCTAssertEqual(SceneRenderer.mipLevelCount(width: -1, height: 100), 1)
        XCTAssertEqual(SceneRenderer.mipLevelCount(width: 100, height: -1), 1)
        XCTAssertEqual(SceneRenderer.mipLevelCount(width: 16, height: 16), 1)
        XCTAssertGreaterThan(SceneRenderer.mipLevelCount(width: 1920, height: 1080), 1)
    }
}

@testable import LiveWallpaper
import XCTest

final class LenientDecodingTests: XCTestCase {
    private func pin(_ json: String) throws -> ScenePin {
        try JSONDecoder().decode(ScenePin.self, from: Data(json.utf8))
    }

    func testMissingAndNullFieldsTakeTheirDefaults() throws {
        let decoded = try pin(#"{"x": 0.25, "y": null}"#)
        XCTAssertEqual(decoded.x, 0.25)
        XCTAssertEqual(decoded.y, 0.5)
        XCTAssertTrue(decoded.isAnchor)
    }

    func testAWrongTypedFieldFallsBackWithoutLosingTheOthers() throws {
        let decoded = try pin(#"{"x": "left", "y": 0.75, "isAnchor": false}"#)
        XCTAssertEqual(decoded.x, 0.5)
        XCTAssertEqual(decoded.y, 0.75)
        XCTAssertFalse(decoded.isAnchor)
    }

    func testUnreadableArrayElementsAreDroppedOneByOne() throws {
        let json = #"[{"x": 0.1}, 7, {"x": 0.9}]"#
        let decoded = try JSONDecoder().decode(
            [FailableDecodable<ScenePin>].self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.compactMap(\.value).map(\.x), [0.1, 0.9])
    }
}

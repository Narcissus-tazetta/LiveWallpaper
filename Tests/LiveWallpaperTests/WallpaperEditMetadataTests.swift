import XCTest

@testable import LiveWallpaper

final class WallpaperEditMetadataTests: XCTestCase {
    func testDefaultIsNoOp() {
        let edit = WallpaperEditMetadata()
        XCTAssertTrue(edit.isNoOp)
    }

    func testNonZeroTrimStartIsNotNoOp() {
        let edit = WallpaperEditMetadata(trimStart: 1, trimEnd: nil, loopStart: nil)
        XCTAssertFalse(edit.isNoOp)
    }

    func testValidRangeIsValid() {
        let edit = WallpaperEditMetadata(trimStart: 2, trimEnd: 10, loopStart: 4)
        XCTAssertTrue(edit.isValid(assetDuration: 20))
    }

    func testNegativeTrimStartIsInvalid() {
        let edit = WallpaperEditMetadata(trimStart: -1, trimEnd: 10, loopStart: nil)
        XCTAssertFalse(edit.isValid(assetDuration: 20))
    }

    func testTrimEndNotAfterTrimStartIsInvalid() {
        let equal = WallpaperEditMetadata(trimStart: 5, trimEnd: 5, loopStart: nil)
        XCTAssertFalse(equal.isValid(assetDuration: 20))

        let before = WallpaperEditMetadata(trimStart: 5, trimEnd: 3, loopStart: nil)
        XCTAssertFalse(before.isValid(assetDuration: 20))
    }

    func testLoopStartBeforeTrimStartIsInvalid() {
        let edit = WallpaperEditMetadata(trimStart: 5, trimEnd: 10, loopStart: 4)
        XCTAssertFalse(edit.isValid(assetDuration: 20))
    }

    func testLoopStartAtOrAfterTrimEndIsInvalid() {
        let atEnd = WallpaperEditMetadata(trimStart: 2, trimEnd: 10, loopStart: 10)
        XCTAssertFalse(atEnd.isValid(assetDuration: 20))

        let afterEnd = WallpaperEditMetadata(trimStart: 2, trimEnd: 10, loopStart: 12)
        XCTAssertFalse(afterEnd.isValid(assetDuration: 20))
    }

    func testTrimStartBeyondDurationIsInvalid() {
        let edit = WallpaperEditMetadata(trimStart: 25, trimEnd: nil, loopStart: nil)
        XCTAssertFalse(edit.isValid(assetDuration: 20))
    }

    func testTrimEndBeyondDurationIsInvalid() {
        let edit = WallpaperEditMetadata(trimStart: 0, trimEnd: 25, loopStart: nil)
        XCTAssertFalse(edit.isValid(assetDuration: 20))
    }

    func testNilTrimEndSkipsDurationCheck() {
        let edit = WallpaperEditMetadata(trimStart: 5, trimEnd: nil, loopStart: nil)
        XCTAssertTrue(edit.isValid(assetDuration: 20))
    }

    func testNilDurationSkipsDurationChecks() {
        let edit = WallpaperEditMetadata(trimStart: 5, trimEnd: 1000, loopStart: nil)
        XCTAssertTrue(edit.isValid(assetDuration: nil))
    }

    func testEffectiveLoopStartFallsBackToTrimStart() {
        let withoutCustomLoop = WallpaperEditMetadata(trimStart: 5, trimEnd: 20, loopStart: nil)
        XCTAssertEqual(withoutCustomLoop.effectiveLoopStart, 5)

        let withCustomLoop = WallpaperEditMetadata(trimStart: 5, trimEnd: 20, loopStart: 12)
        XCTAssertEqual(withCustomLoop.effectiveLoopStart, 12)
    }

    func testCodableRoundTrip() throws {
        let original: [String: WallpaperEditMetadata] = [
            "/a.mp4": WallpaperEditMetadata(trimStart: 1.5, trimEnd: 9.25, loopStart: 3),
            "/b.mp4": WallpaperEditMetadata(trimStart: 0, trimEnd: nil, loopStart: nil),
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([String: WallpaperEditMetadata].self, from: data)
        XCTAssertEqual(decoded, original)
    }
}

import XCTest

@testable import LiveWallpaper

final class WallpaperEditMetadataTests: XCTestCase {
    func testDefaultIsNoOp() {
        let edit = WallpaperEditMetadata()
        XCTAssertTrue(edit.isNoOp)
    }

    func testNonZeroTrimStartIsNotNoOp() {
        let edit = WallpaperEditMetadata(trimStart: 1, trimEnd: nil)
        XCTAssertFalse(edit.isNoOp)
    }

    func testValidRangeIsValid() {
        let edit = WallpaperEditMetadata(trimStart: 2, trimEnd: 10)
        XCTAssertTrue(edit.isValid(assetDuration: 20))
    }

    func testNegativeTrimStartIsInvalid() {
        let edit = WallpaperEditMetadata(trimStart: -1, trimEnd: 10)
        XCTAssertFalse(edit.isValid(assetDuration: 20))
    }

    func testTrimEndNotAfterTrimStartIsInvalid() {
        let equal = WallpaperEditMetadata(trimStart: 5, trimEnd: 5)
        XCTAssertFalse(equal.isValid(assetDuration: 20))

        let before = WallpaperEditMetadata(trimStart: 5, trimEnd: 3)
        XCTAssertFalse(before.isValid(assetDuration: 20))
    }

    func testTrimStartBeyondDurationIsInvalid() {
        let edit = WallpaperEditMetadata(trimStart: 25, trimEnd: nil)
        XCTAssertFalse(edit.isValid(assetDuration: 20))
    }

    func testTrimEndBeyondDurationIsInvalid() {
        let edit = WallpaperEditMetadata(trimStart: 0, trimEnd: 25)
        XCTAssertFalse(edit.isValid(assetDuration: 20))
    }

    func testNilTrimEndSkipsDurationCheck() {
        let edit = WallpaperEditMetadata(trimStart: 5, trimEnd: nil)
        XCTAssertTrue(edit.isValid(assetDuration: 20))
    }

    func testNilDurationSkipsDurationChecks() {
        let edit = WallpaperEditMetadata(trimStart: 5, trimEnd: 1000)
        XCTAssertTrue(edit.isValid(assetDuration: nil))
    }

    // MARK: - ループ開始位置

    func testLoopStartInsideTheCutRangeIsValid() {
        let edit = WallpaperEditMetadata(trimStart: 2, trimEnd: 10, loopStart: 6)
        XCTAssertTrue(edit.isValid(assetDuration: 20))
        XCTAssertEqual(edit.effectiveLoopStart, 6)
    }

    func testLoopStartBeforeTrimStartIsInvalid() {
        let edit = WallpaperEditMetadata(trimStart: 5, trimEnd: 10, loopStart: 1)
        XCTAssertFalse(edit.isValid(assetDuration: 20))
    }

    func testLoopStartAtOrAfterTrimEndIsInvalid() {
        XCTAssertFalse(
            WallpaperEditMetadata(trimStart: 0, trimEnd: 10, loopStart: 10)
                .isValid(assetDuration: 20)
        )
        XCTAssertFalse(
            WallpaperEditMetadata(trimStart: 0, trimEnd: 10, loopStart: 11)
                .isValid(assetDuration: 20)
        )
    }

    func testEffectiveLoopStartFallsBackToTrimStart() {
        let edit = WallpaperEditMetadata(trimStart: 3, trimEnd: 10)
        XCTAssertEqual(edit.effectiveLoopStart, 3)
    }

    func testLoopStartAloneIsNotNoOp() {
        XCTAssertFalse(WallpaperEditMetadata(trimStart: 0, trimEnd: nil, loopStart: 4).isNoOp)
    }

    func testCodableRoundTrip() throws {
        let original: [String: WallpaperEditMetadata] = [
            "/a.mp4": WallpaperEditMetadata(trimStart: 1.5, trimEnd: 9.25, loopStart: 4),
            "/b.mp4": WallpaperEditMetadata(trimStart: 0, trimEnd: nil),
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([String: WallpaperEditMetadata].self, from: data)
        XCTAssertEqual(decoded, original)
    }
}

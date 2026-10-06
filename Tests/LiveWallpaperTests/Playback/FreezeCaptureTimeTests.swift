import AVFoundation
import XCTest
@testable import LiveWallpaper

@MainActor
final class FreezeCaptureTimeTests: XCTestCase {
    func testInvalidTimeBeforeLooperInsertsItemFallsBackToTrimStart() {
        let time = WallpaperModel.freezeCaptureTime(.invalid, trimStart: 2)
        XCTAssertEqual(time.seconds, 2, accuracy: 0.001)
    }

    func testInvalidTimeWithoutTrimFallsBackToZero() {
        let time = WallpaperModel.freezeCaptureTime(.invalid, trimStart: 0)
        XCTAssertTrue(time.isNumeric)
        XCTAssertEqual(time.seconds, 0, accuracy: 0.001)
    }

    func testTimeInsideTrimmedAwayHeadIsMovedToTrimStart() {
        let time = WallpaperModel.freezeCaptureTime(CMTime(seconds: 0.5, preferredTimescale: 600), trimStart: 2)
        XCTAssertEqual(time.seconds, 2, accuracy: 0.001)
    }

    func testPlaybackPositionIsKeptWhenValid() {
        let time = WallpaperModel.freezeCaptureTime(CMTime(seconds: 5, preferredTimescale: 600), trimStart: 2)
        XCTAssertEqual(time.seconds, 5, accuracy: 0.001)
    }
}

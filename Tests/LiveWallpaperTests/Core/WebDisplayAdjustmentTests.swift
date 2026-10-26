import XCTest
@testable import LiveWallpaper

final class WebDisplayAdjustmentTests: XCTestCase {
    private let keys = [
        "flipHorizontally": "flip", "colorEnabled": "on",
        "brightness": "b", "contrast": "c", "saturation": "s", "hue": "h",
    ]

    private func adjustment(on: Bool = true, b: Double = 50, c: Double = 50, s: Double = 50, h: Double = 50)
        -> WebDisplayAdjustment
    {
        WebDisplayAdjustment(keys: keys, values: [
            "on": .bool(on), "b": .number(b), "c": .number(c), "s": .number(s), "h": .number(h),
        ])
    }

    func testColourPassRunsOnlyWhenEnabledAndOffNeutral() {
        XCTAssertNil(adjustment().color)
        XCTAssertNil(adjustment(on: false, b: 80).color)
        XCTAssertNil(WebDisplayAdjustment(keys: nil, values: ["on": .bool(true), "b": .number(80)]).color)
        XCTAssertNotNil(adjustment(h: 51).color)
    }

    func testSlidersMapAsTheOriginalPassesThem() {
        let color = adjustment(b: 100, c: 0, s: 100, h: 100).color!
        XCTAssertEqual(color.value, 4, accuracy: 1e-6)
        XCTAssertEqual(color.contrast, 0, accuracy: 1e-6)
        XCTAssertEqual(color.saturation, Float(2).squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(color.hue, 0.5, accuracy: 1e-6)
    }

    func testNoSaturationLeavesTheBrightestChannelAsGrey() {
        let grey = adjustment(s: 0).color!.apply(red: 0.75, green: 0.125, blue: 0.25)
        XCTAssertEqual(grey.x, 0.75, accuracy: 1e-5)
        XCTAssertEqual(grey.y, 0.75, accuracy: 1e-5)
        XCTAssertEqual(grey.z, 0.75, accuracy: 1e-5)
    }

    func testHalfTurnOfHueMakesRedCyan() {
        let cyan = adjustment(h: 100).color!.apply(red: 1, green: 0, blue: 0)
        XCTAssertEqual(cyan.x, 0, accuracy: 1e-5)
        XCTAssertEqual(cyan.y, 1, accuracy: 1e-5)
        XCTAssertEqual(cyan.z, 1, accuracy: 1e-5)
    }

    func testFlipFollowsItsProperty() {
        XCTAssertTrue(WebDisplayAdjustment(keys: keys, values: ["flip": .bool(true)]).flipsHorizontally)
        XCTAssertFalse(WebDisplayAdjustment(keys: keys, values: [:]).flipsHorizontally)
    }
}

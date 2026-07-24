@testable import LiveWallpaper
import XCTest

/// タイムラインのズーム/スクロール。端でのクランプとアンカー維持は
/// 目視では検証しづらく、崩れると「掴んだ場所と違うところが表示される」
/// という分かりにくい壊れ方をするため、算術だけを直接確かめる。
final class TrimTimelineWindowTests: XCTestCase {
    func testFullWindowCoversTheWholeAsset() {
        let window = TrimTimelineWindow.full(assetDuration: 120)
        XCTAssertEqual(window.start, 0)
        XCTAssertEqual(window.duration, 120)
        XCTAssertTrue(window.isFullyZoomedOut(assetDuration: 120))
    }

    func testZoomKeepsTheAnchorAtTheSameRelativePosition() {
        let window = TrimTimelineWindow(start: 0, duration: 100)
        // アンカー(25秒)は窓の1/4の位置。拡大後も1/4のままであるべき。
        let zoomed = window.zoomed(by: 2, anchor: 25, assetDuration: 100)

        XCTAssertEqual(zoomed.duration, 50, accuracy: 0.0001)
        XCTAssertEqual(zoomed.ratio(forTime: 25), 0.25, accuracy: 0.0001)
    }

    func testZoomIsClampedToTheAssetAtTheHead() {
        let window = TrimTimelineWindow(start: 0, duration: 100)
        let zoomed = window.zoomed(by: 0.5, anchor: 0, assetDuration: 100)

        XCTAssertEqual(zoomed.start, 0, "先頭より手前は映せない")
        XCTAssertEqual(zoomed.duration, 100, "アセットより広くもならない")
    }

    func testZoomStopsAtTheMinimumDuration() {
        let window = TrimTimelineWindow(start: 10, duration: 1)
        let zoomed = window.zoomed(by: 1000, anchor: 10.5, assetDuration: 100)

        XCTAssertEqual(zoomed.duration, TrimTimelineWindow.minimumDuration, accuracy: 0.0001)
        XCTAssertTrue(zoomed.isFullyZoomedIn())
    }

    func testPanIsClampedAtBothEnds() {
        let window = TrimTimelineWindow(start: 50, duration: 20)

        XCTAssertEqual(window.panned(bySeconds: -999, assetDuration: 100).start, 0)
        XCTAssertEqual(
            window.panned(bySeconds: 999, assetDuration: 100).start, 80,
            "末尾を越えて空白を映さない"
        )
    }

    func testFittingWrapsTheRangeWithPadding() {
        let window = TrimTimelineWindow.fitting(from: 40, to: 60, assetDuration: 100)

        XCTAssertLessThan(window.start, 40, "前後に少し余白を残す")
        XCTAssertGreaterThan(window.end, 60)
        XCTAssertTrue(window.contains(40))
        XCTAssertTrue(window.contains(60))
    }

    func testFittingIsClampedWhenTheRangeTouchesTheAssetEdges() {
        let window = TrimTimelineWindow.fitting(from: 0, to: 100, assetDuration: 100)

        XCTAssertEqual(window.start, 0)
        XCTAssertEqual(window.duration, 100)
    }

    func testFollowingDoesNothingWhilePlayheadIsVisible() {
        let window = TrimTimelineWindow(start: 10, duration: 20)
        XCTAssertEqual(window.following(playhead: 15, assetDuration: 100), window)
    }

    func testFollowingCatchesUpWhenThePlayheadLeavesTheWindow() {
        let window = TrimTimelineWindow(start: 10, duration: 20)
        let followed = window.following(playhead: 55, assetDuration: 100)

        XCTAssertTrue(followed.contains(55))
        XCTAssertEqual(followed.duration, 20, accuracy: 0.0001, "追従でズーム率は変えない")
    }

    func testFollowingIsANoOpWhenFullyZoomedOut() {
        let window = TrimTimelineWindow.full(assetDuration: 100)
        XCTAssertEqual(window.following(playhead: 500, assetDuration: 100), window)
    }

    func testRatioAndTimeAreInverses() {
        let window = TrimTimelineWindow(start: 30, duration: 40)
        XCTAssertEqual(window.time(atRatio: window.ratio(forTime: 47)), 47, accuracy: 0.0001)
    }

    func testNonFiniteInputsDoNotCorruptTheWindow() {
        let window = TrimTimelineWindow(start: .nan, duration: .nan)
        XCTAssertEqual(window.start, 0)
        XCTAssertEqual(window.duration, TrimTimelineWindow.minimumDuration)
    }
}

import XCTest
@testable import LiveWallpaper

final class SceneCameraPathTests: XCTestCase {
    private func path(duration: Double) -> SceneCameraPath {
        let up = [0.0, 1, 0]
        return SceneCameraPath(duration: duration, transforms: [
            .init(timestamp: 0, eye: [0, 0, 400], center: [0, 0, 0], up: up),
            .init(timestamp: 4, eye: [100, 0, 400], center: [100, 0, 0], up: up),
        ])
    }

    func testEasesBetweenTwoKeyPointsAndHoldsTheLast() {
        let path = path(duration: 4)
        XCTAssertEqual(path.transform(at: 0).eye.x, 0, accuracy: 1e-4)
        XCTAssertEqual(path.transform(at: 2).eye.x, 50, accuracy: 1e-3)
        // Half a line and half an ease: a quarter of the way in, 0.5 * 0.25 + 0.5 * smoothstep(0.25).
        XCTAssertEqual(path.transform(at: 1).eye.x, 100 * (0.5 * 0.25 + 0.5 * 0.15625), accuracy: 1e-3)
        XCTAssertEqual(path.transform(at: 3.999).eye.x, 100, accuracy: 0.05)
    }

    func testRepeatsAfterTheLongerOfTheLastTimeAndWhatIsLeftOfTheDuration() {
        XCTAssertEqual(path(duration: 8).period, 4)
        let long = SceneCameraPath(duration: 8, transforms: [
            .init(timestamp: 0, eye: [0, 0, 0], center: [0, 0, -1], up: [0, 1, 0]),
            .init(timestamp: 2, eye: [60, 0, 0], center: [60, 0, -1], up: [0, 1, 0]),
        ])
        XCTAssertEqual(long.period, 6)
        XCTAssertEqual(long.transform(at: 5).eye.x, 60, accuracy: 1e-4)
        XCTAssertEqual(long.transform(at: 6).eye.x, 0, accuracy: 1e-4)
    }
}

import XCTest
@testable import LiveWallpaper

final class SceneLoopTimingTests: XCTestCase {
    /// A camera path or a video of 23 s plays 2.6 times a minute: a baked loop plays it at
    /// its own speed through the first half, never backwards, and ends on a whole play.
    func testABakedLoopPlaysARepeatingMotionWholeTimesWithoutWindingBack() {
        func played(_ time: Double) -> Double {
            SceneLoopTiming.phase(rate: 1, cycle: 23, keepsDirection: true, time: time, loop: 60)
        }
        XCTAssertEqual(played(25), 2, accuracy: 1e-9)
        XCTAssertEqual(SceneLoopTiming.phase(rate: 1, cycle: 23, keepsDirection: true, time: 25, loop: nil), 2, accuracy: 1e-9)
        let end = played(59.999)
        XCTAssertTrue(end < 0.01 || end > 22.99, "the loop ends where a play starts, not at \(end)")
        var previous = 0.0, unwrapped = 0.0
        for step in 1 ... 6000 {
            let now = played(Double(step) / 100)
            var moved = now - previous
            if moved < -11.5 { moved += 23 }
            XCTAssertGreaterThan(moved, 0, "moves on at \(Double(step) / 100) s")
            unwrapped += moved
            previous = now
        }
        XCTAssertEqual(unwrapped, 69, accuracy: 0.01, "three whole plays")
    }
}

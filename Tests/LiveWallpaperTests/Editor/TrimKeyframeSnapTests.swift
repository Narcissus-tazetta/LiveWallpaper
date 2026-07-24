@testable import LiveWallpaper
import XCTest

/// キーフレーム吸着。二分探索で前後2つだけを候補にするため、端や
/// 「完全一致」で取りこぼさないことを確認する。
final class TrimKeyframeSnapTests: XCTestCase {
    private let keyframes: [Double] = [0, 2, 4, 6, 8, 10]

    func testSnapsToTheNearestKeyframeWithinTolerance() {
        XCTAssertEqual(
            TrimKeyframeIndex.snapped(4.1, to: keyframes, tolerance: 0.25),
            4,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TrimKeyframeIndex.snapped(3.9, to: keyframes, tolerance: 0.25),
            4,
            accuracy: 0.0001
        )
    }

    func testLeavesTheTimeAloneOutsideTolerance() {
        XCTAssertEqual(
            TrimKeyframeIndex.snapped(5, to: keyframes, tolerance: 0.25),
            5,
            accuracy: 0.0001,
            "遠いキーフレームまで引っ張ると、掴んだ場所と違うところに置かれる"
        )
    }

    func testSnapsAtTheHeadAndTail() {
        XCTAssertEqual(
            TrimKeyframeIndex.snapped(-1, to: keyframes, tolerance: 2),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TrimKeyframeIndex.snapped(11, to: keyframes, tolerance: 2),
            10,
            accuracy: 0.0001
        )
    }

    func testExactMatchIsStable() {
        XCTAssertEqual(
            TrimKeyframeIndex.snapped(6, to: keyframes, tolerance: 0.5),
            6,
            accuracy: 0.0001
        )
    }

    func testEmptyIndexIsANoOp() {
        XCTAssertEqual(TrimKeyframeIndex.snapped(3.3, to: [], tolerance: 5), 3.3, accuracy: 0.0001)
    }

    func testNonFiniteInputIsReturnedUnchanged() {
        XCTAssertTrue(TrimKeyframeIndex.snapped(.nan, to: keyframes, tolerance: 1).isNaN)
    }
}

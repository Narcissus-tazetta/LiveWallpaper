@testable import LiveWallpaper
import XCTest

/// ハンドル同士が重なっていても、ドラッグ開始位置に最も近いハンドルを選べることを
/// 確認する。以前は各ハンドルが個別に `.gesture` を持ち、重なった領域は常に
/// 最後に描画されたハンドル(end)へ吸われて掴めなかった。
final class TrimHandleHitTesterTests: XCTestCase {
    func testPicksNearestHandleWhenFarApart() {
        let target = TrimHandleHitTester.resolve(
            at: 10,
            trimStartX: 10,
            trimEndX: 200,
            hitRadius: 16
        )
        XCTAssertEqual(target, .start)
    }

    func testPicksStartWhenHandlesOverlapAndTouchIsCloserToStart() {
        // start と end がほぼ同じ位置(重なっている)状態で、start 側に近いところを
        // タップした場合は必ず start が選ばれる。
        let target = TrimHandleHitTester.resolve(
            at: 98,
            trimStartX: 100,
            trimEndX: 102,
            hitRadius: 16
        )
        XCTAssertEqual(target, .start)
    }

    func testPicksEndWhenHandlesOverlapAndTouchIsCloserToEnd() {
        let target = TrimHandleHitTester.resolve(
            at: 104,
            trimStartX: 100,
            trimEndX: 102,
            hitRadius: 16
        )
        XCTAssertEqual(target, .end)
    }

    func testFallsBackToTrackOutsideHitRadius() {
        let target = TrimHandleHitTester.resolve(
            at: 150,
            trimStartX: 10,
            trimEndX: 20,
            hitRadius: 16
        )
        XCTAssertEqual(target, .track)
    }

    func testPicksTheLoopStartHandleWhenItIsNearest() {
        let target = TrimHandleHitTester.resolve(
            at: 150,
            trimStartX: 10,
            trimEndX: 300,
            loopStartX: 145,
            hitRadius: 16
        )
        XCTAssertEqual(target, .loopStart)
    }

    func testLoopStartHandleIsNotACandidateWhenAbsent() {
        // 「途中からループする」がOFFのとき、その座標付近を掴んでもトラック扱い。
        let target = TrimHandleHitTester.resolve(
            at: 150,
            trimStartX: 10,
            trimEndX: 300,
            loopStartX: nil,
            hitRadius: 16
        )
        XCTAssertEqual(target, .track)
    }

    func testOverlappingHandlesPickClosestByExactDistance() {
        // start/end が同じピクセル付近に重なっていても、タップ位置に一番近い
        // ものが一意に決まる。
        let target = TrimHandleHitTester.resolve(
            at: 100.4,
            trimStartX: 99,
            trimEndX: 101,
            hitRadius: 16
        )
        XCTAssertEqual(target, .end)
    }
}

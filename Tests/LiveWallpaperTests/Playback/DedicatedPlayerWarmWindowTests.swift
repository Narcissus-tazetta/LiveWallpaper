import XCTest
@testable import LiveWallpaper

final class DedicatedPlayerWarmWindowTests: XCTestCase {
    func testNeighborsMiddleOfOrder() {
        let order = ["a", "b", "c", "d", "e"]
        let result = DedicatedPlayerWarmWindow.neighbors(current: "c", order: order)
        XCTAssertEqual(result.left, "b")
        XCTAssertEqual(result.right, "d")
    }

    func testNeighborsAtStartHasNoLeft() {
        let order = ["a", "b", "c"]
        let result = DedicatedPlayerWarmWindow.neighbors(current: "a", order: order)
        XCTAssertNil(result.left)
        XCTAssertEqual(result.right, "b")
    }

    func testNeighborsAtEndHasNoRight() {
        let order = ["a", "b", "c"]
        let result = DedicatedPlayerWarmWindow.neighbors(current: "c", order: order)
        XCTAssertEqual(result.left, "b")
        XCTAssertNil(result.right)
    }

    func testNeighborsSingleSpaceHasNoNeighbors() {
        let result = DedicatedPlayerWarmWindow.neighbors(current: "a", order: ["a"])
        XCTAssertNil(result.left)
        XCTAssertNil(result.right)
    }

    func testNeighborsDoesNotWrapAround() {
        let order = ["a", "b", "c"]
        let result = DedicatedPlayerWarmWindow.neighbors(current: "a", order: order)
        XCTAssertNotEqual(result.left, "c")
    }

    func testNeighborsCurrentNotInOrderReturnsNil() {
        let result = DedicatedPlayerWarmWindow.neighbors(current: "z", order: ["a", "b", "c"])
        XCTAssertNil(result.left)
        XCTAssertNil(result.right)
    }

    func testDiffProducesCreateAndEvictSets() {
        let plan = DedicatedPlayerWarmWindow.diff(desired: ["b", "c"], existing: ["a", "b"])
        XCTAssertEqual(plan.toCreate, ["c"])
        XCTAssertEqual(plan.toEvict, ["a"])
    }

    func testDiffIsNoOpWhenSetsMatch() {
        let plan = DedicatedPlayerWarmWindow.diff(desired: ["a", "b"], existing: ["a", "b"])
        XCTAssertTrue(plan.toCreate.isEmpty)
        XCTAssertTrue(plan.toEvict.isEmpty)
    }

    func testDiffWithEmptyDesiredEvictsAllExisting() {
        let plan = DedicatedPlayerWarmWindow.diff(desired: [], existing: ["a", "b"])
        XCTAssertTrue(plan.toCreate.isEmpty)
        XCTAssertEqual(plan.toEvict, ["a", "b"])
    }
}

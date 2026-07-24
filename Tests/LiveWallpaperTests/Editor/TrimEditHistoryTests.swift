@testable import LiveWallpaper
import XCTest

/// Undo/Redo。特に「ドラッグ1回 = ⌘Z 1回」の合流(coalescing)を確認する。
/// これが効かないと、1ピクセルずつ戻る使い物にならない履歴になる。
final class TrimEditHistoryTests: XCTestCase {
    private func snapshot(_ start: Double) -> TrimEditSnapshot {
        TrimEditSnapshot(trimStart: start, trimEnd: nil, loopStart: nil)
    }

    func testUndoRestoresThePreviousState() {
        var history = TrimEditHistory()
        history.record(snapshot(0), coalescingKey: nil)

        XCTAssertTrue(history.canUndo)
        XCTAssertEqual(history.undo(current: snapshot(10)), snapshot(0))
        XCTAssertFalse(history.canUndo)
    }

    func testConsecutiveSameKeyEditsCollapseIntoOneStep() {
        var history = TrimEditHistory()
        // ドラッグ中の連続更新: 操作前の状態は最初の1つだけが残る。
        history.record(snapshot(0), coalescingKey: "trimStart")
        history.record(snapshot(1), coalescingKey: "trimStart")
        history.record(snapshot(2), coalescingKey: "trimStart")

        XCTAssertEqual(history.undo(current: snapshot(3)), snapshot(0))
        XCTAssertFalse(history.canUndo, "1回のドラッグは1手")
    }

    func testDifferentKeysAreSeparateSteps() {
        var history = TrimEditHistory()
        history.record(snapshot(0), coalescingKey: "trimStart")
        history.record(snapshot(1), coalescingKey: "trimEnd")

        XCTAssertEqual(history.undo(current: snapshot(2)), snapshot(1))
        XCTAssertEqual(history.undo(current: snapshot(1)), snapshot(0))
    }

    func testBreakCoalescingStartsANewStepForTheSameKey() {
        var history = TrimEditHistory()
        history.record(snapshot(0), coalescingKey: "trimStart")
        history.breakCoalescing()
        history.record(snapshot(1), coalescingKey: "trimStart")

        XCTAssertEqual(history.undo(current: snapshot(2)), snapshot(1))
        XCTAssertEqual(history.undo(current: snapshot(1)), snapshot(0))
    }

    func testRedoReplaysTheUndoneStep() {
        var history = TrimEditHistory()
        history.record(snapshot(0), coalescingKey: nil)
        let undone = history.undo(current: snapshot(10))

        XCTAssertEqual(undone, snapshot(0))
        XCTAssertTrue(history.canRedo)
        XCTAssertEqual(history.redo(current: snapshot(0)), snapshot(10))
    }

    func testNewEditDiscardsTheRedoStack() {
        var history = TrimEditHistory()
        history.record(snapshot(0), coalescingKey: nil)
        _ = history.undo(current: snapshot(10))
        XCTAssertTrue(history.canRedo)

        history.record(snapshot(0), coalescingKey: nil)

        XCTAssertFalse(history.canRedo, "分岐した後の redo は復元できない")
    }

    func testHistoryIsBounded() {
        var history = TrimEditHistory()
        for index in 0 ... (TrimEditHistory.limit + 50) {
            history.record(snapshot(Double(index)), coalescingKey: nil)
        }

        var steps = 0
        var current = snapshot(9999)
        while let previous = history.undo(current: current) {
            current = previous
            steps += 1
        }
        XCTAssertEqual(steps, TrimEditHistory.limit)
    }

    func testClearDropsEverything() {
        var history = TrimEditHistory()
        history.record(snapshot(0), coalescingKey: nil)
        _ = history.undo(current: snapshot(1))

        history.clear()

        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }
}

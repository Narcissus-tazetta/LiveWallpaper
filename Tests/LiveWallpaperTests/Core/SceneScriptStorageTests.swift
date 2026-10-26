import Foundation
import XCTest
@testable import LiveWallpaper

final class SceneScriptStorageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func text(_ value: String) -> Data { Data(value.utf8) }

    func testValuesCountTheirBytesPlusEightAcrossAreasAndAFailedWriteKeepsTheOldValue() {
        let storage = SceneScriptStorage(directory: directory)
        let screen = storage.session(path: "/scene", screen: "A")
        // A 99 990-character string is 99 992 bytes of JSON: with its 8 it fills the limit.
        let full = text("\"" + String(repeating: "a", count: 99_990) + "\"")
        XCTAssertTrue(screen.store.set(text("p"), full, in: screen.area(global: false)))
        XCTAssertFalse(screen.store.set(text("q"), text("1"), in: screen.area(global: true)))
        XCTAssertFalse(screen.store.set(text("p"), text("\"" + String(repeating: "a", count: 99_991) + "\""), in: screen.area(global: false)))
        XCTAssertEqual(screen.store.get(text("p"), in: screen.area(global: false)), full)
        // Overwriting counts only the difference.
        XCTAssertTrue(screen.store.set(text("p"), full, in: screen.area(global: false)))
        XCTAssertTrue(screen.store.delete(text("p"), in: screen.area(global: false)))
        XCTAssertFalse(screen.store.delete(text("p"), in: screen.area(global: false)))
        for index in 0 ..< 9090 {
            XCTAssertTrue(screen.store.set(text("k\(index)"), text("\"a\""), in: screen.area(global: index % 2 == 0)))
        }
        XCTAssertFalse(screen.store.set(text("last"), text("\"a\""), in: screen.area(global: true)))
    }

    func testScreensShareTheGlobalAreaAndAnInstanceOnNoScreenUsesItForBoth() {
        let storage = SceneScriptStorage(directory: directory)
        let first = storage.session(path: "/scene", screen: "A"), second = storage.session(path: "/scene", screen: "B")
        let preview = storage.session(path: "/scene", screen: nil)
        _ = first.store.set(text("k"), text("1"), in: first.area(global: false))
        _ = first.store.set(text("g"), text("2"), in: first.area(global: true))
        XCTAssertNil(second.store.get(text("k"), in: second.area(global: false)))
        XCTAssertEqual(second.store.get(text("g"), in: second.area(global: true)), text("2"))
        XCTAssertEqual(preview.store.get(text("g"), in: preview.area(global: false)), text("2"))
        XCTAssertNil(storage.session(path: "/other", screen: "A").store.get(text("g"), in: .global))
    }

    func testWritesReachTheFileAfterTheDelayAndASnapshotKeepsItsOwn() throws {
        let storage = SceneScriptStorage(directory: directory)
        let session = storage.session(path: "/scene", screen: "A")
        _ = session.store.set(text("k\0ey"), text("{\"a\":[1,2,3]}"), in: .screen("A"))
        let snapshot = storage.snapshot(path: "/scene")
        _ = snapshot.store.set(text("bake"), text("1"), in: .global)
        let saved = expectation(description: "saved")
        DispatchQueue.global().asyncAfter(deadline: .now() + SceneScriptStorage.saveDelay + 0.5) { saved.fulfill() }
        wait(for: [saved], timeout: SceneScriptStorage.saveDelay + 2)
        let reopened = SceneScriptStorage(directory: directory).session(path: "/scene/", screen: "A")
        XCTAssertEqual(reopened.store.get(text("k\0ey"), in: .screen("A")), text("{\"a\":[1,2,3]}"))
        XCTAssertNil(reopened.store.get(text("bake"), in: .global))
    }

    func testScriptsReachTheStorageTheyAreGiven() throws {
        let layer = SceneLayer(name: "Image", imageFile: "image.png")
        var document = SceneDocument(canvasWidth: 100, canvasHeight: 80, layers: [layer])
        var script = SceneScript(source: """
        function update(c){
          const before = __lwjs_storage(0, 0, 'n');
          __lwjs_storage(1, 0, 'n', String(Number(before ?? 0) + 1));
          return [{id:c.targets[0].id, values:{offsetX:Number(before ?? 0) * 0.1}}];
        }
        """, layerIDs: [layer.id])
        script.isAuthorized = true
        document.scripts = [script]
        let storage = SceneScriptStorage(directory: directory)
        let evaluator = SceneFrameEvaluator(storage: storage.session(path: "/scene", screen: "A"))
        _ = try evaluator.evaluate(document, input: SceneFrameInput(time: 0), timeOfDay: .day)
        let frame = try evaluator.evaluate(document, input: SceneFrameInput(time: 0.1), timeOfDay: .day)
        XCTAssertEqual(frame.layers[layer.id]!.transform.offsetX, 0.1, accuracy: 1e-9)
        XCTAssertEqual(storage.session(path: "/scene", screen: "A").store.get(text("n"), in: .screen("A")), text("2"))
    }
}

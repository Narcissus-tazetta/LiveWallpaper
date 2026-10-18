import Foundation
@testable import LiveWallpaper
import XCTest

final class SceneScriptModuleTests: XCTestCase {
    private func scene(source: String, modules: [String: String]) -> SceneDocument {
        let layer = SceneLayer(name: "Image", imageFile: "image.png")
        var script = SceneScript(source: source, layerIDs: [layer.id])
        script.modules = modules
        script.isAuthorized = true
        var document = SceneDocument(canvasWidth: 100, canvasHeight: 80, layers: [layer])
        document.scripts = [script]
        return document
    }

    func testImportsKeepModuleStateAndResetAfterSeekingBackwards() throws {
        let document = scene(source: """
        import { next } from './lib/counter.js';
        export function update(c) { return [{id:c.targets[0].id, values:{offsetX:next()}}]; }
        """, modules: ["lib/counter.js": "let n=0; export function next(){return ++n/100;}"])
        let evaluator = SceneFrameEvaluator()
        let id = document.layers[0].id
        let first = try evaluator.evaluate(document, input: .init(time: 61), timeOfDay: .day)
        let second = try evaluator.evaluate(document, input: .init(time: 62), timeOfDay: .day)
        let reset = try evaluator.evaluate(document, input: .init(time: 61), timeOfDay: .day)
        XCTAssertEqual(first.layers[id]!.transform.offsetX, 0.01)
        XCTAssertEqual(second.layers[id]!.transform.offsetX, 0.02)
        XCTAssertEqual(reset.layers[id]!.transform.offsetX, 0.01)
    }

    func testChangedModuleInvalidatesPermissionAndCompiledProgram() throws {
        var document = scene(source: """
        import { amount } from 'values';
        export function update(c){return [{id:c.targets[0].id,values:{offsetX:amount}}];}
        """, modules: ["values": "export const amount=0.1;"])
        let script = document.scripts[0]
        let evaluator = SceneFrameEvaluator()
        let first = try evaluator.evaluate(document, input: .rest, timeOfDay: .day)
        document.scripts[0].modules!["values"] = "export const amount=0.2;"
        let second = try evaluator.evaluate(document, input: .rest, timeOfDay: .day)
        XCTAssertEqual(first.layers[document.layers[0].id]!.transform.offsetX, 0.1)
        XCTAssertEqual(second.layers[document.layers[0].id]!.transform.offsetX, 0.2)
        XCTAssertNotEqual(SceneScriptPermissions.fingerprint(script, path: "/tmp/example"),
                          SceneScriptPermissions.fingerprint(document.scripts[0], path: "/tmp/example"))
        let decoded = try JSONDecoder().decode(SceneDocument.self, from: JSONEncoder().encode(document))
        XCTAssertFalse(decoded.scripts[0].canRun)
        XCTAssertEqual(decoded.scripts[0].modules, document.scripts[0].modules)
    }

    func testPreparedBundleChangesAreStillValidated() throws {
        let runtime = SceneScriptRuntime()
        var script = SceneScript(source: "export function update(){return []}", layerIDs: [])
        script.modules = ["values": "export const amount=0.1;"]
        try runtime.prepare(script)
        try runtime.prepare(script)
        script.modules?["values"] = "export const amount=0.1;\0"
        XCTAssertThrowsError(try runtime.prepare(script))
        script.modules?["values"] = "export const amount=0.2;"
        try runtime.prepare(script)
        script.source += "\0"
        XCTAssertThrowsError(try runtime.prepare(script))
    }

    func testPartFailureIsReportedWhileTheRestRuns() throws {
        let document = scene(source: """
        export function update(c){return {adjustments:[{id:c.targets[0].id,values:{offsetX:0.1}}],warnings:['Part.visible update: boom']};}
        """, modules: [:])
        let frame = try SceneFrameEvaluator().evaluate(document, input: .rest, timeOfDay: .day)
        XCTAssertEqual(frame.layers[document.layers[0].id]!.transform.offsetX, 0.1)
        XCTAssertEqual(frame.issues.map(\.message), ["Part.visible update: boom"])
        XCTAssertEqual(frame.issues.map(\.isPartial), [true])
        XCTAssertNoThrow(try SceneFrameEvaluator().evaluate(document, input: .rest, timeOfDay: .day))
    }

    func testWallClockNeedsTimeOfDayAndFollowsBakedTime() throws {
        var document = scene(source: """
        let first;
        export function update(c){first??=c.wallClock.epochMilliseconds;
          return [{id:c.targets[0].id,values:{offsetX:(c.wallClock.epochMilliseconds-first)/10000}}];}
        """, modules: [:])
        XCTAssertThrowsError(try SceneFrameEvaluator().evaluate(document, input: .rest, timeOfDay: .day)) {
            XCTAssertTrue(($0 as? SceneScriptIssue)?.message.contains("wallClock") == true, "\($0)")
        }
        document.scripts[0].usesTimeOfDay = true
        let evaluator = SceneFrameEvaluator()
        _ = try evaluator.evaluate(document, input: .init(time: 2), timeOfDay: .day)
        let later = try evaluator.evaluate(document, input: .init(time: 3), timeOfDay: .day)
        XCTAssertEqual(later.layers[document.layers[0].id]!.transform.offsetX, 0.1, accuracy: 1e-9)
    }

    func testModuleStartMayTakeLongerThanAFrame() throws {
        let work = "let x=0; for(let i=0;i<300000;i++) x+=i%7;"
        let document = scene(source: "\(work) export function update(c){return [];}", modules: [:])
        let evaluator = SceneFrameEvaluator()
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertNoThrow(try evaluator.evaluate(document, input: .init(time: 0), timeOfDay: .day))
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        guard elapsed > SceneFrameEvaluator.Budget.live.perScript else {
            throw XCTSkip("Module start took \(elapsed) s, within one frame's budget on this machine")
        }
        // The first update is part of the start; the same work in a later frame is not.
        let slowFrame = scene(source: "let frames=0; export function update(c){if(frames++){\(work)} return [];}", modules: [:])
        let later = SceneFrameEvaluator()
        XCTAssertNoThrow(try later.evaluate(slowFrame, input: .init(time: 0), timeOfDay: .day))
        XCTAssertThrowsError(try later.evaluate(slowFrame, input: .init(time: 1), timeOfDay: .day))
    }

    func testUnknownImportsExceptionsAndInfiniteLoopsStop() {
        for source in [
            "import * as os from 'os'; export function update(){return []}",
            "import x from '../../etc/passwd'; export function update(){return []}",
            "throw new Error('module-init'); export function update(){return []}",
            "while(true){} export function update(){return []}",
            "export function update(){while(true){}}",
            "await new Promise(()=>{}); export function update(){return []}",
            "await 0; export function update(){return []}"
        ] {
            let document = scene(source: source, modules: [:])
            let start = ProcessInfo.processInfo.systemUptime
            XCTAssertThrowsError(try SceneFrameEvaluator().evaluate(document, input: .rest, timeOfDay: .day), source)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
        }
    }

    func testRigPlaybackUpdatesReachSharedPoseAndRejectOtherRigs() throws {
        let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        let rigID = UUID()
        var moved = SceneSkeleton.Transform()
        moved.translation = [10, 0, 0]
        let rig = SceneSkeleton(bones: [.init(name: "root", rest: .init(), inverseBind: identity)],
                                clips: [.init(name: "move", framesPerSecond: 1, frameCount: 1,
                                              tracks: [.init(bone: 0, transforms: [.init(), moved])])],
                                playback: [.init(clip: 0)],
                                attachments: [.init(name: "socket", bone: 0, transform: identity)])
        var document = scene(source: """
        export function update(c){return [{id:c.targets[0].id,order:0,rigs:[{id:c.targets[0].rigs[0].id,
          playback:[{index:0,frame:0.5,weight:1}]}]}];}
        """, modules: [:])
        document.rigs[rigID] = rig
        document.layers[0].placement = .init(steps: [.init(matrix: identity, skeletonID: rigID, attachment: "socket")],
                                             referenceTransform: .identity)
        let frame = try SceneFrameEvaluator().evaluate(document, input: .init(time: 100), timeOfDay: .day)
        let registry = try SceneSkeletonRegistry(document.rigs)
        registry.setPlaybackOverrides(frame.rigPlayback)
        let evaluator = try registry.evaluator(rigID)
        XCTAssertEqual(evaluator.evaluate(time: 100).attachments["socket"]!.columns.3.x, 5, accuracy: 0.0001)
        registry.setPlaybackOverrides([:])
        XCTAssertEqual(evaluator.evaluate(time: 100).attachments["socket"]!.columns.3.x, 0, accuracy: 0.0001)
        let illegal: [[String: Any]] = [["id": document.layers[0].id.uuidString,
                                        "rigs": [["id": UUID().uuidString, "playback": []]]]]
        XCTAssertThrowsError(try SceneScriptRuntime.readOutput(JSONSerialization.data(withJSONObject: illegal),
                                                              script: document.scripts[0], layers: document.layers, rigs: document.rigs))
    }

    func testLargeBundledModuleAndTimeBeyondTheLoop() throws {
        let document = scene(source: """
        import { payload } from 'large';
        export function update(c){return [{id:c.targets[0].id,values:{offsetX:c.elapsedTime/1000}}];}
        """, modules: ["large": "export const payload='" + String(repeating: "a", count: 355000) + "';"])
        let frame = try SceneFrameEvaluator().evaluate(document, input: .init(time: 65), timeOfDay: .day)
        XCTAssertEqual(frame.layers[document.layers[0].id]!.transform.offsetX, 0.065)
    }
}

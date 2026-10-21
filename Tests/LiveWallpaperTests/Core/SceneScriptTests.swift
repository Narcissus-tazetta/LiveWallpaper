import Foundation
import XCTest
@testable import LiveWallpaper

final class SceneScriptTests: XCTestCase {
    private func scene(_ source: String) -> SceneDocument {
        let layer = SceneLayer(name: "Image", imageFile: "image.png")
        var document = SceneDocument(canvasWidth: 100, canvasHeight: 80, layers: [layer])
        var script = SceneScript(source: source, layerIDs: [layer.id])
        script.isAuthorized = true
        document.scripts = [script]
        return document
    }

    func testSameInputsMatchAfterSeekingAndDoNotKeepGlobals() throws {
        let document = scene("var count = 0; function update(c){count++; return [{id:c.targets[0].id, values:{offsetX:wave(c.phase)*0.1 + count*0.01}}];}")
        let evaluator = SceneFrameEvaluator()
        let first = try evaluator.evaluate(document, input: SceneFrameInput(time: 5), timeOfDay: .day)
        _ = try evaluator.evaluate(document, input: SceneFrameInput(time: 2), timeOfDay: .day)
        let repeated = try evaluator.evaluate(document, input: SceneFrameInput(time: 5), timeOfDay: .day)
        XCTAssertEqual(first.layers[document.layers[0].id]?.transform, repeated.layers[document.layers[0].id]?.transform)
        XCTAssertEqual(first.layers[document.layers[0].id]!.transform.offsetX, 0.11, accuracy: 1e-9)
        XCTAssertEqual(document.layers[0].transform, .identity)
    }

    func testScriptsCombineAfterKeyframesAndGUILinks() throws {
        var document = scene("function update(c){return [{id:c.targets[0].id,values:{offsetX:0.2,scale:2,opacity:0.5}}];}")
        document.layers[0].transform.offsetX = 0.1
        var link = SceneLink(input: .timeOfDay, layerIDs: [document.layers[0].id])
        var values = SceneLinkValues(); values.offsetX = 0.3; values.scale = 2
        link.timeValues[.night] = values
        document.links = [link]
        let frame = try SceneFrameEvaluator().evaluate(document, input: .rest, timeOfDay: .night)
        XCTAssertEqual(frame.layers[document.layers[0].id]!.transform.offsetX, 0.6, accuracy: 1e-9)
        XCTAssertEqual(frame.layers[document.layers[0].id]!.transform.scale, 4)
        XCTAssertEqual(frame.layers[document.layers[0].id]!.opacity, 0.5)
    }

    func testEngineInterruptsLoopsGettersRecursionAndAllocation() {
        let sources = [
            "function update(c){while(true){}}",
            "function update(c){while(true){try{while(true){}}catch(e){}}}",
            "function update(c){return [{get id(){while(true){}}}]}",
            "function update(c){function f(){return f()};return f()}",
            "function update(c){let a=[];for(;;)a.push(new Array(10000).fill(1))}",
            "function update(c){return /^(a+)+$/.test('a'.repeat(100000)+'x')}",
            "while(true){}; function update(c){return []}"
        ]
        for source in sources {
            let start = ProcessInfo.processInfo.systemUptime
            XCTAssertThrowsError(try SceneFrameEvaluator().evaluate(scene(source), input: .rest, timeOfDay: .day), source)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5, source)
        }
    }

    func testNoHostAccessOrNonDeterministicAPIs() throws {
        let source = """
        function update(c){
          for(const name of ['fetch','WebSocket','require','std','os','process','Date','Promise','Atomics','SharedArrayBuffer','Function','eval']){
            if(typeof globalThis[name] !== 'undefined') throw new Error('Unexpected API: '+name);
          }
          for(const fn of [function(){},async function(){},function*(){},async function*(){}]){
            if(fn.constructor !== undefined) throw new Error('Function constructor exposed');
          }
          return [{id:c.targets[0].id,values:{offsetX:random(7,3)}}];
        }
        """
        let document = scene(source)
        let evaluator = SceneFrameEvaluator()
        let a = try evaluator.evaluate(document, input: .rest, timeOfDay: .day)
        let b = try evaluator.evaluate(document, input: .rest, timeOfDay: .day)
        XCTAssertEqual(a.layers[document.layers[0].id]!.transform, b.layers[document.layers[0].id]!.transform)
        XCTAssertThrowsError(try SceneFrameEvaluator().evaluate(scene("function update(c){Math.random();return []}"), input: .rest, timeOfDay: .day))
    }

    func testMalformedOutputIsRejectedInsteadOfSilentlyIgnored() {
        for values in ["{offsetX:NaN}", "{opacity:Infinity}", "{scale:0}", "{opacity:true}", "{file:'secret'}", "{offsetX:null}"] {
            let source = "function update(c){return [{id:c.targets[0].id,values:\(values)}]}"
            XCTAssertThrowsError(try SceneFrameEvaluator().evaluate(scene(source), input: .rest, timeOfDay: .day), values)
        }
        XCTAssertThrowsError(try SceneFrameEvaluator().evaluate(scene("function update(c){return [{id:'invalid',values:{}}]}"), input: .rest, timeOfDay: .day))
    }

    func testDependenciesAreEnforcedAndDriveAnimation() throws {
        var document = scene("function update(c){return [{id:c.targets[0].id,values:{offsetX:c.cursor.x}}]}")
        document.scripts[0].usesTime = false
        XCTAssertThrowsError(try SceneFrameEvaluator().evaluate(document, input: .rest, timeOfDay: .day))
        document.scripts[0].usesCursor = true
        XCTAssertTrue(document.usesCursor)
        XCTAssertFalse(document.isAnimated)
        XCTAssertNoThrow(try SceneFrameEvaluator().evaluate(document, input: .rest, timeOfDay: .day))
        document.scripts[0].usesTimeOfDay = true
        XCTAssertTrue(document.usesTimeOfDay)
        XCTAssertFalse(document.looksSame(at: .day, as: .night))
    }

    func testFailuresStayStoppedUntilSourceChanges() throws {
        var document = scene("function update(c){if(c.phase>0.1)throw new Error('broken');return []}")
        let evaluator = SceneFrameEvaluator()
        let failed = try evaluator.evaluate(document, input: SceneFrameInput(time: 5), timeOfDay: .day, failOnError: false)
        XCTAssertEqual(failed.issues.count, 1)
        let stillStopped = try evaluator.evaluate(document, input: .rest, timeOfDay: .day, failOnError: false)
        XCTAssertEqual(stillStopped.issues, failed.issues)
        document.scripts[0].source = "function update(c){return []}"
        XCTAssertTrue(try evaluator.evaluate(document, input: .rest, timeOfDay: .day).issues.isEmpty)
    }

    func testAuthorizationDoesNotTravelInJSONAndLegacyScenesLoad() throws {
        let document = scene("function update(c){return []}")
        let data = try JSONEncoder().encode(document)
        let restored = try JSONDecoder().decode(SceneDocument.self, from: data)
        XCTAssertFalse(restored.scripts[0].isAuthorized)
        XCTAssertTrue(restored.hasUnapprovedScripts)
        XCTAssertEqual(restored.scripts[0].source, document.scripts[0].source)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "scripts")
        let old = try JSONDecoder().decode(SceneDocument.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(old.scripts.isEmpty)
    }

    func testUnknownAPIVersionIsPreservedButCannotRun() throws {
        var document = scene("function update(c){return []}")
        document.scripts[0].version = 999
        XCTAssertFalse(document.scripts[0].canRun)
        let restored = try JSONDecoder().decode(SceneDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(restored.scripts[0].version, 999)
        XCTAssertEqual(restored.scripts[0].source, document.scripts[0].source)
    }

    func testEffectAndParticleOutputsReachTheFrameOnly() throws {
        var document = scene("function update(c){return [{id:c.targets[0].id,effects:[{id:c.targets[0].effects[0].id,isEnabled:false,strength:0.8}],particles:{count:100,opacity:0.2,color:{red:1,green:0,blue:0,alpha:1}}}]} ")
        document.layers[0].particles = SceneParticles(preset: .snow)
        document.layers[0].kind = .particles
        document.layers[0].effects = [SceneEffect(kind: .waves)]
        let frame = try SceneFrameEvaluator().evaluate(document, input: .rest, timeOfDay: .day)
        let layer = frame.layers[document.layers[0].id]!.layer
        XCTAssertFalse(layer.effects[0].isEnabled)
        XCTAssertEqual(layer.effects[0].strength, 0.8)
        XCTAssertEqual(layer.particles?.count, 100)
        XCTAssertEqual(layer.particles?.opacity, 0.2)
        XCTAssertTrue(document.layers[0].effects[0].isEnabled)
        XCTAssertNotEqual(document.layers[0].particles?.count, 100)
    }

    func testAllSamplesRunAtMultipleTimesAndInputConditions() throws {
        for sample in SceneScriptSample.allCases {
            var document = scene(sample.source)
            document.layers[0].effects = [SceneEffect(kind: .waves)]
            if [.master, .particles, .palette, .dayParticles, .particleWind, .particleCursor].contains(sample) {
                document.layers[0].kind = .particles
                document.layers[0].particles = SceneParticles(preset: .fireflies)
            }
            document.scripts[0].usesTime = sample.usesTime
            document.scripts[0].usesCursor = sample.usesCursor
            document.scripts[0].usesTimeOfDay = sample.usesTimeOfDay
            // Sample correctness must not depend on the CI runner meeting a live frame deadline.
            let evaluator = SceneFrameEvaluator(budget: .offline)
            for time in [0.0, 5, 10, 19.99] {
                for band in SceneTimeOfDay.allCases {
                    XCTAssertNoThrow(try evaluator.evaluate(document, input: SceneFrameInput(time: time), timeOfDay: band), sample.rawValue)
                }
            }
        }
    }

    func testAsynchronousAndModuleCodeCannotRun() {
        for source in ["async function update(c){return []}", "function update(c){return import('std')}",
                       "function update(c){return new Promise(r=>r([]))}",
                       "function update(c){return [{id:c.targets[0].id,get values(){(async()=>{await 0})();return {opacity:1}}}]}"
        ] {
            XCTAssertThrowsError(try SceneFrameEvaluator().evaluate(scene(source), input: .rest, timeOfDay: .day), source)
        }
    }

    func testProceduralHelpersAndCanvasDimensions() throws {
        var document = scene("function update(c){return [{id:c.targets[0].id,values:{offsetX:noise(0.5,3)*0.1,offsetY:c.canvas.aspectRatio/10},particles:{color:hsv(0,1,1)}}]}")
        document.layers[0].particles = SceneParticles(preset: .snow)
        let frame = try SceneFrameEvaluator().evaluate(document, input: .rest, timeOfDay: .day)
        XCTAssertEqual(frame.layers[document.layers[0].id]!.transform.offsetY, 0.125)
        XCTAssertEqual(frame.layers[document.layers[0].id]!.layer.particles?.color, RGBAColor(red: 1, green: 0, blue: 0, alpha: 1))
    }

    func testConsoleIsBoundedAndItsGettersCannotHang() throws {
        let document = scene("function update(c){for(let i=0;i<100;i++)console.log('x'.repeat(10000));return []}")
        let result = try SceneFrameEvaluator().evaluate(document, input: .rest, timeOfDay: .day)
        XCTAssertLessThanOrEqual(result.logs[document.scripts[0].id]!.utf8.count, 4095)
        XCTAssertThrowsError(try SceneFrameEvaluator().evaluate(scene("function update(c){console.log({toString(){while(true){}}});return []}"), input: .rest, timeOfDay: .day))
    }

    func testMultipleScriptsCombineAndDeletedTargetsDoNotCrash() throws {
        var document = scene("function update(c){return c.targets.map(l=>({id:l.id,values:{offsetX:0.1}}))}")
        var second = document.scripts[0]; second.id = UUID()
        document.scripts.append(second)
        let frame = try SceneFrameEvaluator().evaluate(document, input: .rest, timeOfDay: .day)
        XCTAssertEqual(frame.layers[document.layers[0].id]!.transform.offsetX, 0.2)
        document.layers = []
        XCTAssertNoThrow(try SceneFrameEvaluator().evaluate(document, input: .rest, timeOfDay: .day))
    }

    func testRunningOutOfTimeOnScreenPausesAndResumes() throws {
        let document = scene("function update(c){if(c.phase>0.5){while(true){}}return [{id:c.targets[0].id,values:{offsetX:0.1}}]}")
        let evaluator = SceneFrameEvaluator(temporaryStopSeconds: 0.2)
        let slow = try evaluator.evaluate(document, input: SceneFrameInput(time: 15), timeOfDay: .day, failOnError: false)
        XCTAssertEqual(slow.issues.map(\.isTemporary), [true])
        let paused = try evaluator.evaluate(document, input: .rest, timeOfDay: .day, failOnError: false)
        XCTAssertEqual(paused.layers[document.layers[0].id]!.transform.offsetX, 0)
        Thread.sleep(forTimeInterval: 0.25)
        let resumed = try evaluator.evaluate(document, input: .rest, timeOfDay: .day, failOnError: false)
        XCTAssertTrue(resumed.issues.isEmpty)
        XCTAssertEqual(resumed.layers[document.layers[0].id]!.transform.offsetX, 0.1, accuracy: 1e-9)
    }

    func testErrorsOtherThanTimeStayStopped() throws {
        let document = scene("function update(c){throw new Error('broken')}")
        let evaluator = SceneFrameEvaluator(temporaryStopSeconds: 0)
        let failed = try evaluator.evaluate(document, input: .rest, timeOfDay: .day, failOnError: false)
        XCTAssertEqual(failed.issues.map(\.isTemporary), [false])
        XCTAssertEqual(try evaluator.evaluate(document, input: .rest, timeOfDay: .day, failOnError: false).issues, failed.issues)
    }

    func testBakesAllowFramesSlowerThanTheScreenButStopEndlessCode() throws {
        let slow = scene("function update(c){let x=0;for(let i=0;i<1e6;i++)x+=i;return [{id:c.targets[0].id,values:{offsetX:x>0?0.1:0}}]}")
        XCTAssertThrowsError(try SceneFrameEvaluator().evaluate(slow, input: .rest, timeOfDay: .day))
        let frame = try SceneFrameEvaluator(budget: .offline).evaluate(slow, input: .rest, timeOfDay: .day)
        XCTAssertEqual(frame.layers[slow.layers[0].id]!.transform.offsetX, 0.1, accuracy: 1e-9)
        XCTAssertThrowsError(try SceneFrameEvaluator(budget: .offline).evaluate(scene("function update(c){while(true){}}"), input: .rest, timeOfDay: .day))
    }

    func testScriptsReadNonASCIIKeysAndExactNumbers() throws {
        var document = scene("""
        function update(c){return [{id:c.targets[0].id,values:{offsetX:c.params['速さ'] + (c.params.speed === 0.1 ? 0 : 1)}}]}
        """)
        document.scripts[0].params = ["速さ": 0.0021054233122316966, "speed": 0.1]
        let frame = try SceneFrameEvaluator().evaluate(document, input: .rest, timeOfDay: .day)
        XCTAssertEqual(frame.layers[document.layers[0].id]!.transform.offsetX, 0.0021054233122316966)
    }

    func testFractionsInWholeNumberFieldsNameTheField() {
        var document = scene("function update(c){return [{id:c.targets[0].id,particles:{count:100.5}}]}")
        document.layers[0].particles = SceneParticles(preset: .snow)
        XCTAssertThrowsError(try SceneFrameEvaluator().evaluate(document, input: .rest, timeOfDay: .day)) { error in
            XCTAssertTrue((error as? SceneScriptIssue)?.message.contains("particles.count") == true, "\(error)")
        }
    }

    func testModularScriptRequiresLiveInteraction() {
        var script = SceneScript(source: "export function update(){}", layerIDs: [])
        script.isAuthorized = true
        script.usesCursor = true
        XCTAssertTrue(script.requiresLiveInteraction)

        script.modules = [
            "scene-bridge": "export const engine = { cursor: { x: 0, y: 0 }, media: {} };",
            "binding0.js": "export function update(v){ v.z = engine.runtime * 20; return v; }"
        ]
        XCTAssertFalse(script.requiresLiveInteraction)

        script.modules?["binding1.js"] = "export function update(v){ if(engine.cursor.x > 0) v.z = 1; return v; }"
        XCTAssertTrue(script.requiresLiveInteraction)

        var clockScript = SceneScript(source: "export function update(){}", layerIDs: [])
        clockScript.isAuthorized = true
        clockScript.usesTimeOfDay = true
        clockScript.modules = [
            "clock.js": "export function update(c){ return [{id: c.targets[0].id, values:{rotation: c.wallClock.epochMilliseconds / 1000}}]; }"
        ]
        XCTAssertTrue(clockScript.requiresLiveInteraction)
    }

    func testSceneDocumentHasLiveInteraction() {
        let plainLayer = SceneLayer(name: "BG", imageFile: "bg.png")
        var document = SceneDocument(canvasWidth: 100, canvasHeight: 100, layers: [plainLayer])
        XCTAssertFalse(document.hasLiveInteraction)

        var cursorLayer = SceneLayer(name: "Cursor", imageFile: "cursor.png")
        cursorLayer.parallaxDepth = 1.0
        document.layers = [cursorLayer]
        XCTAssertTrue(document.hasLiveInteraction)

        var cursorDoc = SceneDocument(canvasWidth: 100, canvasHeight: 100, layers: [plainLayer])
        var link = SceneLink(input: .cursorX, layerIDs: [plainLayer.id])
        link.start.offsetX = 0.5
        cursorDoc.links = [link]
        XCTAssertTrue(cursorDoc.hasLiveInteraction)

        var script = SceneScript(source: "export function update(){}", layerIDs: [])
        script.isAuthorized = true
        script.usesCursor = true
        script.modules = [
            "scene-bridge": "export const engine = { cursor: { x: 0, y: 0 } };",
            "code.js": "export function update(v){ v.x += 1; return v; }"
        ]
        document.layers = [plainLayer]
        document.scripts = [script]
        XCTAssertFalse(document.hasLiveInteraction)

        script.modules?["code.js"] = "export function update(v){ if (engine.cursor.x > 0) v.x += 1; return v; }"
        document.scripts = [script]
        XCTAssertTrue(document.hasLiveInteraction)
    }
}

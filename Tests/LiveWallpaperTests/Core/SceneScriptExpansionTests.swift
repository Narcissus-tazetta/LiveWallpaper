import XCTest
@testable import LiveWallpaper

final class SceneScriptExpansionTests: XCTestCase {
    private func scene(_ source: String) -> SceneDocument {
        var layer = SceneLayer(name: "Particles", particles: SceneParticles(preset: .fireflies))
        layer.effects = [SceneEffect(kind: .waves)]
        var script = SceneScript(source: source, layerIDs: [layer.id])
        script.isAuthorized = true
        var document = SceneDocument(canvasWidth: 64, canvasHeight: 48, layers: [layer])
        document.scripts = [script]
        return document
    }

    func testHelpersAndAppearanceProduceDeterministicDrawableValues() throws {
        var document = scene("""
        function update(c) {
          const a = vec.of(0, 0), b = vec.of(1, 0);
          const point = path.bezier(a, a, b, b, 0.5);
          return c.targets.map(l => ({
            id:l.id,
            values:{offsetX:point.x, offsetY:vec.distance(b,vec.rotate(b,90)),
                    brightness:curve(0.5,[{time:0,value:0},{time:1,value:0.6}]),
                    saturation:mapRange(triangle(0.5),-1,1,0,2)},
            appearance:{isVisible:false,blendMode:'screen',parallaxDepth:0.8,
                        depthStrength:0.7,depthAutoMotion:0.3,depthAutoCycles:3,
                        cursorMask:{mode:'show',radius:0.2,softness:0.4}},
            effects:l.effects.map(e=>({id:e.id,kind:'ripple',fixedEdge:e.fixedEdge,centerX:e.centerX,centerY:e.centerY,reversed:e.reversed})),
            particles:{preset:'snow',cursorMode:'attract',seed:123,color:color.hex('#FF000080')}
          }));
        }
        """)
        document.scripts[0].usesCursor = true
        document.layers[0].effects[0].fixedEdge = .bottom
        document.layers[0].effects[0].centerX = 0.25
        document.layers[0].effects[0].reversed = true
        let evaluator = SceneFrameEvaluator()
        let first = try evaluator.evaluate(document, input: .rest, timeOfDay: .day).layers[document.layers[0].id]!
        let repeated = try evaluator.evaluate(document, input: .rest, timeOfDay: .day).layers[document.layers[0].id]!
        XCTAssertEqual(first.layer, repeated.layer)
        XCTAssertEqual(first.transform.offsetX, 0.5)
        XCTAssertEqual(first.transform.offsetY, 2.squareRoot(), accuracy: 0.00001)
        XCTAssertEqual(first.color.brightness, 0.3)
        XCTAssertEqual(first.color.saturation, 2)
        XCTAssertFalse(first.layer.isVisible)
        XCTAssertEqual(first.layer.blendMode, .screen)
        XCTAssertEqual(first.layer.cursorMask?.mode, .show)
        XCTAssertEqual(first.layer.effects[0].kind, .ripple)
        XCTAssertEqual(first.layer.effects[0].fixedEdge, .bottom)
        XCTAssertEqual(first.layer.effects[0].centerX, 0.25)
        XCTAssertTrue(first.layer.effects[0].reversed)
        XCTAssertEqual(first.layer.particles?.preset, .snow)
        XCTAssertEqual(first.layer.particles?.color.alpha ?? 0, 128 / 255, accuracy: 0.00001)
        XCTAssertTrue(document.layers[0].isVisible)
    }

    func testExpandedFieldsStillRejectInvalidTypesAndHostResources() {
        for output in ["appearance:{blendMode:null}", "appearance:{blendMode:'invalid'}",
                       "appearance:{parallaxDepth:2}", "appearance:{isVisible:1}",
                       "appearance:{cursorMask:{mode:'invalid'}}", "appearance:{depthFile:'/tmp/file'}",
                       "appearance:{clearCursorMask:true,cursorMask:{radius:0.2}}",
                       "particles:{preset:'invalid'}", "particles:{seed:-1}",
                       "effects:[{id:l.effects[0].id,kind:'invalid'}]"] {
            let document = scene("function update(c){return c.targets.map(l=>({id:l.id,\(output)}))}")
            XCTAssertThrowsError(try SceneFrameEvaluator().evaluate(document, input: .rest, timeOfDay: .day), output)
        }
    }

    func testThirtyTwoScriptsSaveButMoreAreRejected() throws {
        var document = scene(SceneScriptSample.blank.source)
        let template = document.scripts[0]
        document.scripts = (0..<SceneScript.maximumCount).map { _ in
            var script = template; script.id = UUID(); return script
        }
        let loaded = try JSONDecoder().decode(SceneDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(loaded.scripts.count, 32)
        XCTAssertFalse(loaded.scripts[0].canRun)
        var extra = template; extra.id = UUID(); document.scripts.append(extra)
        XCTAssertThrowsError(try JSONDecoder().decode(SceneDocument.self, from: JSONEncoder().encode(document)))
        XCTAssertEqual(SceneScriptSample.allCases.first, .blank)
        XCTAssertFalse(SceneScriptSample.blank.usesTime)
    }

    func testVersionOneScriptsStillRun() throws {
        var document = scene("function update(c){return [{id:c.targets[0].id,values:{offsetX:0.25}}]}")
        document.scripts[0].version = 1
        XCTAssertTrue(document.scripts[0].canRun)
        let frame = try SceneFrameEvaluator().evaluate(document, input: .rest, timeOfDay: .day)
        XCTAssertEqual(frame.layers[document.layers[0].id]!.transform.offsetX, 0.25)
    }

    func testNewCursorAndTimeRenderingNeedsDeclaredInputs() throws {
        var document = scene("function update(c){return [{id:c.targets[0].id,appearance:{parallaxDepth:0.5}}]}")
        XCTAssertThrowsError(try SceneFrameEvaluator().evaluate(document, input: .rest, timeOfDay: .day))
        document.scripts[0].usesCursor = true
        XCTAssertNoThrow(try SceneFrameEvaluator().evaluate(document, input: .rest, timeOfDay: .day))
        document.layers[0].isVisible = false
        document.scripts[0].usesTime = false
        document.scripts[0].source = "function update(c){return [{id:c.targets[0].id,appearance:{isVisible:true}}]}"
        XCTAssertThrowsError(try SceneFrameEvaluator().evaluate(document, input: .rest, timeOfDay: .day))
        document.scripts[0].usesTime = true
        XCTAssertNoThrow(try SceneFrameEvaluator().evaluate(document, input: .rest, timeOfDay: .day))
    }

    func testOneScriptIncludesNewLayersAndScopeSurvivesSaving() throws {
        var document = scene("function update(c){return c.targets.map(l=>({id:l.id,values:{brightness:0.25}}))}")
        document.scripts[0].targetsAllLayers = true
        let evaluator = SceneFrameEvaluator()
        let second = SceneLayer(name: "New image", imageFile: "new.png")
        document.layers.append(second)
        let result = try evaluator.evaluate(document, input: .rest, timeOfDay: .day)
        XCTAssertEqual(result.layers[second.id]?.color.brightness, 0.25)
        XCTAssertEqual(result.layers[document.layers[0].id]?.color.brightness, 0.25)
        let data = try JSONEncoder().encode(document)
        let loaded = try JSONDecoder().decode(SceneDocument.self, from: data)
        XCTAssertTrue(loaded.scripts[0].targetsAllLayers)
        XCTAssertFalse(loaded.scripts[0].canRun)
        document.scripts[0].targetsAllLayers = false
        let selected = try evaluator.evaluate(document, input: .rest, timeOfDay: .day)
        XCTAssertEqual(selected.layers[second.id]?.color.brightness, 0)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var scripts = json["scripts"] as! [[String: Any]]
        scripts[0].removeValue(forKey: "targetsAllLayers")
        json["scripts"] = scripts
        let legacy = try JSONDecoder().decode(SceneDocument.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(legacy.scripts[0].targetsAllLayers)
    }
}

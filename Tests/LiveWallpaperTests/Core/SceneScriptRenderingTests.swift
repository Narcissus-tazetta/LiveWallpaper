import AppKit
import AVFoundation
import Metal
import XCTest
@testable import LiveWallpaper

@MainActor
final class SceneScriptRenderingTests: XCTestCase {
    private func fixture(_ directory: URL) throws -> (SceneDocument, String) {
        let path = directory.appendingPathComponent("source.mp4").path
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let file = try SceneStore.writeImage(context.makeImage()!, prefix: "layer", videoPath: path)
        let layer = SceneLayer(name: "Image", imageFile: file)
        var document = SceneDocument(canvasWidth: 64, canvasHeight: 48, layers: [layer])
        var script = SceneScript(source: "function update(c){return [{id:c.targets[0].id,values:{offsetX:wave(c.phase)*0.05,brightness:0.1,scale:0.8}}]}", layerIDs: [layer.id])
        script.isAuthorized = true
        document.scripts = [script]
        document.loopSeconds = 1
        return (document, path)
    }

    private func pixels(_ renderer: SceneRenderer, input: SceneFrameInput, frame: SceneEvaluatedFrame) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 48, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let command = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
        try renderer.encode(into: texture, commandBuffer: command, input: input, frame: frame)
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        var result = [UInt8](repeating: 0, count: 64 * 48 * 4)
        texture.getBytes(&result, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 48), mipmapLevel: 0)
        return result
    }

    func testLiveAndBakeEvaluationDrawTheSamePixelsAndMarkers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScriptRender-\(UUID())")
        defer { try! FileManager.default.removeItem(at: directory) }
        let (document, path) = try fixture(directory)
        let input = SceneFrameInput(time: 0.25)
        let liveFrame = try await Task.detached { try SceneFrameEvaluator().evaluate(document, input: input, timeOfDay: .day) }.value
        let bakeFrame = try await Task.detached { try SceneFrameEvaluator().evaluate(document, input: input, timeOfDay: .day) }.value
        let live = try SceneRenderer(document: document, videoPath: path)
        let bake = try SceneRenderer(document: document, videoPath: path)
        XCTAssertEqual(try pixels(live, input: input, frame: liveFrame), try pixels(bake, input: input, frame: bakeFrame))
        XCTAssertEqual(live.currentTransform(layerID: document.layers[0].id), liveFrame.layers[document.layers[0].id]!.transform)
        let uv = SIMD2<Float>(0.2, 0.3)
        let canvas = try XCTUnwrap(live.canvasUV(layerUV: uv, layerID: document.layers[0].id))
        let restored = try XCTUnwrap(live.layerUV(canvasUV: canvas, layerID: document.layers[0].id))
        XCTAssertEqual(restored.x, uv.x, accuracy: 0.00001)
        XCTAssertEqual(restored.y, uv.y, accuracy: 0.00001)
    }

    func testScriptedTintAboveOneBrightensWhatTheShaderMultipliesInAndStopsAtWhite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TintRender-\(UUID())")
        defer { try! FileManager.default.removeItem(at: directory) }
        var (document, path) = try fixture(directory)
        document.scripts[0].source = "function update(c){return [{id:c.targets[0].id,appearance:{tint:{red:1.25,green:1.25,blue:1.25,alpha:1}}}]}"
        let input = SceneFrameInput(time: 0)
        let frame = try await Task.detached { [document] in try SceneFrameEvaluator().evaluate(document, input: input, timeOfDay: .day) }.value
        XCTAssertEqual(frame.layers[document.layers[0].id]!.layer.tint.red, 1.25)
        let renderer = try SceneRenderer(document: document, videoPath: path)
        let result = try pixels(renderer, input: input, frame: frame)
        var plain = document
        plain.scripts = []
        let unscripted = try await Task.detached { [plain] in try SceneFrameEvaluator().evaluate(plain, input: input, timeOfDay: .day) }.value
        let reference = try pixels(try SceneRenderer(document: plain, videoPath: path), input: input, frame: unscripted)
        // BGRA at the centre: blue and green rise by the tint, red (215 * 1.25 > 255) stops at white.
        let centre = (24 * 64 + 32) * 4
        XCTAssertEqual(Double(result[centre]), Double(reference[centre]) * 1.25, accuracy: 1.5)
        XCTAssertEqual(Double(result[centre + 1]), Double(reference[centre + 1]) * 1.25, accuracy: 1.5)
        XCTAssertEqual(result[centre + 2], 255)
    }

    func testMediaArtworkChangesAndUnavailableMediaRestoresTheLayerImage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArtworkRender-\(UUID())")
        defer { try! FileManager.default.removeItem(at: directory) }
        var (document, path) = try fixture(directory)
        document.scripts = []
        let mask = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        mask.setFillColor(CGColor(gray: 1, alpha: 1))
        mask.fillEllipse(in: CGRect(x: 0, y: 0, width: 64, height: 48))
        document.layers[0].imageFile = try SceneStore.writeImage(XCTUnwrap(mask.makeImage()), prefix: "artwork-mask", videoPath: path)
        document.layers[0].usesMediaArtwork = true
        let restored = try JSONDecoder().decode(SceneDocument.self, from: JSONEncoder().encode(document))
        XCTAssertTrue(restored.layers[0].usesMediaArtwork)
        XCTAssertTrue(restored.requiresRealTimePlayback)
        let renderer = try SceneRenderer(document: restored, videoPath: path)
        let evaluator = SceneFrameEvaluator()
        func draw(_ media: SceneMediaState?) throws -> [UInt8] {
            let input = SceneFrameInput(media: media)
            let frame = try evaluator.evaluate(restored, input: input, timeOfDay: .day)
            return try pixels(renderer, input: input, frame: frame)
        }
        func artwork(_ color: CGColor) throws -> Data {
            let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            return try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
        }
        let fallback = try draw(nil)
        let center = (24 * 64 + 32) * 4
        var media = SceneMediaState(isAvailable: true, artworkID: "red", artworkData: try artwork(CGColor(red: 1, green: 0, blue: 0, alpha: 1)))
        let red = try draw(media)
        XCTAssertGreaterThan(Int(red[center + 2]) - Int(red[center + 1]), 150)
        XCTAssertEqual(Array(red.prefix(4)), Array(fallback.prefix(4)))
        media.artworkID = "green"
        media.artworkData = try artwork(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        let green = try draw(media)
        XCTAssertGreaterThan(Int(green[center + 1]) - Int(green[center + 2]), 150)
        media.isAvailable = false
        XCTAssertEqual(try draw(media), fallback)
        media.isAvailable = true
        media.artworkID = ""
        media.artworkData = nil
        XCTAssertEqual(try draw(media), fallback)
    }

    func testBakerWritesScriptMotionAndFailureKeepsThePreviousVideo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScriptBake-\(UUID())")
        defer { try! FileManager.default.removeItem(at: directory) }
        var (document, path) = try fixture(directory)
        let video = directory.appendingPathComponent("out.mp4")
        try await SceneVideoBaker.bake(document: document, videoPath: path, to: video) { _ in }
        let bytes = try Data(contentsOf: video)
        XCTAssertGreaterThan(bytes.count, 1000)
        let duration = try await AVURLAsset(url: video).load(.duration)
        XCTAssertEqual(duration.seconds, 1, accuracy: 0.05)
        document.scripts[0].source = "function update(c){if(c.phase>0.3)throw new Error('failure during bake');return []}"
        do {
            try await SceneVideoBaker.bake(document: document, videoPath: path, to: video) { _ in }
            XCTFail("A failing script must not produce a successful video")
        } catch {
            XCTAssertEqual(try Data(contentsOf: video), bytes)
        }
    }

    func testPermissionsAreLocalAndImportRevokesThem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScriptShare-\(UUID())")
        defer { try! FileManager.default.removeItem(at: directory) }
        let (document, path) = try fixture(directory)
        defer { SceneScriptPermissions.revoke(document, path: path) }
        SceneScriptPermissions.authorize(document.scripts[0], path: path)
        try SceneStore.save(document, videoPath: path)
        let loaded = try XCTUnwrap(SceneStore.load(videoPath: path))
        XCTAssertFalse(loaded.scripts[0].isAuthorized)
        XCTAssertTrue(SceneScriptPermissions.restored(loaded, path: path).scripts[0].canRun)
        var changed = loaded
        changed.scripts[0].source += "\n"
        XCTAssertFalse(SceneScriptPermissions.restored(changed, path: path).scripts[0].canRun)
        let packaged = directory.appendingPathComponent("package/scene")
        try SceneStore.copyScene(videoPath: path, to: packaged)
        let importedPath = directory.appendingPathComponent("imported.mp4").path
        FileManager.default.createFile(atPath: importedPath, contents: Data())
        let imported = try SceneStore.importScene(from: packaged, videoPath: importedPath)
        XCTAssertFalse(imported.scripts[0].canRun)
        XCTAssertEqual(imported.scripts[0].source, document.scripts[0].source)
        SceneScriptPermissions.revoke(loaded, path: path)
        XCTAssertFalse(SceneScriptPermissions.restored(loaded, path: path).scripts[0].canRun)
    }

    func testAppearanceChangesReachTheRenderedPixels() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScriptAppearance-\(UUID())")
        defer { try! FileManager.default.removeItem(at: directory) }
        var (document, path) = try fixture(directory)
        for appearance in ["{isVisible:false}", "{blendMode:'multiply'}"] {
            document.scripts[0].source = "function update(c){return [{id:c.targets[0].id,appearance:\(appearance)}]}"
            let input = document
            let frame = try await Task.detached { try SceneFrameEvaluator().evaluate(input, input: .rest, timeOfDay: .day) }.value
            let renderer = try SceneRenderer(document: document, videoPath: path)
            let result = try pixels(renderer, input: .rest, frame: frame)
            XCTAssertEqual(renderer.currentLayer(layerID: document.layers[0].id)?.isVisible, appearance == "{isVisible:false}" ? false : true)
            for i in stride(from: 0, to: result.count, by: 4) {
                XCTAssertEqual(Array(result[i..<i+4]), [0, 0, 0, 255], appearance)
            }
        }
    }

    func testLiveWorkerStopsRecursiveScriptsOffTheMainThread() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScriptWorker-\(UUID())")
        defer { try! FileManager.default.removeItem(at: directory) }
        var (document, _) = try fixture(directory)
        document.scripts[0].source = "function update(c){function recurse(){return recurse()}return recurse()}"
        let worker = SceneScriptWorker()
        let result = await withCheckedContinuation { continuation in
            worker.evaluate(document, input: .rest, timeOfDay: .day) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(try result.get().issues.count, 1)
        XCTAssertTrue(try result.get().issues[0].message.lowercased().contains("stack"))
        document.scripts[0].source = "function update(c){return []}"
        let recovered = await withCheckedContinuation { continuation in
            worker.evaluate(document, input: .rest, timeOfDay: .day) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(try recovered.get().issues.isEmpty)
    }

    func testApplyingAndUndoingScriptsKeepsFailedDraftsOutOfTheDocument() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScriptEdit-\(UUID())")
        let (original, path) = try fixture(directory)
        let model = WallpaperModel()
        model.registerImportedScene(original, path: path)
        defer {
            model.cancelSceneBake(path: path)
            model.discardSceneSave(path: path)
            SceneScriptPermissions.revoke(model.sceneDocumentsByPath[path]!, path: path)
            try! FileManager.default.removeItem(at: directory)
        }
        let imported = model.sceneDocumentsByPath[path]!
        XCTAssertFalse(imported.scripts[0].canRun)
        var script = imported.scripts[0]
        script.source = "function update(c){return [{id:c.targets[0].id,values:{brightness:0.2}}]}"
        try await model.applySceneScript(script, path: path, input: .rest, timeOfDay: .day)
        let applied = model.sceneDocumentsByPath[path]!
        XCTAssertTrue(applied.scripts[0].canRun)
        XCTAssertEqual(applied.scripts[0].source, script.source)
        let editor = SceneScriptEditorController()
        editor.edit(applied.scripts[0], path: path) { $0.script.source = "function update(c){while(true){}}" }
        await editor.run(applied.scripts[0], path: path, model: model, input: .rest, timeOfDay: .day)
        XCTAssertNotNil(editor.draft(for: applied.scripts[0], path: path).error)
        XCTAssertEqual(model.sceneDocumentsByPath[path], applied)
        model.undoScene(path: path)
        XCTAssertEqual(model.sceneDocumentsByPath[path], imported)
        model.redoScene(path: path)
        XCTAssertEqual(model.sceneDocumentsByPath[path], applied)
    }
}

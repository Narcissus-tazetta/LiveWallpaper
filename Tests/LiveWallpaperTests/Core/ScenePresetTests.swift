import AppKit
@testable import LiveWallpaper
import XCTest

@MainActor
final class ScenePresetTests: XCTestCase {
    private var directory: URL!
    private var video: URL!
    private var model: WallpaperModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScenePresetTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        video = directory.appendingPathComponent("scene.mp4")
        let scene = SceneDocument(canvasWidth: 8, canvasHeight: 8, layers: [
            SceneLayer(name: "photo", imageFile: try writeImage(videoPath: video.path))
        ])
        try SceneStore.save(scene, videoPath: video.path)
        model = WallpaperModel()
        model.scenePresetStore = ScenePresetStore(directory: directory.appendingPathComponent("Presets"))
        model.registerImportedScene(scene, path: video.path)
    }

    override func tearDownWithError() throws {
        model.endScenePresetTrial()
        model.cancelSceneBake(path: video.path)
        model.discardSceneSave(path: video.path)
        try FileManager.default.removeItem(at: directory)
    }

    private func writeImage(videoPath: String) throws -> String {
        let image = CGImage(
            width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(repeating: 200, count: 8 * 8 * 4) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )!
        return try SceneStore.writeImage(image, prefix: "layer", videoPath: videoPath)
    }

    private var scene: SceneDocument {
        model.sceneDocumentsByPath[video.path]!
    }

    private func fileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(
            atPath: SceneStore.folderURL(forVideoPath: video.path).appendingPathComponent(name).path
        )
    }

    /// The photo with a masked sway, as if painted by the user.
    private func paintedPhoto() throws -> SceneLayer {
        var layer = scene.layers[0]
        var sway = SceneEffect(kind: .sway)
        sway.strength = 0.8
        sway.maskFile = try SceneStore.writePaintImage(
            [UInt8](repeating: 255, count: 64), width: 8, height: 8, target: .mask, videoPath: video.path
        )
        var puppet = SceneEffect(kind: .puppet)
        puppet.pins = [ScenePin(x: 0.25, y: 0.75, isAnchor: true)]
        layer.effects = [sway, puppet]
        var document = scene
        document.layers[0] = layer
        model.updateScene(document, path: video.path, coalescing: false)
        return layer
    }

    // MARK: - Applying

    func testEveryBuiltInAppliesToAnImageLayer() throws {
        let layerID = scene.layers[0].id
        for kind in ScenePreset.BuiltIn.allCases {
            let preset = ScenePreset.builtIn(kind, localize: { $0 })
            let result = try XCTUnwrap(preset.applied(to: scene, layerID: layerID), "\(kind)")
            XCTAssertEqual(result.document.layers[0].imageFile, scene.layers[0].imageFile)
            XCTAssertEqual(result.document.layers.count, 1 + preset.particleLayers.count)
            XCTAssertTrue(result.document.isAnimated || result.document.usesCursor || preset.wantsDepth, "\(kind) does something")
        }
    }

    func testBuiltInsThatNeedPaintOrAIListThoseSteps() throws {
        let layerID = scene.layers[0].id
        func steps(_ kind: ScenePreset.BuiltIn) throws -> [ScenePresetStep] {
            try XCTUnwrap(ScenePreset.builtIn(kind, localize: { $0 }).applied(to: scene, layerID: layerID)).guide.steps
        }
        XCTAssertEqual(try steps(.depthFireflies), [.estimateDepth])
        XCTAssertEqual(try steps(.cherryBlossoms), [])
        let water = try steps(.waterSurface)
        XCTAssertEqual(water.count, 1, "drawing the direction is the area too")
        XCTAssertTrue(water.contains { if case .drawFlow = $0 { true } else { false } })
        let hair = try steps(.hairSway)
        XCTAssertTrue(hair.first.map { if case .paintMask = $0 { true } else { false } } ?? false)
        XCTAssertTrue(hair.last.map { if case .moveToOwnLayer = $0 { true } else { false } } ?? false)
    }

    func testParticlesGoRightAboveTheLayerAndKeepItsPlacement() throws {
        var document = scene
        document.layers[0].transform.scale = 1.5
        document.layers[0].opacity = 0.4
        document.layers.append(SceneLayer(name: "top", imageFile: document.layers[0].imageFile))
        let preset = ScenePreset.builtIn(.fallingSnow, localize: { $0 })

        let applied = try XCTUnwrap(preset.applied(to: document, layerID: document.layers[0].id)).document
        XCTAssertEqual(applied.layers.map(\.name), ["photo", "雪(遠く)", "雪(近く)", "top"])
        XCTAssertEqual(applied.layers[0].transform.scale, 1.5)
        XCTAssertEqual(applied.layers[0].opacity, 0.4)
    }

    func testApplyingTwiceGivesIndependentIDs() throws {
        let preset = ScenePreset.builtIn(.hairSway, localize: { $0 })
        let layerID = scene.layers[0].id
        let first = try XCTUnwrap(preset.applied(to: scene, layerID: layerID)).document
        let second = try XCTUnwrap(preset.applied(to: first, layerID: layerID)).document
        XCTAssertNotEqual(first.layers[0].effects[0].id, second.layers[0].effects[0].id)
    }

    func testParticleLayersCannotTakeAPreset() {
        var document = scene
        document.layers.append(SceneLayer(name: "snow", particles: SceneParticles(preset: .snow)))
        XCTAssertNil(ScenePreset.builtIn(.hairSway, localize: { $0 }).applied(to: document, layerID: document.layers[1].id))
    }

    // MARK: - Capturing

    func testWithoutPaintTheAreasBecomeSteps() throws {
        let layer = try paintedPhoto()
        let preset = ScenePreset.capture(name: "mine", layer: layer, particleLayers: [], includingPaint: false)
        XCTAssertTrue(preset.referencedFiles.isEmpty)

        let result = try XCTUnwrap(preset.applied(to: scene, layerID: layer.id))
        XCTAssertNil(result.document.layers[0].effects[0].maskFile)
        XCTAssertEqual(result.document.layers[0].effects[0].strength, 0.8)
        XCTAssertEqual(result.guide.steps.count, 2, "paint the sway, pin the puppet")
    }

    // MARK: - Trial and the model

    func testTrialLeavesTheSceneAndApplyIsOneUndoStep() throws {
        let before = scene
        let layerID = scene.layers[0].id
        model.beginScenePresetTrial(ScenePreset.builtIn(.depthFireflies, localize: { $0 }), layerID: layerID, path: video.path)
        XCTAssertEqual(scene, before)
        XCTAssertEqual(model.scenePresetTrial?.document.layers.count, 2)

        model.applyScenePresetTrial()
        XCTAssertNil(model.scenePresetTrial)
        XCTAssertEqual(scene.layers.count, 2)
        XCTAssertEqual(model.scenePresetGuides[video.path]?.steps, [.estimateDepth])

        model.undoScene(path: video.path)
        XCTAssertEqual(scene, before)
    }

    func testTrialFollowsEditsMadeMeanwhile() throws {
        let layerID = scene.layers[0].id
        model.beginScenePresetTrial(ScenePreset.builtIn(.hairSway, localize: { $0 }), layerID: layerID, path: video.path)
        var document = scene
        document.loopSeconds = 10
        model.updateScene(document, path: video.path)
        XCTAssertEqual(model.scenePresetTrial?.document.loopSeconds, 10)
    }

    func testSavedPresetWithPaintLandsOnAnotherPictureAndSurvivesPruning() throws {
        let layer = try paintedPhoto()
        XCTAssertTrue(model.saveUserScenePreset(
            name: "mine", layerID: layer.id, path: video.path, includingPaint: true, includingParticles: false
        ))
        model.userScenePresets = nil
        model.loadUserScenePresetsIfNeeded()
        let preset = try XCTUnwrap(model.userScenePresets?.first)
        XCTAssertEqual(preset.name, "mine")
        XCTAssertEqual(preset.effects[0].effect.pins, [], "sway has no pins")
        XCTAssertEqual(preset.effects[1].effect.pins.map(\.x), [0.25])

        // Another, wider picture in the same scene.
        let wide = SceneLayer(name: "wide", imageFile: try writeImage(videoPath: video.path))
        var document = scene
        document.layers.append(wide)
        model.updateScene(document, path: video.path, coalescing: false)

        model.beginScenePresetTrial(preset, layerID: wide.id, path: video.path)
        let trialMask = try XCTUnwrap(model.scenePresetTrial?.document.layers.last?.effects[0].maskFile)
        XCTAssertNotEqual(trialMask, layer.effects[0].maskFile)
        // Saving an edit meanwhile prunes files the scene does not name.
        document = scene
        document.layers[0].opacity = 0.5
        model.updateScene(document, path: video.path)
        model.flushSceneSave(path: video.path)
        XCTAssertTrue(fileExists(trialMask), "the preview still shows it")

        model.applyScenePresetTrial()
        let applied = try XCTUnwrap(scene.layers.last)
        XCTAssertEqual(applied.effects[0].maskFile, trialMask)
        XCTAssertEqual(applied.effects[1].pins.map(\.y), [0.75])
        XCTAssertNil(model.scenePresetGuides[video.path], "nothing left to paint")
        model.flushSceneSave(path: video.path)
        XCTAssertTrue(fileExists(trialMask))
        XCTAssertEqual(try SceneStore.load(videoPath: video.path), scene)
    }

    func testEndingATrialRemovesItsCopies() throws {
        let layer = try paintedPhoto()
        XCTAssertTrue(model.saveUserScenePreset(
            name: "mine", layerID: layer.id, path: video.path, includingPaint: true, includingParticles: false
        ))
        let preset = try XCTUnwrap(model.userScenePresets?.first)
        model.beginScenePresetTrial(preset, layerID: layer.id, path: video.path)
        let copy = try XCTUnwrap(model.scenePresetTrial?.document.layers[0].effects[0].maskFile)
        XCTAssertTrue(fileExists(copy))

        model.endScenePresetTrial()
        XCTAssertFalse(fileExists(copy))
        XCTAssertTrue(fileExists(try XCTUnwrap(layer.effects[0].maskFile)), "the scene's own mask stays")
    }

    func testDeletingAPresetRemovesItsFolder() throws {
        let layer = try paintedPhoto()
        XCTAssertTrue(model.saveUserScenePreset(
            name: "mine", layerID: layer.id, path: video.path, includingPaint: true, includingParticles: false
        ))
        let preset = try XCTUnwrap(model.userScenePresets?.first)
        let folder = try XCTUnwrap(model.scenePresetStore).folderURL(of: preset.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        model.deleteUserScenePreset(preset.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(model.userScenePresets, [])
    }

    func testUndoingThePresetRetiresItsGuide() throws {
        let layerID = scene.layers[0].id
        model.beginScenePresetTrial(ScenePreset.builtIn(.depthFireflies, localize: { $0 }), layerID: layerID, path: video.path)
        model.applyScenePresetTrial()
        let guide = try XCTUnwrap(model.scenePresetGuides[video.path])
        XCTAssertTrue(guide.isActive(in: scene))

        model.undoScene(path: video.path)
        XCTAssertFalse(guide.isActive(in: scene), "the fireflies are gone, so is the preset")
        model.redoScene(path: video.path)
        XCTAssertTrue(guide.isActive(in: scene))
    }

    func testHairMovesToItsOwnLayerAsOneStepAndTheGuideFollows() async throws {
        let layerID = scene.layers[0].id
        model.beginScenePresetTrial(ScenePreset.builtIn(.hairSway, localize: { $0 }), layerID: layerID, path: video.path)
        model.applyScenePresetTrial()
        let guide = try XCTUnwrap(model.scenePresetGuides[video.path])
        XCTAssertEqual(guide.steps.count, 2)
        let effectID = scene.layers[0].effects[0].id
        let unpainted = await model.moveScenePaintedAreaToOwnLayer(effectID: effectID, layerID: layerID, path: video.path)
        XCTAssertNil(unpainted, "nothing painted yet")

        // Paint the lower half.
        let mask = try SceneStore.writePaintImage(
            (0 ..< 64).map { $0 >= 32 ? 255 : 0 }, width: 8, height: 8, target: .mask, videoPath: video.path
        )
        model.setScenePaintFile(mask, kind: .mask, effectID: effectID, layerID: layerID, path: video.path)
        let painted = scene
        let moved = await model.moveScenePaintedAreaToOwnLayer(effectID: effectID, layerID: layerID, path: video.path)
        let areaID = try XCTUnwrap(moved)

        XCTAssertEqual(scene.layers.map(\.id), [layerID, areaID])
        let rest = scene.layers[0]
        let area = scene.layers[1]
        XCTAssertTrue(rest.effects.isEmpty, "the effect went with the area")
        XCTAssertEqual(area.effects.map(\.id), [effectID])
        XCTAssertNil(area.effects[0].maskFile, "the area's outline is the cut-out itself")
        XCTAssertEqual(area.effects[0].fixedEdge, .top)
        XCTAssertEqual(area.effects[0].areaBounds?.minY ?? 0, 0.5, accuracy: 0.07, "within a pixel of the 8 px mask")
        XCTAssertNotEqual(rest.imageFile, painted.layers[0].imageFile, "the area's place is filled in")
        XCTAssertTrue(guide.steps.allSatisfy { guide.isDone($0, in: scene) == true })
        XCTAssertTrue(guide.isActive(in: scene))

        model.undoScene(path: video.path)
        XCTAssertEqual(scene, painted)
        XCTAssertTrue(fileExists(painted.layers[0].imageFile))
        model.redoScene(path: video.path)
        model.flushSceneSave(path: video.path)
        XCTAssertTrue(fileExists(area.imageFile))
        XCTAssertTrue(fileExists(rest.imageFile))
    }

    func testCutOutHasTheMaskAsAlphaAndTheRestIsFilled() throws {
        // Left half red, right half green; the right half is cut out.
        let width = 32
        var pixels = [UInt8](repeating: 255, count: width * width * 4)
        for index in 0 ..< width * width {
            let isRight = index % width >= width / 2
            pixels[index * 4] = isRight ? 0 : 255
            pixels[index * 4 + 1] = isRight ? 255 : 0
            pixels[index * 4 + 2] = 0
        }
        let image = CGImage(
            width: width, height: width, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )!
        let file = try SceneStore.writeImage(image, prefix: "layer", videoPath: video.path)
        let mask = try SceneStore.writePaintImage(
            (0 ..< width * width).map { $0 % width >= width / 2 ? 255 : 0 }, width: width, height: width,
            target: .mask, videoPath: video.path
        )
        let folder = SceneStore.folderURL(forVideoPath: video.path)
        let separation = try SceneAI.separateArea(
            imageURL: folder.appendingPathComponent(file), maskURL: folder.appendingPathComponent(mask)
        )
        func rgba(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            let context = CGContext(
                data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
            return bytes
        }
        XCTAssertEqual(rgba(separation.foreground, x: 2, y: 16)[3], 0, "outside the area is clear")
        XCTAssertEqual(rgba(separation.foreground, x: 28, y: 16), [0, 255, 0, 255])
        let filled = rgba(separation.background, x: 28, y: 16)
        XCTAssertGreaterThan(filled[0], 200, "the hole takes the red around it")
        XCTAssertLessThan(filled[1], 60)
        XCTAssertEqual(filled[3], 255)
    }

    func testGuideTicksOffAPaintedArea() throws {
        let layerID = scene.layers[0].id
        model.beginScenePresetTrial(ScenePreset.builtIn(.hairSway, localize: { $0 }), layerID: layerID, path: video.path)
        model.applyScenePresetTrial()
        let guide = try XCTUnwrap(model.scenePresetGuides[video.path])
        let step = try XCTUnwrap(guide.steps.first)
        XCTAssertEqual(guide.isDone(step, in: scene), false)

        let effectID = scene.layers[0].effects[0].id
        let mask = try SceneStore.writePaintImage(
            [UInt8](repeating: 255, count: 64), width: 8, height: 8, target: .mask, videoPath: video.path
        )
        model.setScenePaintFile(mask, kind: .mask, effectID: effectID, layerID: layerID, path: video.path)
        XCTAssertEqual(guide.isDone(step, in: scene), true)
    }
}

@testable import LiveWallpaper
import XCTest

@MainActor
final class SceneLiveDecisionTests: XCTestCase {
    private func scene(cursorLayer: Bool = false, mediaArtwork: Bool = false) -> SceneDocument {
        var layer = SceneLayer(name: "Image", imageFile: "image.png")
        if cursorLayer { layer.cursorMask = SceneCursorMask() }
        layer.usesMediaArtwork = mediaArtwork
        return SceneDocument(canvasWidth: 100, canvasHeight: 80, layers: [layer])
    }

    private func live(
        _ document: SceneDocument,
        cursorReacts: Bool,
        isStale: Bool = false,
        scriptsDriveSound: Bool = false
    ) -> Bool {
        WallpaperModel.drawsSceneLive(
            document, listensToAudio: false, cursorReacts: cursorReacts,
            isStale: isStale, scriptsDriveSound: scriptsDriveSound
        )
    }

    func testCursorSceneIsLiveOnlyWhileTheCursorMovesIt() {
        let document = scene(cursorLayer: true)
        XCTAssertTrue(document.usesCursor)
        XCTAssertTrue(live(document, cursorReacts: true))
        XCTAssertFalse(live(document, cursorReacts: false))
    }

    func testOtherLiveNeedsAndAnOutdatedVideoKeepItLive() {
        XCTAssertTrue(live(scene(cursorLayer: true, mediaArtwork: true), cursorReacts: false))
        XCTAssertTrue(live(scene(cursorLayer: true), cursorReacts: false, isStale: true))
        XCTAssertTrue(live(scene(), cursorReacts: false, scriptsDriveSound: true))
        XCTAssertFalse(live(scene(), cursorReacts: true))
    }

    func testCursorScriptNeedsTheCursorButMediaScriptDoesNot() {
        var script = SceneScript(source: "export function update(c){return [];}", layerIDs: [])
        script.isAuthorized = true
        script.usesCursor = true
        XCTAssertTrue(script.requiresLiveInteraction(cursorReacts: true))
        XCTAssertFalse(script.requiresLiveInteraction(cursorReacts: false))
        script.usesMedia = true
        XCTAssertTrue(script.requiresLiveInteraction(cursorReacts: false))
    }

    func testShownSceneBakesOnceOnMainsPower() {
        func bakes(
            animated: Bool = true, battery: Bool = false, baking: Bool = false,
            failed: Bool = false, tried: Bool = false
        ) -> Bool {
            WallpaperModel.shouldBakeShownScene(
                isAnimated: animated, isOnBattery: battery, isBaking: baking,
                hasFailed: failed, alreadyTried: tried
            )
        }
        XCTAssertTrue(bakes())
        XCTAssertFalse(bakes(animated: false))
        XCTAssertFalse(bakes(battery: true))
        XCTAssertFalse(bakes(baking: true))
        XCTAssertFalse(bakes(failed: true))
        XCTAssertFalse(bakes(tried: true))
    }
}

@testable import LiveWallpaper
import XCTest

final class SceneMediaSubscriptionTests: XCTestCase {
    private func scene(source: String, usesMedia: Bool) -> SceneDocument {
        let layer = SceneLayer(name: "Image", imageFile: "image.png")
        var script = SceneScript(source: source, layerIDs: [layer.id])
        script.modules = [:]
        script.isAuthorized = true
        script.usesMedia = usesMedia
        var document = SceneDocument(canvasWidth: 100, canvasHeight: 80, layers: [layer])
        document.scripts = [script]
        return document
    }

    @MainActor
    func testSuspendedSceneReadsNoMediaOrSoundButKeepsWhatItWants() {
        let document = scene(
            source: "export function update(c){registerAudioBuffers(64);return [];}",
            usesMedia: true
        )
        let shown = SceneMetalLayer.mediaNeeds(
            document: document, listensToSound: true, isSuspended: false
        )
        XCTAssertEqual(shown.subscribed, .init(media: true, spectrum: true))
        XCTAssertEqual(shown.wanted, shown.subscribed)

        let suspended = SceneMetalLayer.mediaNeeds(
            document: document, listensToSound: true, isSuspended: true
        )
        XCTAssertEqual(suspended.subscribed, .init())
        XCTAssertEqual(suspended.wanted, .init(media: true, spectrum: true))
    }

    @MainActor
    func testSoundNeedsTheReactionTurnedOn() {
        let document = scene(
            source: "export function update(c){registerAudioBuffers(64);return [];}",
            usesMedia: false
        )
        let needs = SceneMetalLayer.mediaNeeds(
            document: document, listensToSound: false, isSuspended: false
        )
        XCTAssertEqual(needs.subscribed, .init())
    }
}

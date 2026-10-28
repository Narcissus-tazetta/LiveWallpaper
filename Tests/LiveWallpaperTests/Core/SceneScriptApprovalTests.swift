@testable import LiveWallpaper
import XCTest

@MainActor
final class SceneScriptApprovalTests: XCTestCase {
    private let path = "/tmp/SceneScriptApprovalTests-\(UUID().uuidString)/scene.mp4"
    private let copy = "/tmp/SceneScriptApprovalTests-\(UUID().uuidString)/copy.mp4"

    private func scene(source: String = "function update(c){return []}") -> SceneDocument {
        let layer = SceneLayer(name: "layer", imageFile: "a.png")
        var document = SceneDocument(canvasWidth: 8, canvasHeight: 8, layers: [layer])
        document.scripts = [SceneScript(source: source, layerIDs: [layer.id])]
        return document
    }

    override func tearDown() {
        for target in [path, copy] {
            SceneScriptPermissions.revoke(scene(), path: target)
            SceneScriptPermissions.revoke(scene(source: "changed"), path: target)
            for version in ["v1", "v2", "v3", "v4"] { SceneScriptPermissions.revoke(scene(source: version), path: target) }
        }
    }

    func testAllowedScriptsRunAgainWhenTheSceneIsRegisteredAgain() throws {
        let model = WallpaperModel()
        model.registerImportedScene(scene(), path: path)
        XCTAssertTrue(model.sceneDocumentsByPath[path]!.hasUnapprovedScripts)
        model.requestSceneScriptApproval(id: "item", name: "Item", path: path)
        let request = try XCTUnwrap(model.sceneScriptApprovalRequests.first)
        model.answerSceneScriptApproval(request, allow: true)
        XCTAssertTrue(model.sceneScriptApprovalRequests.isEmpty)
        XCTAssertTrue(model.sceneDocumentsByPath[path]!.scripts[0].canRun)

        // A relaunch registers the prepared scene again.
        let relaunched = WallpaperModel()
        relaunched.registerImportedScene(scene(), path: path)
        XCTAssertTrue(relaunched.sceneDocumentsByPath[path]!.scripts[0].canRun)
        // Changed code asks again.
        relaunched.registerImportedScene(scene(source: "changed"), path: path)
        XCTAssertFalse(relaunched.sceneDocumentsByPath[path]!.scripts[0].canRun)
    }

    func testDecliningLeavesScriptsStoppedAndAsksOnlyOnce() throws {
        let model = WallpaperModel()
        model.registerImportedScene(scene(), path: path)
        model.requestSceneScriptApproval(id: "item", name: "Item", path: path)
        model.requestSceneScriptApproval(id: "item", name: "Item", path: path)
        XCTAssertEqual(model.sceneScriptApprovalRequests.count, 1)
        model.answerSceneScriptApproval(try XCTUnwrap(model.sceneScriptApprovalRequests.first), allow: false)
        XCTAssertFalse(model.sceneDocumentsByPath[path]!.scripts[0].canRun)
    }

    func testApprovalCarriesToTheLibraryCopyButNotThroughAPackage() {
        SceneScriptPermissions.authorizeAll(scene(), path: path)
        SceneScriptPermissions.carry(scene(), from: path, to: copy)
        let model = WallpaperModel()
        model.registerImportedScene(scene(), path: copy)
        XCTAssertTrue(model.sceneDocumentsByPath[copy]!.scripts[0].canRun)
        model.registerImportedScene(scene(), path: copy, asksAgain: true)
        XCTAssertFalse(model.sceneDocumentsByPath[copy]!.scripts[0].canRun)
    }

    private func converted(origin: String?, bridge: String) -> SceneDocument {
        var document = scene(source: bridge)
        document.scriptOrigin = origin
        return document
    }

    func testReconversionKeepsApprovalWhenTheScriptsComeFromTheSameOrigin() {
        let previous = converted(origin: "a", bridge: "v1")
        SceneScriptPermissions.authorizeAll(previous, path: path)
        let previousApproved = SceneScriptPermissions.restored(previous, path: path)

        let reconverted = converted(origin: "a", bridge: "v2")
        XCTAssertFalse(SceneScriptPermissions.restored(reconverted, path: path).scripts[0].isAuthorized)
        SceneScriptPermissions.carry(reconverted, replacing: previousApproved, path: path)
        XCTAssertTrue(SceneScriptPermissions.restored(reconverted, path: path).scripts[0].isAuthorized)
    }

    func testReconversionAsksAgainWhenTheOriginChangedOrWasNeverAllowedOrIsUnknown() {
        let previous = converted(origin: "a", bridge: "v1")
        SceneScriptPermissions.authorizeAll(previous, path: path)
        let approved = SceneScriptPermissions.restored(previous, path: path)
        let notAllowed = converted(origin: "a", bridge: "v1")

        for (reconverted, before) in [(converted(origin: "b", bridge: "v2"), approved),
                                      (converted(origin: nil, bridge: "v3"), approved),
                                      (converted(origin: "a", bridge: "v4"), notAllowed)] {
            SceneScriptPermissions.carry(reconverted, replacing: before, path: path)
            XCTAssertFalse(SceneScriptPermissions.restored(reconverted, path: path).scripts[0].isAuthorized)
        }
    }
}

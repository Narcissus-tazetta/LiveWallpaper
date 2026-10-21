import XCTest

@testable import LiveWallpaper

@MainActor
final class WebDisplayOverrideTests: XCTestCase {
    private let keys = [
        PrefsKey.webOverrideByScreenID,
        PrefsKey.videoOverrideByScreenID,
    ]
    private var previousValues: [String: Any] = [:]
    private var videoURL: URL!

    override func setUpWithError() throws {
        for key in keys {
            previousValues[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        videoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("web-override-\(UUID().uuidString).mov")
        try Data("test".utf8).write(to: videoURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: videoURL)
        for key in keys {
            if let value = previousValues[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    private func makeModel() -> (WallpaperModel, WebWallpaperSource) {
        let model = WallpaperModel()
        let source = WebWallpaperSource(url: URL(string: "https://example.com/a")!)
        model.webWallpaperFeatureEnabled = true
        model.webWallpaperSources = [source]
        return (model, source)
    }

    func testOverrideMakesScreenWebAndNotSharedPlayerDisplay() {
        let (model, source) = makeModel()
        model.setWebOverride(id: source.id, forScreenID: "screen-2")

        XCTAssertEqual(model.webSource(forScreenID: "screen-2")?.id, source.id)
        XCTAssertFalse(model.isSharedPlayerDisplay("screen-2"))
        XCTAssertNil(model.webSource(forScreenID: "screen-1"))
        XCTAssertTrue(model.isSharedPlayerDisplay("screen-1"))
    }

    func testOverrideIsIgnoredWhileWebFeatureIsOff() {
        let (model, source) = makeModel()
        model.setWebOverride(id: source.id, forScreenID: "screen-2")
        model.webWallpaperFeatureEnabled = false

        XCTAssertNil(model.webSource(forScreenID: "screen-2"))
        XCTAssertTrue(model.isSharedPlayerDisplay("screen-2"))
    }

    func testUnknownSourceIsRejected() {
        let (model, _) = makeModel()
        model.setWebOverride(id: UUID(), forScreenID: "screen-2")

        XCTAssertTrue(model.webOverrideByScreenID.isEmpty)
    }

    func testVideoAssignmentReplacesWebOverrideOnSameScreen() {
        let (model, source) = makeModel()
        model.setWebOverride(id: source.id, forScreenID: "screen-2")
        model.setVideoOverride(path: videoURL.path, forScreenID: "screen-2")

        XCTAssertNil(model.webOverrideByScreenID["screen-2"])
        XCTAssertEqual(model.videoOverride(forScreenID: "screen-2"), videoURL.path)
    }

    func testWebAssignmentReplacesVideoOverrideOnSameScreen() {
        let (model, source) = makeModel()
        model.setVideoOverride(path: videoURL.path, forScreenID: "screen-2")
        model.setWebOverride(id: source.id, forScreenID: "screen-2")

        XCTAssertNil(model.videoOverride(forScreenID: "screen-2"))
        XCTAssertEqual(model.webOverrideByScreenID["screen-2"], source.id)
    }

    func testRemovingSourceClearsItsOverrides() {
        let (model, source) = makeModel()
        model.setWebOverride(id: source.id, forScreenID: "screen-1")
        model.setWebOverride(id: source.id, forScreenID: "screen-2")
        model.removeWebWallpaper(id: source.id)

        XCTAssertTrue(model.webOverrideByScreenID.isEmpty)
    }

    func testOverridesSurviveRelaunch() {
        let (model, source) = makeModel()
        model.setWebOverride(id: source.id, forScreenID: "screen-2")

        let relaunched = WallpaperModel()
        relaunched.webWallpaperFeatureEnabled = true
        relaunched.webWallpaperSources = [source]
        relaunched.restoreWebOverrides()

        XCTAssertEqual(relaunched.webSource(forScreenID: "screen-2")?.id, source.id)
    }

    func testVideoPinStaysDedicatedWhileSharedWallpaperIsWeb() {
        let (model, source) = makeModel()
        model.setVideoOverride(path: videoURL.path, forScreenID: "screen-2")
        model.currentWebWallpaperID = source.id
        model.wallpaperKind = .web

        XCTAssertTrue(model.isWebWallpaperActive)
        XCTAssertEqual(model.resolvedOverridePath(forScreenID: "screen-2"), videoURL.path)
        XCTAssertFalse(model.isSharedPlayerDisplay("screen-2"))
        XCTAssertNil(model.resolvedOverridePath(forScreenID: "screen-1"))
        XCTAssertEqual(model.webSource(forScreenID: "screen-1")?.id, source.id)
    }
}

import XCTest

@testable import LiveWallpaper

@MainActor
final class PinCurrentVideoPersistenceTests: XCTestCase {
    private let keys = [
        PrefsKey.pinCurrentVideo,
        PrefsKey.wallpaperKind,
        PrefsKey.currentWebWallpaperID,
        PrefsKey.wallpaperTransitionDuration,
        PrefsKey.autoSwitchIntervalMinutes,
        PrefsKey.playlistPlaybackEnabled,
        PrefsKey.shufflePlaybackEnabled,
        PrefsKey.libraryVideoPaths,
        PrefsKey.selectedPlaylistID,
        PrefsKey.webWallpaperFeatureEnabled,
        PrefsKey.webWallpaperSourcesData,
    ]
    private var previousValues: [String: Any] = [:]

    override func setUpWithError() throws {
        for key in keys {
            previousValues[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDownWithError() throws {
        for key in keys {
            if let value = previousValues[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    func testPinSurvivesRelaunch() {
        UserDefaults.standard.set(["/a.mp4", "/b.mp4"], forKey: PrefsKey.libraryVideoPaths)
        UserDefaults.standard.set(true, forKey: PrefsKey.playlistPlaybackEnabled)
        let model = WallpaperModel()
        model.setPinCurrentVideo(true)
        XCTAssertTrue(model.pinCurrentVideo)

        let relaunched = WallpaperModel()

        XCTAssertTrue(relaunched.pinCurrentVideo)
    }

    func testUnpinSurvivesRelaunch() {
        UserDefaults.standard.set(["/a.mp4", "/b.mp4"], forKey: PrefsKey.libraryVideoPaths)
        UserDefaults.standard.set(true, forKey: PrefsKey.playlistPlaybackEnabled)
        let model = WallpaperModel()
        model.setPinCurrentVideo(true)
        model.setPinCurrentVideo(false)

        let relaunched = WallpaperModel()

        XCTAssertFalse(relaunched.pinCurrentVideo)
    }

    func testPinSurvivesRelaunchWithMixedQueue() throws {
        UserDefaults.standard.set(["/a.mp4"], forKey: PrefsKey.libraryVideoPaths)
        UserDefaults.standard.set(true, forKey: PrefsKey.playlistPlaybackEnabled)
        UserDefaults.standard.set(true, forKey: PrefsKey.webWallpaperFeatureEnabled)
        let source = WebWallpaperSource(url: URL(string: "https://example.com")!)
        UserDefaults.standard.set(
            try JSONEncoder().encode([source]), forKey: PrefsKey.webWallpaperSourcesData
        )
        let model = WallpaperModel()
        XCTAssertTrue(model.canPinCurrentVideo)
        model.setPinCurrentVideo(true)

        let relaunched = WallpaperModel()

        XCTAssertTrue(relaunched.pinCurrentVideo)
    }

    func testPinIsDroppedWhenQueueIsEmpty() {
        UserDefaults.standard.set(["/a.mp4", "/b.mp4"], forKey: PrefsKey.libraryVideoPaths)
        UserDefaults.standard.set(true, forKey: PrefsKey.playlistPlaybackEnabled)
        let model = WallpaperModel()
        model.setPinCurrentVideo(true)
        UserDefaults.standard.set([String](), forKey: PrefsKey.libraryVideoPaths)

        let relaunched = WallpaperModel()

        XCTAssertFalse(relaunched.pinCurrentVideo)
    }

    func testWebWallpaperCanBePinnedWithoutContinuousPlaybackAndSurvivesRelaunch() throws {
        let source = WebWallpaperSource(url: URL(string: "https://example.com")!)
        UserDefaults.standard.set(true, forKey: PrefsKey.webWallpaperFeatureEnabled)
        UserDefaults.standard.set(try JSONEncoder().encode([source]), forKey: PrefsKey.webWallpaperSourcesData)
        UserDefaults.standard.set(WallpaperKind.web.rawValue, forKey: PrefsKey.wallpaperKind)
        UserDefaults.standard.set(source.id.uuidString, forKey: PrefsKey.currentWebWallpaperID)
        let model = WallpaperModel()
        XCTAssertFalse(model.playlistPlaybackEnabled)
        XCTAssertTrue(model.canPinCurrentVideo)

        model.setPinCurrentVideo(true)
        model.setPlaylistPlaybackEnabled(true)
        model.setPlaylistPlaybackEnabled(false)
        let relaunched = WallpaperModel()

        XCTAssertTrue(model.pinCurrentVideo)
        XCTAssertTrue(relaunched.pinCurrentVideo)
        XCTAssertEqual(relaunched.currentPlaybackEntry, .web(source.id))
        XCTAssertEqual(relaunched.playbackEndBehavior(), .loopCurrent)
    }

    func testSelectingAnotherWebWallpaperClearsPinButReselectingDoesNot() throws {
        let sources = ["https://example.com/a", "https://example.com/b"].map {
            WebWallpaperSource(url: URL(string: $0)!)
        }
        UserDefaults.standard.set(true, forKey: PrefsKey.webWallpaperFeatureEnabled)
        UserDefaults.standard.set(try JSONEncoder().encode(sources), forKey: PrefsKey.webWallpaperSourcesData)
        UserDefaults.standard.set(WallpaperKind.web.rawValue, forKey: PrefsKey.wallpaperKind)
        UserDefaults.standard.set(sources[0].id.uuidString, forKey: PrefsKey.currentWebWallpaperID)
        UserDefaults.standard.set(0, forKey: PrefsKey.wallpaperTransitionDuration)
        let model = WallpaperModel()
        model.setPinCurrentVideo(true)
        model.selectWebWallpaper(id: sources[0].id)
        XCTAssertTrue(model.pinCurrentVideo)

        model.selectWebWallpaper(id: sources[1].id)

        XCTAssertFalse(model.pinCurrentVideo)
        XCTAssertEqual(model.currentPlaybackEntry, .web(sources[1].id))
    }

    func testPinPreventsTimerSwitchUntilReleased() throws {
        let sources = ["https://example.com/a", "https://example.com/b"].map {
            WebWallpaperSource(url: URL(string: $0)!)
        }
        UserDefaults.standard.set(true, forKey: PrefsKey.webWallpaperFeatureEnabled)
        UserDefaults.standard.set(try JSONEncoder().encode(sources), forKey: PrefsKey.webWallpaperSourcesData)
        UserDefaults.standard.set(WallpaperKind.web.rawValue, forKey: PrefsKey.wallpaperKind)
        UserDefaults.standard.set(sources[0].id.uuidString, forKey: PrefsKey.currentWebWallpaperID)
        UserDefaults.standard.set(0, forKey: PrefsKey.wallpaperTransitionDuration)
        let model = WallpaperModel()
        model.scheduleRules = []
        model.displayIDByWindow[ObjectIdentifier(model)] = "pin-test-display"
        model.setAutoSwitchInterval(minutes: 5)
        let timer = try XCTUnwrap(model.autoSwitchTimer)
        defer { timer.invalidate() }

        model.setPinCurrentVideo(true)
        timer.fire()
        XCTAssertEqual(model.currentPlaybackEntry, .web(sources[0].id))

        model.setPinCurrentVideo(false)
        timer.fire()
        XCTAssertEqual(model.currentPlaybackEntry, .web(sources[1].id))
    }

}

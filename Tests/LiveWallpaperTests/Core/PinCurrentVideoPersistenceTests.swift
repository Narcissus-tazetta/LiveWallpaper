import XCTest

@testable import LiveWallpaper

/// 「この動画で固定」が再起動(WallpaperModel の作り直し)をまたいで残るかを検証する。
@MainActor
final class PinCurrentVideoPersistenceTests: XCTestCase {
    private let keys = [
        PrefsKey.pinCurrentVideo,
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

    /// 1本の動画 + Web壁紙で2エントリになるキュー。起動途中の同期は Web壁紙の
    /// 機能フラグ復元前に走るため、そこで固定が消されないことを確かめる。
    func testPinSurvivesRelaunchWhenQueueNeedsWebWallpaperToReachTwoEntries() throws {
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

    func testPinIsDroppedWhenQueueNoLongerAllowsIt() {
        UserDefaults.standard.set(["/a.mp4", "/b.mp4"], forKey: PrefsKey.libraryVideoPaths)
        UserDefaults.standard.set(true, forKey: PrefsKey.playlistPlaybackEnabled)
        let model = WallpaperModel()
        model.setPinCurrentVideo(true)
        UserDefaults.standard.set(["/a.mp4"], forKey: PrefsKey.libraryVideoPaths)

        let relaunched = WallpaperModel()

        XCTAssertFalse(relaunched.pinCurrentVideo)
    }
}

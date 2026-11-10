@testable import LiveWallpaper
import XCTest

@MainActor
final class AutoSwitchFocusTests: XCTestCase {
    func testDisablingFocusIntegrationLetsTheAutoSwitchTimerAdvance() throws {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        let paths = ["first.mp4", "second.mp4"].map { folder.appendingPathComponent($0).path }
        for path in paths {
            try Data("video".utf8).write(to: URL(fileURLWithPath: path))
        }
        let model = WallpaperModel()
        model.wallpaperTransitionDuration = 0
        model.libraryVideoPaths = paths
        model.selectedPlaylistID = nil
        model.syncActivePlaylistPaths()
        model.videoOverrideByScreenID = [:]
        model.spaceWallpaperFeatureEnabled = false
        model.suspendedDisplayIDs = []
        model.isDeepSuspended = false
        model.pinCurrentVideo = false
        model.shufflePlaybackEnabled = false
        model.scheduleRules = []
        model.selectRegisteredVideo(path: paths[0])
        model.applyFocusFilterState(target: .video(paths[0]))
        model.setFocusFilterIntegrationEnabled(true)
        model.setAutoSwitchInterval(minutes: 1)
        defer {
            model.setAutoSwitchInterval(minutes: 0)
            model.applyFocusFilterState(target: nil)
        }
        XCTAssertFalse(model.sharedPlayerDisplayIDs(among: model.allWallpaperDisplayIDs()).isEmpty)
        let timer = try XCTUnwrap(model.autoSwitchTimer)
        timer.fire()
        XCTAssertEqual(model.currentVideoPath, paths[0])

        model.setFocusFilterIntegrationEnabled(false)
        model.isDeepSuspended = false
        model.suspendedDisplayIDs = []
        timer.fire()
        XCTAssertEqual(model.currentVideoPath, paths[1])
    }
}

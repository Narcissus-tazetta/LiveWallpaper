import XCTest
@testable import LiveWallpaper

@MainActor
final class PlaybackPolicyTests: XCTestCase {
    private typealias Behavior = WallpaperModel.PlaybackEndBehavior

    func testSingleEntryAlwaysLoops() {
        XCTAssertEqual(
            WallpaperModel.playbackEndBehavior(
                entryCount: 1,
                pinCurrentVideo: false,
                playlistPlaybackEnabled: true,
                videoLoopEnabled: false
            ),
            Behavior.loopCurrent
        )
    }

    func testPinnedVideoLoopsRegardlessOfOtherSettings() {
        XCTAssertEqual(
            WallpaperModel.playbackEndBehavior(
                entryCount: 5,
                pinCurrentVideo: true,
                playlistPlaybackEnabled: true,
                videoLoopEnabled: false
            ),
            Behavior.loopCurrent
        )
    }

    func testPlaylistPlaybackAdvancesWhenNotPinned() {
        XCTAssertEqual(
            WallpaperModel.playbackEndBehavior(
                entryCount: 3,
                pinCurrentVideo: false,
                playlistPlaybackEnabled: true,
                videoLoopEnabled: false
            ),
            Behavior.advancePlaylist
        )
    }

    func testVideoLoopEnabledWinsOverAdvanceWhenNoPlaylist() {
        XCTAssertEqual(
            WallpaperModel.playbackEndBehavior(
                entryCount: 3,
                pinCurrentVideo: false,
                playlistPlaybackEnabled: false,
                videoLoopEnabled: true
            ),
            Behavior.loopCurrent
        )
    }

    func testPlaysOnceWhenNoLoopNoPlaylistNoPin() {
        XCTAssertEqual(
            WallpaperModel.playbackEndBehavior(
                entryCount: 3,
                pinCurrentVideo: false,
                playlistPlaybackEnabled: false,
                videoLoopEnabled: false
            ),
            Behavior.playOnce
        )
    }
}

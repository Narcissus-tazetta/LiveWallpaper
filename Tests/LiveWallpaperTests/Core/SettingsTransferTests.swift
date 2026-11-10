@testable import LiveWallpaper
import XCTest

@MainActor
final class SettingsTransferTests: XCTestCase {
    private var directory: URL!
    private var savedPreferences: [String: Any]?
    private let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName

    override func setUpWithError() throws {
        savedPreferences = UserDefaults.standard.persistentDomain(forName: domain)
        UserDefaults.standard.removePersistentDomain(forName: domain)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.setPersistentDomain(savedPreferences ?? [:], forName: domain)
        try FileManager.default.removeItem(at: directory)
    }

    private func modelWithAssignments() throws -> WallpaperModel {
        let video = directory.appendingPathComponent("video.mp4")
        try Data("video".utf8).write(to: video)
        let model = WallpaperModel()
        model.wallpaperTransitionDuration = 0
        model.libraryVideoPaths = [video.path]
        model.syncActivePlaylistPaths()
        let playlist = try XCTUnwrap(model.createPlaylist(named: "test"))
        for screen in ["keep", "remove"] {
            model.setVideoOverride(path: video.path, forScreenID: screen)
            model.setSpaceVideo(path: video.path, forSpaceUUID: screen)
            model.setSuspendDisabled(true, forScreenID: screen)
            model.setScreenPlaylist(playlist, forScreenID: screen, autoAssignFirstVideo: false)
            model.setWallpaperPresentation(
                fitMode: .fit, zoom: 2, offsetX: 0.1, offsetY: 0.2,
                path: video.path, screenID: screen
            )
        }
        return model
    }

    func testExplicitEmptyCollectionsClearAssignmentsWhenImported() throws {
        let model = try modelWithAssignments()
        var snapshot = SettingsSnapshot()
        snapshot.videoOverrideByScreenID = [:]
        snapshot.videoBySpaceUUID = [:]
        snapshot.screenPlaylistByScreenID = [:]
        snapshot.suspendDisabledDisplayIDs = []
        snapshot.wallpaperPresentationByPath = [:]
        let file = directory.appendingPathComponent("settings.json")
        try JSONEncoder().encode(snapshot).write(to: file)

        try SettingsTransfer.importSettings(from: file, into: model)

        XCTAssertTrue(model.videoOverrideByScreenID.isEmpty)
        XCTAssertTrue(model.videoBySpaceUUID.isEmpty)
        XCTAssertTrue(model.screenPlaylistByScreenID.isEmpty)
        XCTAssertTrue(model.suspendDisabledDisplayIDs.isEmpty)
        XCTAssertTrue(model.wallpaperPresentationByPath.isEmpty)
    }

    func testRestoreRemovesOnlyEntriesMissingFromTheSnapshot() throws {
        let model = try modelWithAssignments()
        var snapshot = SettingsTransfer.snapshot(from: model)
        snapshot.videoOverrideByScreenID?.removeValue(forKey: "remove")
        snapshot.videoBySpaceUUID?.removeValue(forKey: "remove")
        snapshot.screenPlaylistByScreenID?.removeValue(forKey: "remove")
        snapshot.suspendDisabledDisplayIDs = ["keep"]
        let path = try XCTUnwrap(model.libraryVideoPaths.first)
        snapshot.wallpaperPresentationByPath?[path]?.removeValue(forKey: "remove")

        SettingsTransfer.apply(snapshot, to: model)

        XCTAssertEqual(Set(model.videoOverrideByScreenID.keys), ["keep"])
        XCTAssertEqual(Set(model.videoBySpaceUUID.keys), ["keep"])
        XCTAssertEqual(Set(model.screenPlaylistByScreenID.keys), ["keep"])
        XCTAssertEqual(model.suspendDisabledDisplayIDs, ["keep"])
        XCTAssertEqual(Set(model.wallpaperPresentationByPath[path]?.keys ?? [:].keys), ["keep"])
        XCTAssertEqual(model.wallpaperZoom(path: path, screenID: "keep"), 2)
    }

    func testAbsentCollectionsLeaveExistingAssignmentsUntouched() throws {
        let model = try modelWithAssignments()
        let before = SettingsTransfer.snapshot(from: model)

        SettingsTransfer.apply(SettingsSnapshot(), to: model)

        XCTAssertEqual(model.videoOverrideByScreenID, before.videoOverrideByScreenID)
        XCTAssertEqual(model.videoBySpaceUUID, before.videoBySpaceUUID)
        XCTAssertEqual(
            model.screenPlaylistByScreenID.mapValues(\.uuidString),
            before.screenPlaylistByScreenID
        )
        XCTAssertEqual(
            model.suspendDisabledDisplayIDs,
            try Set(XCTUnwrap(before.suspendDisabledDisplayIDs))
        )
        XCTAssertEqual(model.wallpaperPresentationByPath, before.wallpaperPresentationByPath)
    }
}

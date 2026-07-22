import XCTest

@testable import LiveWallpaper

/// wallpaperEditByPath の永続化(restoreState でのデコード)と、ライブラリから消えた
/// パスの間引き(pruneWallpaperEditsForExistingPaths)を検証する。
/// WallpaperModel.init() は restoreState() を自動で呼ぶため(WallpaperModel.swift:321)、
/// UserDefaults を先に仕込んでからモデルを構築するだけで復元経路を通せる。
@MainActor
final class WallpaperModelEditPersistenceTests: XCTestCase {
    private let editKey = "wallpaperEditByPath"
    private let libraryKey = "libraryVideoPaths"
    private var previousEditData: Data?
    private var previousLibraryPaths: [String]?

    override func setUpWithError() throws {
        previousEditData = UserDefaults.standard.data(forKey: editKey)
        previousLibraryPaths = UserDefaults.standard.stringArray(forKey: libraryKey)
    }

    override func tearDownWithError() throws {
        if let previousEditData {
            UserDefaults.standard.set(previousEditData, forKey: editKey)
        } else {
            UserDefaults.standard.removeObject(forKey: editKey)
        }
        if let previousLibraryPaths {
            UserDefaults.standard.set(previousLibraryPaths, forKey: libraryKey)
        } else {
            UserDefaults.standard.removeObject(forKey: libraryKey)
        }
    }

    func testRestoreStateDecodesWallpaperEditByPath() throws {
        UserDefaults.standard.set(["/a.mp4", "/b.mp4"], forKey: libraryKey)
        let edits: [String: WallpaperEditMetadata] = [
            "/a.mp4": WallpaperEditMetadata(trimStart: 2, trimEnd: 8, loopStart: 4)
        ]
        UserDefaults.standard.set(try JSONEncoder().encode(edits), forKey: editKey)

        let model = WallpaperModel()

        XCTAssertEqual(model.wallpaperEditByPath, edits)
    }

    func testRestoreStateDropsEditsForPathsNotInLibrary() throws {
        UserDefaults.standard.set(["/a.mp4"], forKey: libraryKey)
        let edits: [String: WallpaperEditMetadata] = [
            "/a.mp4": WallpaperEditMetadata(trimStart: 1, trimEnd: 5, loopStart: nil),
            "/stale.mp4": WallpaperEditMetadata(trimStart: 1, trimEnd: 5, loopStart: nil),
        ]
        UserDefaults.standard.set(try JSONEncoder().encode(edits), forKey: editKey)

        let model = WallpaperModel()

        XCTAssertEqual(model.wallpaperEditByPath, ["/a.mp4": edits["/a.mp4"]!])
    }

    func testPruneRemovesEditsForPathsNoLongerInLibrary() {
        UserDefaults.standard.removeObject(forKey: libraryKey)
        UserDefaults.standard.removeObject(forKey: editKey)
        let model = WallpaperModel()

        model.libraryVideoPaths = ["/a.mp4"]
        model.wallpaperEditByPath = [
            "/a.mp4": WallpaperEditMetadata(trimStart: 1, trimEnd: 5, loopStart: nil),
            "/gone.mp4": WallpaperEditMetadata(trimStart: 1, trimEnd: 5, loopStart: nil),
        ]

        model.pruneWallpaperEditsForExistingPaths()

        XCTAssertEqual(Array(model.wallpaperEditByPath.keys), ["/a.mp4"])
    }

    func testPruneIsNoOpWhenNothingIsStale() {
        UserDefaults.standard.removeObject(forKey: libraryKey)
        UserDefaults.standard.removeObject(forKey: editKey)
        let model = WallpaperModel()

        model.libraryVideoPaths = ["/a.mp4"]
        let edits: [String: WallpaperEditMetadata] = [
            "/a.mp4": WallpaperEditMetadata(trimStart: 1, trimEnd: 5, loopStart: nil)
        ]
        model.wallpaperEditByPath = edits

        model.pruneWallpaperEditsForExistingPaths()

        XCTAssertEqual(model.wallpaperEditByPath, edits)
    }
}

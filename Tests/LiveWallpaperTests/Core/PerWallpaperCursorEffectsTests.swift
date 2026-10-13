import XCTest

@testable import LiveWallpaper

@MainActor
final class PerWallpaperCursorEffectsTests: XCTestCase {
    private let path = "/tmp/per-wallpaper-effects.mov"

    override func setUp() {
        super.setUp()
        Self.wipePersistentDefaults()
    }

    override func tearDown() {
        Self.wipePersistentDefaults()
        super.tearDown()
    }

    private static func wipePersistentDefaults() {
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        UserDefaults.standard.removePersistentDomain(forName: domain)
    }

    private var sparkleTrail: CursorEffectsSettings {
        var settings = CursorEffectsSettings()
        settings.trailEnabled = true
        settings.trailShape = .sparkle
        return settings
    }

    func testAWallpaperWithoutItsOwnSettingsFollowsTheAppWideOnes() {
        let model = WallpaperModel()
        model.currentVideoPath = path
        var appWide = CursorEffectsSettings()
        appWide.spotlightEnabled = true
        model.setCursorEffects(appWide)
        XCTAssertEqual(model.effectiveCursorEffects(forDisplayID: "1"), appWide)
    }

    func testAWallpapersOwnSettingsWinButNotTheDesktopOnlySwitch() {
        let model = WallpaperModel()
        model.currentVideoPath = path
        var appWide = CursorEffectsSettings()
        appWide.onlyWhileDesktopActive = false
        model.setCursorEffects(appWide)
        model.setCursorEffectsOverride(sparkleTrail, path: path)

        let effective = model.effectiveCursorEffects(forDisplayID: "1")
        XCTAssertTrue(effective.trailEnabled)
        XCTAssertEqual(effective.trailShape, .sparkle)
        XCTAssertFalse(effective.onlyWhileDesktopActive)

        model.setCursorEffectsOverride(nil, path: path)
        XCTAssertEqual(model.effectiveCursorEffects(forDisplayID: "1"), appWide)
    }

    func testOwnSettingsPersistAndGoAwayWithTheWallpaper() {
        // Settings for paths outside the library are pruned at launch, like trim edits.
        UserDefaults.standard.set([path], forKey: PrefsKey.libraryVideoPaths)
        let model = WallpaperModel()
        model.setCursorEffectsOverride(sparkleTrail, path: path)
        XCTAssertEqual(WallpaperModel().cursorEffectsOverride(path: path), sparkleTrail)

        model.libraryVideoPaths = []
        model.pruneWallpaperEditsForExistingPaths()
        XCTAssertNil(model.cursorEffectsOverride(path: path))
        XCTAssertNil(WallpaperModel().cursorEffectsOverride(path: path))
    }

    // MARK: - Packages

    private func video(cursorEffects: CursorEffectsSettings?) -> PackageManifest.PackageVideo {
        PackageManifest.PackageVideo(
            id: "video-1",
            source: .init(fileName: "clip.mp4", size: 1024),
            displayName: "Clip",
            sha256: nil,
            thumbnail: nil,
            presentations: [:],
            cursorEffects: cursorEffects
        )
    }

    func testPackagesCarryTheSettings() throws {
        let data = try JSONEncoder().encode(video(cursorEffects: sparkleTrail))
        let decoded = try JSONDecoder().decode(PackageManifest.PackageVideo.self, from: data)
        XCTAssertEqual(decoded.cursorEffects, sparkleTrail)
    }

    func testPackagesWithoutTheSettingsStillDecode() throws {
        let data = try JSONEncoder().encode(video(cursorEffects: nil))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("cursorEffects"))
        XCTAssertNil(try JSONDecoder().decode(PackageManifest.PackageVideo.self, from: data).cursorEffects)
    }

    /// A package from a newer version may use a shape this one does not know; only that
    /// field falls back, and the package still imports.
    func testUnknownValuesFallBackPerField() throws {
        let json = #"{"trailEnabled":true,"trailShape":"laser","trailAmount":"high"}"#
        let settings = try JSONDecoder().decode(CursorEffectsSettings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.trailEnabled)
        XCTAssertEqual(settings.trailShape, .glow)
        XCTAssertEqual(settings.trailAmount, .high)
    }

    func testOutOfRangeColoursAreClamped() {
        let color = RGBAColor(red: 4, green: -1, blue: .nan, alpha: 1).nsColor
        XCTAssertEqual(color.redComponent, 1)
        XCTAssertEqual(color.greenComponent, 0)
        XCTAssertEqual(color.blueComponent, 1)
    }

    func testEditsUndoBackToFollowingTheAppWideSettings() {
        let model = WallpaperModel()
        model.editCursorEffectsOverride(CursorEffectsSettings(), path: path, coalescingKey: nil)
        model.editCursorEffectsOverride(sparkleTrail, path: path, coalescingKey: "trail")

        model.undoCursorEffects(path: path)
        XCTAssertEqual(model.cursorEffectsOverride(path: path), CursorEffectsSettings())
        model.undoCursorEffects(path: path)
        XCTAssertNil(model.cursorEffectsOverride(path: path))
        XCTAssertFalse(model.canUndoCursorEffects(path: path))

        model.redoCursorEffects(path: path)
        model.redoCursorEffects(path: path)
        XCTAssertEqual(model.cursorEffectsOverride(path: path), sparkleTrail)
    }

    func testOneDraggedValueIsOneStep() {
        let model = WallpaperModel()
        model.editCursorEffectsOverride(CursorEffectsSettings(), path: path, coalescingKey: nil)
        model.breakCursorEffectsHistoryCoalescing()
        for red in [0.2, 0.4, 0.6] {
            var settings = CursorEffectsSettings()
            settings.trailCustomColor = RGBAColor(red: red, green: 0, blue: 0, alpha: 1)
            model.editCursorEffectsOverride(settings, path: path, coalescingKey: "colour")
        }
        model.undoCursorEffects(path: path)
        XCTAssertEqual(model.cursorEffectsOverride(path: path), CursorEffectsSettings())
    }
}

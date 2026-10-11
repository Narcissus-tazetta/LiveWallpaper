import XCTest

@testable import LiveWallpaper

@MainActor
final class CursorEffectsTests: XCTestCase {
    private let screen = CGSize(width: 2000, height: 1000)

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

    // MARK: - Parallax geometry

    func testCentreDoesNotMove() {
        let offset = CursorEffectGeometry.parallaxOffset(
            cursor: CGPoint(x: 1000, y: 500), screenSize: screen, amplitude: 0.02
        )
        XCTAssertEqual(offset, .zero)
    }

    func testEdgesMoveTheFullAmountAgainstTheCursor() {
        let topRight = CursorEffectGeometry.parallaxOffset(
            cursor: CGPoint(x: 2000, y: 1000), screenSize: screen, amplitude: 0.02
        )
        XCTAssertEqual(topRight.width, -40, accuracy: 1e-9)
        XCTAssertEqual(topRight.height, -20, accuracy: 1e-9)
        let bottomLeft = CursorEffectGeometry.parallaxOffset(
            cursor: .zero, screenSize: screen, amplitude: 0.02
        )
        XCTAssertEqual(bottomLeft.width, 40, accuracy: 1e-9)
        XCTAssertEqual(bottomLeft.height, 20, accuracy: 1e-9)
    }

    func testPositionsPastTheEdgeAreClamped() {
        let past = CursorEffectGeometry.parallaxOffset(
            cursor: CGPoint(x: 5000, y: -3000), screenSize: screen, amplitude: 0.02
        )
        XCTAssertEqual(past.width, -40, accuracy: 1e-9)
        XCTAssertEqual(past.height, 20, accuracy: 1e-9)
    }

    /// Scaled about the centre, the content overhangs each edge by exactly the largest shift.
    func testScaleCoversTheLargestShift() {
        let amplitude: CGFloat = 0.03
        let scale = CursorEffectGeometry.parallaxScale(amplitude: amplitude)
        let overhang = (screen.width * scale - screen.width) / 2
        XCTAssertEqual(overhang, amplitude * screen.width, accuracy: 1e-9)
    }

    // MARK: - Stored settings

    func testSettingsSavedBeforeAnEffectExistedStillLoad() throws {
        let json = Data(#"{"parallaxEnabled":true}"#.utf8)
        let settings = try JSONDecoder().decode(CursorEffectsSettings.self, from: json)
        XCTAssertTrue(settings.parallaxEnabled)
        XCTAssertFalse(settings.trailEnabled)
        XCTAssertEqual(settings.trailColor, .white)
    }

    func testSettingsRoundTrip() throws {
        var settings = CursorEffectsSettings()
        settings.trailEnabled = true
        settings.trailColor = .custom
        settings.trailCustomColor = RGBAColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let decoded = try JSONDecoder().decode(CursorEffectsSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    func testSettingsPersistAcrossLaunches() {
        var settings = CursorEffectsSettings()
        settings.spotlightEnabled = true
        settings.spotlightSize = .high
        WallpaperModel().setCursorEffects(settings)
        XCTAssertEqual(WallpaperModel().cursorEffects, settings)
    }

    // MARK: - When effects turn off

    func testBatteryReduceLoadStopsMotionButNotTheSpotlight() {
        let model = WallpaperModel()
        model.batteryPlaybackPolicy = .reduceLoad
        model.isOnBatteryPower = true
        XCTAssertEqual(model.cursorMotionBlockReason, .battery)
        XCTAssertNil(model.cursorSpotlightBlockReason)

        model.isOnBatteryPower = false
        XCTAssertNil(model.cursorMotionBlockReason)
    }

    func testBatteryNormalPolicyKeepsMotion() {
        let model = WallpaperModel()
        model.batteryPlaybackPolicy = .normal
        model.isOnBatteryPower = true
        XCTAssertNil(model.cursorMotionBlockReason)
    }

    func testReduceMotionStopsMotionOnlyWhenRespected() {
        let model = WallpaperModel()
        model.systemReduceMotionEnabled = true
        model.respectReduceMotionEnabled = true
        XCTAssertEqual(model.cursorMotionBlockReason, .reduceMotion)
        XCTAssertNil(model.cursorSpotlightBlockReason)

        model.respectReduceMotionEnabled = false
        XCTAssertNil(model.cursorMotionBlockReason)
    }
}

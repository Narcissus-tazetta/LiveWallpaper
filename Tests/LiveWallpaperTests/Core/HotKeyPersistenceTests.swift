import Foundation
@testable import LiveWallpaper
import XCTest

@MainActor
final class HotKeyPersistenceTests: XCTestCase {
    private let keys = ["hotKeyCombos", "hotKeyDisabledActions"]
    private var saved: [String: Any] = [:]

    override func setUpWithError() throws {
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDownWithError() throws {
        for key in keys {
            if let value = saved[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    func testExplicitlyUnassignedHotKeyStaysUnassignedAfterRestore() {
        let model = WallpaperModel()
        model.restoreHotKeysState()
        model.setHotKeyCombo(nil, for: .togglePause)
        model.restoreHotKeysState()
        XCTAssertNil(model.hotKeyCombo(for: .togglePause))
        XCTAssertEqual(
            model.hotKeyCombo(for: .nextWallpaper),
            HotKeyAction.nextWallpaper.defaultCombo
        )
    }

    func testConflictingAssignmentRemainsRemovedAfterRestore() {
        let model = WallpaperModel()
        model.restoreHotKeysState()
        let custom = HotKeyCombo(
            keyCode: 0,
            carbonModifiers: HotKeyAction.togglePause.defaultCombo.carbonModifiers
        )
        model.setHotKeyCombo(custom, for: .togglePause)
        model.setHotKeyCombo(custom, for: .toggleAudio)
        model.restoreHotKeysState()
        XCTAssertNil(model.hotKeyCombo(for: .togglePause))
        XCTAssertEqual(model.hotKeyCombo(for: .toggleAudio), custom)
    }

    func testOlderBindingsGetNewDefaultsWithoutTakingAnExistingShortcut() throws {
        let model = WallpaperModel()
        let legacy = [HotKeyAction.toggleAudio.rawValue: HotKeyAction.togglePause.defaultCombo]
        try UserDefaults.standard.set(JSONEncoder().encode(legacy), forKey: "hotKeyCombos")
        model.restoreHotKeysState()
        XCTAssertNil(model.hotKeyCombo(for: .togglePause))
        XCTAssertEqual(model.hotKeyCombo(for: .toggleAudio), HotKeyAction.togglePause.defaultCombo)
        XCTAssertEqual(
            model.hotKeyCombo(for: .nextWallpaper),
            HotKeyAction.nextWallpaper.defaultCombo
        )
    }
}

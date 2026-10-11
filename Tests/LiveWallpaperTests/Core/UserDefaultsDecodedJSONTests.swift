import XCTest

@testable import LiveWallpaper

final class UserDefaultsDecodedJSONTests: XCTestCase {
    private let suiteName = "UserDefaultsDecodedJSONTests"
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDecodesStoredValue() throws {
        defaults.set(try JSONEncoder().encode(["a": 1]), forKey: "k")

        XCTAssertEqual(defaults.decodedJSON([String: Int].self, forKey: "k"), ["a": 1])
        XCTAssertNil(defaults.data(forKey: "k.unreadable"))
    }

    func testMissingKeyReturnsNilWithoutBackup() {
        XCTAssertNil(defaults.decodedJSON([String: Int].self, forKey: "k"))
        XCTAssertNil(defaults.data(forKey: "k.unreadable"))
    }

    func testUnreadableValueIsBackedUpBeforeItCanBeOverwritten() {
        let unreadable = Data("not json".utf8)
        defaults.set(unreadable, forKey: "k")

        XCTAssertNil(defaults.decodedJSON([String: Int].self, forKey: "k"))
        XCTAssertEqual(defaults.data(forKey: "k.unreadable"), unreadable)
    }
}

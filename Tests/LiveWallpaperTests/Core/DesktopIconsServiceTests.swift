import XCTest
@testable import LiveWallpaper

final class DesktopIconsServiceTests: XCTestCase {
    func testMissingKeyDefaultsToVisible() {
        let service = DesktopIconsService(
            readPreference: { _, _ in nil },
            writePreference: { _ in true },
            restartFinder: {}
        )

        XCTAssertTrue(service.isDesktopIconsVisible())
    }

    func testReadsFalsePreference() {
        let service = DesktopIconsService(
            readPreference: { _, _ in false },
            writePreference: { _ in true },
            restartFinder: {}
        )

        XCTAssertFalse(service.isDesktopIconsVisible())
    }

    func testReadsTruePreference() {
        let service = DesktopIconsService(
            readPreference: { _, _ in true },
            writePreference: { _ in true },
            restartFinder: {}
        )

        XCTAssertTrue(service.isDesktopIconsVisible())
    }

    func testBoolFromPreferenceValueReadsCFBooleanFalse() {
        XCTAssertEqual(
            DesktopIconsService.boolFromPreferenceValue(kCFBooleanFalse),
            false
        )
    }

    func testBoolFromPreferenceValueReadsCFBooleanTrue() {
        XCTAssertEqual(
            DesktopIconsService.boolFromPreferenceValue(kCFBooleanTrue),
            true
        )
    }

    func testBoolFromPreferenceValueReadsNSNumber() {
        XCTAssertEqual(
            DesktopIconsService.boolFromPreferenceValue(NSNumber(value: 0)),
            false
        )
        XCTAssertEqual(
            DesktopIconsService.boolFromPreferenceValue(NSNumber(value: 1)),
            true
        )
    }

    func testSetVisibleWritesPreferenceAndRestartsFinder() throws {
        var writtenValue: Bool?
        var restartCount = 0
        let service = DesktopIconsService(
            readPreference: { _, _ in false },
            writePreference: { visible in
                writtenValue = visible
                return true
            },
            restartFinder: {
                restartCount += 1
            }
        )

        try service.setDesktopIconsVisible(true)

        XCTAssertEqual(writtenValue, true)
        XCTAssertEqual(restartCount, 1)
    }

    func testSetHiddenWritesPreferenceAndRestartsFinder() throws {
        var writtenValue: Bool?
        var restartCount = 0
        let service = DesktopIconsService(
            readPreference: { _, _ in true },
            writePreference: { visible in
                writtenValue = visible
                return true
            },
            restartFinder: {
                restartCount += 1
            }
        )

        try service.setDesktopIconsVisible(false)

        XCTAssertEqual(writtenValue, false)
        XCTAssertEqual(restartCount, 1)
    }

    func testSetSkipsWhenValueUnchanged() throws {
        var writeCount = 0
        var restartCount = 0
        let service = DesktopIconsService(
            readPreference: { _, _ in true },
            writePreference: { _ in
                writeCount += 1
                return true
            },
            restartFinder: {
                restartCount += 1
            }
        )

        try service.setDesktopIconsVisible(true)

        XCTAssertEqual(writeCount, 0)
        XCTAssertEqual(restartCount, 0)
    }

    func testSetThrowsWhenWriteFails() {
        let service = DesktopIconsService(
            readPreference: { _, _ in true },
            writePreference: { _ in false },
            restartFinder: {
                XCTFail("Finder should not restart when write fails")
            }
        )

        XCTAssertThrowsError(try service.setDesktopIconsVisible(false)) { error in
            XCTAssertEqual(error as? DesktopIconsError, .preferencesWriteFailed)
        }
    }

    func testSetRevertsPreferenceWhenRestartFails() {
        var writeCalls: [Bool] = []
        let service = DesktopIconsService(
            readPreference: { _, _ in true },
            writePreference: { visible in
                writeCalls.append(visible)
                return true
            },
            restartFinder: {
                throw DesktopIconsError.finderRestartFailed
            }
        )

        XCTAssertThrowsError(try service.setDesktopIconsVisible(false)) { error in
            XCTAssertEqual(error as? DesktopIconsError, .finderRestartFailed)
        }
        XCTAssertEqual(writeCalls, [false, true])
    }
}

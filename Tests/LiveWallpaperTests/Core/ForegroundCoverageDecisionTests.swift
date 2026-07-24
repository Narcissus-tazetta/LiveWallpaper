import XCTest
@testable import LiveWallpaper

@MainActor
final class ForegroundCoverageDecisionTests: XCTestCase {
    func testNoSuspensionWithoutEligibleFrontmostApp() {
        XCTAssertEqual(
            WallpaperModel.suspendedDisplayIDs(
                hasEligibleFrontmostApp: false,
                occludedDisplayIDs: ["main"]
            ),
            []
        )
    }

    func testSuspendsOccludedDisplaysWhenFrontmostAppIsEligible() {
        XCTAssertEqual(
            WallpaperModel.suspendedDisplayIDs(
                hasEligibleFrontmostApp: true,
                occludedDisplayIDs: ["main"]
            ),
            ["main"]
        )
    }

    func testNoSuspensionWhenNothingIsOccluded() {
        XCTAssertEqual(
            WallpaperModel.suspendedDisplayIDs(
                hasEligibleFrontmostApp: true,
                occludedDisplayIDs: []
            ),
            []
        )
    }

    func testHighSensitivityCoverageAddsSuspensionOnItsOwn() {
        XCTAssertEqual(
            WallpaperModel.suspendedDisplayIDs(
                hasEligibleFrontmostApp: true,
                occludedDisplayIDs: [],
                highSensitivityCoveredDisplayIDs: ["main"]
            ),
            ["main"]
        )
    }

    func testOcclusionAndHighSensitivitySignalsAreUnioned() {
        XCTAssertEqual(
            WallpaperModel.suspendedDisplayIDs(
                hasEligibleFrontmostApp: true,
                occludedDisplayIDs: ["secondary"],
                highSensitivityCoveredDisplayIDs: ["main"]
            ),
            ["main", "secondary"]
        )
    }

    func testHighSensitivityCoverageIgnoredWithoutEligibleFrontmostApp() {
        XCTAssertEqual(
            WallpaperModel.suspendedDisplayIDs(
                hasEligibleFrontmostApp: false,
                occludedDisplayIDs: [],
                highSensitivityCoveredDisplayIDs: ["main"]
            ),
            []
        )
    }

    func testFrontmostOnlySuspendsRegardlessOfCoverage() {
        XCTAssertEqual(
            WallpaperModel.suspendedDisplayIDs(
                hasEligibleFrontmostApp: true,
                occludedDisplayIDs: [],
                frontmostOnlyDisplayIDs: ["main", "secondary"]
            ),
            ["main", "secondary"]
        )
    }

    func testFrontmostOnlyIgnoredWithoutEligibleFrontmostApp() {
        XCTAssertEqual(
            WallpaperModel.suspendedDisplayIDs(
                hasEligibleFrontmostApp: false,
                occludedDisplayIDs: [],
                frontmostOnlyDisplayIDs: ["main"]
            ),
            []
        )
    }

    func testAllThreeSuspensionSignalsAreUnioned() {
        XCTAssertEqual(
            WallpaperModel.suspendedDisplayIDs(
                hasEligibleFrontmostApp: true,
                occludedDisplayIDs: ["a"],
                highSensitivityCoveredDisplayIDs: ["b"],
                frontmostOnlyDisplayIDs: ["c"]
            ),
            ["a", "b", "c"]
        )
    }

    func testAddsNewSuspensionIsFalseWhenUnchanged() {
        XCTAssertFalse(
            WallpaperModel.addsNewSuspension(current: ["main"], desired: ["main"])
        )
    }

    func testAddsNewSuspensionIsFalseWhenOnlyResuming() {
        XCTAssertFalse(
            WallpaperModel.addsNewSuspension(current: ["main", "secondary"], desired: ["main"])
        )
    }

    func testAddsNewSuspensionIsTrueWhenCoveringNewDisplay() {
        XCTAssertTrue(
            WallpaperModel.addsNewSuspension(current: [], desired: ["main"])
        )
    }

    func testAddsNewSuspensionIsTrueWhenAddingAndRemovingAtOnce() {
        XCTAssertTrue(
            WallpaperModel.addsNewSuspension(current: ["secondary"], desired: ["main"])
        )
    }

    func testAddsNewSuspensionIsFalseWhenBothEmpty() {
        XCTAssertFalse(
            WallpaperModel.addsNewSuspension(current: [], desired: [])
        )
    }
}

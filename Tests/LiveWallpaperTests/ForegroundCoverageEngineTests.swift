import XCTest
@testable import LiveWallpaper

final class ForegroundCoverageEngineTests: XCTestCase {
    private let targetIDs: Set<String> = ["main"]

    func testFrontmostModeIgnoresFinderDesktop() {
        let snapshot = ForegroundCoverageSnapshot(
            app: ForegroundCoverageAppState(
                pid: 100,
                bundleID: "com.apple.finder",
                isFinder: true
            ),
            targetDisplayIDs: targetIDs,
            axProbe: .unavailable,
            cgProbe: .unavailable
        )

        let suspended = ForegroundCoverageEngine.suspendedDisplayIDs(
            mode: .frontmostAppPresence,
            snapshot: snapshot
        )

        XCTAssertTrue(suspended.isEmpty)
    }

    func testPreciseModeStopsForFinderWindowCoverage() {
        let snapshot = ForegroundCoverageSnapshot(
            app: ForegroundCoverageAppState(
                pid: 100,
                bundleID: "com.apple.finder",
                isFinder: true
            ),
            targetDisplayIDs: targetIDs,
            axProbe: .clear,
            cgProbe: .covered(["main"])
        )

        let suspended = ForegroundCoverageEngine.suspendedDisplayIDs(
            mode: .preciseWindowCoverage,
            snapshot: snapshot
        )

        XCTAssertEqual(suspended, ["main"])
    }

    func testPreciseModeFallsBackWhenNonFinderIsUncertain() {
        let snapshot = ForegroundCoverageSnapshot(
            app: ForegroundCoverageAppState(
                pid: 200,
                bundleID: "com.example.editor",
                isFinder: false
            ),
            targetDisplayIDs: targetIDs,
            axProbe: .uncertain,
            cgProbe: .uncertain
        )

        let suspended = ForegroundCoverageEngine.suspendedDisplayIDs(
            mode: .preciseWindowCoverage,
            snapshot: snapshot
        )

        XCTAssertEqual(suspended, targetIDs)
    }

    func testPreciseModeFallsBackWhenAXPermissionIsUnavailableAndCGIsUncertain() {
        let snapshot = ForegroundCoverageSnapshot(
            app: ForegroundCoverageAppState(
                pid: 250,
                bundleID: "com.example.mail",
                isFinder: false
            ),
            targetDisplayIDs: targetIDs,
            axProbe: .uncertain,
            cgProbe: .uncertain
        )

        let suspended = ForegroundCoverageEngine.suspendedDisplayIDs(
            mode: .preciseWindowCoverage,
            snapshot: snapshot
        )

        XCTAssertEqual(suspended, targetIDs)
    }

    func testPreciseModeChecksCGWhenAXIsClear() {
        let snapshot = ForegroundCoverageSnapshot(
            app: ForegroundCoverageAppState(
                pid: 300,
                bundleID: "com.example.browser",
                isFinder: false
            ),
            targetDisplayIDs: targetIDs,
            axProbe: .clear,
            cgProbe: .covered(["main"])
        )

        let suspended = ForegroundCoverageEngine.suspendedDisplayIDs(
            mode: .preciseWindowCoverage,
            snapshot: snapshot
        )

        XCTAssertEqual(suspended, ["main"])
    }

    func testPreciseModeTrustsAXClearOverUncertainCG() {
        let snapshot = ForegroundCoverageSnapshot(
            app: ForegroundCoverageAppState(
                pid: 400,
                bundleID: "com.example.notes",
                isFinder: false
            ),
            targetDisplayIDs: targetIDs,
            axProbe: .clear,
            cgProbe: .uncertain
        )

        let suspended = ForegroundCoverageEngine.suspendedDisplayIDs(
            mode: .preciseWindowCoverage,
            snapshot: snapshot
        )

        XCTAssertTrue(suspended.isEmpty)
    }
}

import CoreGraphics
import XCTest
@testable import LiveWallpaper

final class ForegroundCoverageGeometryTests: XCTestCase {
    func testFullScreenWindowCoversOnlyIntersectingDisplay() {
        let displays = [
            ForegroundCoverageDisplay(
                id: "left",
                frame: CGRect(x: 0, y: 0, width: 1000, height: 800)
            ),
            ForegroundCoverageDisplay(
                id: "right",
                frame: CGRect(x: 1000, y: 0, width: 1000, height: 800)
            )
        ]
        let windows = [
            ForegroundCoverageWindow(
                bounds: CGRect(x: 1000, y: 0, width: 1000, height: 800)
            )
        ]

        let covered = ForegroundCoverageGeometry.coveredDisplayIDs(
            by: windows,
            displays: displays,
            coverageThreshold: 0.9
        )

        XCTAssertEqual(covered, ["right"])
    }

    func testWindowCrossingDisplaysRequiresThresholdPerDisplay() {
        let displays = [
            ForegroundCoverageDisplay(
                id: "left",
                frame: CGRect(x: 0, y: 0, width: 1000, height: 800)
            ),
            ForegroundCoverageDisplay(
                id: "right",
                frame: CGRect(x: 1000, y: 0, width: 1000, height: 800)
            )
        ]
        let windows = [
            ForegroundCoverageWindow(
                bounds: CGRect(x: 100, y: 0, width: 1400, height: 800)
            )
        ]

        let covered = ForegroundCoverageGeometry.coveredDisplayIDs(
            by: windows,
            displays: displays,
            coverageThreshold: 0.9
        )

        XCTAssertEqual(covered, ["left"])
    }

    func testDisplayCanMatchAlternateCoordinateFrame() {
        let displays = [
            ForegroundCoverageDisplay(
                id: "main",
                frames: [
                    CGRect(x: 0, y: 0, width: 1000, height: 800),
                    CGRect(x: 0, y: -800, width: 1000, height: 800)
                ]
            )
        ]
        let windows = [
            ForegroundCoverageWindow(
                bounds: CGRect(x: 0, y: -800, width: 1000, height: 800)
            )
        ]

        let covered = ForegroundCoverageGeometry.coveredDisplayIDs(
            by: windows,
            displays: displays,
            coverageThreshold: 0.9
        )

        XCTAssertEqual(covered, ["main"])
    }

    func testSmallTransparentNegativeLayerAndMiniaturizedWindowsAreIgnored() {
        let displays = [
            ForegroundCoverageDisplay(
                id: "main",
                frame: CGRect(x: 0, y: 0, width: 1000, height: 800)
            )
        ]
        let windows = [
            ForegroundCoverageWindow(
                bounds: CGRect(x: 0, y: 0, width: 1000, height: 800),
                alpha: 0
            ),
            ForegroundCoverageWindow(
                bounds: CGRect(x: 0, y: 0, width: 1000, height: 800),
                layer: -1
            ),
            ForegroundCoverageWindow(
                bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
            ),
            ForegroundCoverageWindow(
                bounds: CGRect(x: 0, y: 0, width: 1000, height: 800),
                isMiniaturized: true
            )
        ]

        let covered = ForegroundCoverageGeometry.coveredDisplayIDs(
            by: windows,
            displays: displays,
            coverageThreshold: 0.9
        )

        XCTAssertTrue(covered.isEmpty)
    }
}

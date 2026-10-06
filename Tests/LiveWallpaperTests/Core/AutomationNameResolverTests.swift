import XCTest
@testable import LiveWallpaper

final class AutomationNameResolverTests: XCTestCase {
    private let candidates: [(id: Int, name: String)] = [
        (id: 1, name: "Ocean.mp4"),
        (id: 2, name: "Ocean Night.mp4"),
        (id: 3, name: "Forest.mov"),
        (id: 4, name: "ＴＯＫＹＯ"),
    ]

    func testExactMatchWinsOverPrefixMatches() {
        XCTAssertEqual(AutomationNameResolver.resolve("ocean.mp4", among: candidates), .unique(1))
    }

    func testUniquePrefixResolvesWithoutExtension() {
        XCTAssertEqual(AutomationNameResolver.resolve("forest", among: candidates), .unique(3))
    }

    func testSharedPrefixIsAmbiguousRatherThanPickingOne() {
        XCTAssertEqual(
            AutomationNameResolver.resolve("Ocean", among: candidates),
            .ambiguous(["Ocean.mp4", "Ocean Night.mp4"])
        )
    }

    func testFullWidthAndCaseAreIgnored() {
        XCTAssertEqual(AutomationNameResolver.resolve("tokyo", among: candidates), .unique(4))
    }

    func testUnknownAndBlankNamesAreNotFound() {
        XCTAssertEqual(AutomationNameResolver.resolve("desert", among: candidates), .notFound)
        XCTAssertEqual(AutomationNameResolver.resolve("   ", among: candidates), .notFound)
    }

    func testDuplicateDisplayNamesAreAmbiguous() {
        let duplicated = [(id: 1, name: "Clip"), (id: 2, name: "Clip")]
        XCTAssertEqual(
            AutomationNameResolver.resolve("clip", among: duplicated),
            .ambiguous(["Clip", "Clip"])
        )
    }

    func testAliasesOfTheSameTargetAreNotAmbiguous() {
        let aliased: [(id: Int?, name: String)] = [
            (id: nil, name: "all"),
            (id: nil, name: "All Wallpapers"),
            (id: 7, name: "Work"),
        ]
        XCTAssertEqual(AutomationNameResolver.resolve("al", among: aliased), .unique(nil))
    }
}

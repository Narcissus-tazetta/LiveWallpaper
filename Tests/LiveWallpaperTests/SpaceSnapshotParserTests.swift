import XCTest
@testable import LiveWallpaper

final class SpaceSnapshotParserTests: XCTestCase {
    private func space(uuid: String, fullscreen: Bool = false) -> [String: Any] {
        var dict: [String: Any] = [
            "ManagedSpaceID": Int.random(in: 1...9999),
            "uuid": uuid,
            "type": 0,
        ]
        if fullscreen {
            dict["TileLayoutManager"] = ["kind": "tile"] as [String: Any]
        }
        return dict
    }

    private func display(
        identifier: String,
        spaces: [[String: Any]],
        current: [String: Any]
    ) -> [String: Any] {
        [
            "Display Identifier": identifier,
            "Spaces": spaces,
            "Current Space": current,
        ]
    }

    func testNormalizeUUIDMapsEmptyAndNilToPrimary() {
        XCTAssertEqual(SpaceSnapshotParser.normalizeUUID(nil), "primary")
        XCTAssertEqual(SpaceSnapshotParser.normalizeUUID(""), "primary")
        XCTAssertEqual(SpaceSnapshotParser.normalizeUUID("ABC-123"), "ABC-123")
    }

    func testParseSingleDisplayAssignsOrdinals() {
        let raw = [
            display(
                identifier: "Main",
                spaces: [
                    space(uuid: ""),
                    space(uuid: "S2"),
                    space(uuid: "S3"),
                ],
                current: space(uuid: "S2")
            )
        ]
        let snapshots = SpaceSnapshotParser.parse(raw)
        XCTAssertEqual(snapshots?.count, 1)
        let snapshot = snapshots?.first
        XCTAssertEqual(snapshot?.cgsDisplayIdentifier, "Main")
        XCTAssertEqual(snapshot?.currentSpaceUUID, "S2")
        XCTAssertEqual(snapshot?.currentSpaceIsFullscreen, false)
        XCTAssertEqual(
            snapshot?.spaces.map(\.uuid),
            ["primary", "S2", "S3"]
        )
        XCTAssertEqual(snapshot?.spaces.map(\.ordinal), [1, 2, 3])
    }

    func testParseSkipsFullscreenSpacesInOrdinals() {
        let raw = [
            display(
                identifier: "Main",
                spaces: [
                    space(uuid: "S1"),
                    space(uuid: "F1", fullscreen: true),
                    space(uuid: "S2"),
                ],
                current: space(uuid: "F1", fullscreen: true)
            )
        ]
        let snapshot = SpaceSnapshotParser.parse(raw)?.first
        XCTAssertEqual(snapshot?.spaces.map(\.ordinal), [1, nil, 2])
        XCTAssertEqual(snapshot?.spaces.map(\.isFullscreen), [false, true, false])
        XCTAssertEqual(snapshot?.currentSpaceIsFullscreen, true)
    }

    func testParseContinuesOrdinalsAcrossDisplays() {
        let raw = [
            display(
                identifier: "UUID-A",
                spaces: [space(uuid: "A1"), space(uuid: "A2")],
                current: space(uuid: "A1")
            ),
            display(
                identifier: "UUID-B",
                spaces: [
                    space(uuid: "F1", fullscreen: true),
                    space(uuid: "B1"),
                ],
                current: space(uuid: "B1")
            ),
        ]
        let snapshots = SpaceSnapshotParser.parse(raw)
        XCTAssertEqual(snapshots?.count, 2)
        XCTAssertEqual(snapshots?[0].spaces.map(\.ordinal), [1, 2])
        XCTAssertEqual(snapshots?[1].spaces.map(\.ordinal), [nil, 3])
        XCTAssertEqual(snapshots?[1].currentSpaceUUID, "B1")
    }

    func testParseReturnsNilOnMissingRequiredKeys() {
        XCTAssertNil(SpaceSnapshotParser.parse([]))
        XCTAssertNil(SpaceSnapshotParser.parse([["Spaces": []]]))
        XCTAssertNil(
            SpaceSnapshotParser.parse([
                [
                    "Display Identifier": "Main",
                    "Spaces": [["uuid": "S1"]],
                    // "Current Space" 欠落
                ]
            ])
        )
        XCTAssertNil(
            SpaceSnapshotParser.parse([
                [
                    "Display Identifier": "Main",
                    "Spaces": "not-an-array",
                    "Current Space": ["uuid": "S1"],
                ]
            ])
        )
    }
}

@testable import LiveWallpaper
import XCTest

final class SceneBakeCleanupTests: XCTestCase {
    func testOnlyStagedBakeFilesIdleForAnHourAreRemoved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let names = [
            "..scene-A.mp4.B.tmp.mp4": now.addingTimeInterval(-7200),
            ".scene-C.mp4": now.addingTimeInterval(-7200),
            ".scene-D.png": now.addingTimeInterval(-7200),
            "..scene-E.mp4.F.tmp.mp4": now.addingTimeInterval(-60),
            "wallpaper-G.mp4": now.addingTimeInterval(-7200),
            ".hidden.mp4": now.addingTimeInterval(-7200)
        ]
        for (name, modified) in names {
            let url = directory.appendingPathComponent(name)
            try Data([0]).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: modified],
                ofItemAtPath: url.path
            )
        }

        WallpaperModel.removeAbandonedBakeFiles(in: directory, now: now)

        let left = try Set(FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertEqual(left, ["..scene-E.mp4.F.tmp.mp4", "wallpaper-G.mp4", ".hidden.mp4"])
    }
}

import XCTest

@testable import LiveWallpaper

@MainActor
final class PackageImporterVersionGateTests: XCTestCase {
    private func manifest(version: String) -> PackageManifest {
        PackageManifest(
            version: version,
            manifest: .init(
                name: "Test", author: "tester", createdAt: "2026-07-21T00:00:00Z",
                description: "desc", license: nil
            ),
            videos: [],
            playlists: [],
            packaging: .init(videosIncluded: false, packageSizeBytes: 0)
        )
    }

    func testAcceptsVersion1_0() {
        let importer = PackageImporter()
        XCTAssertNoThrow(try importer.validateManifest(manifest(version: "1.0")))
    }

    func testAcceptsVersion1_1() {
        let importer = PackageImporter()
        XCTAssertNoThrow(try importer.validateManifest(manifest(version: "1.1")))
    }

    func testRejectsUnknownVersion() {
        let importer = PackageImporter()
        XCTAssertThrowsError(try importer.validateManifest(manifest(version: "2.0"))) { error in
            guard case PackageImporter.ImportError.unsupportedPackageVersion = error else {
                XCTFail("expected unsupportedPackageVersion, got \(error)")
                return
            }
        }
    }
}

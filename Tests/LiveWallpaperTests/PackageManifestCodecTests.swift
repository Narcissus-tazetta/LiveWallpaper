import XCTest

@testable import LiveWallpaper

final class PackageManifestCodecTests: XCTestCase {
    private func samplePackageVideo(
        edit: PackageManifest.PackageVideo.EditMetadata?
    ) -> PackageManifest.PackageVideo {
        PackageManifest.PackageVideo(
            id: "video-1",
            source: .init(fileName: "clip.mp4", size: 1024),
            displayName: "Clip",
            sha256: "deadbeef",
            thumbnail: "previews/video-1.png",
            presentations: [
                "main": .init(fitMode: "fill", zoom: 1.0, offsetX: 0, offsetY: 0)
            ],
            edit: edit,
            duration: 12.5,
            hasAudio: false
        )
    }

    private func sampleManifest(
        edit: PackageManifest.PackageVideo.EditMetadata?
    ) -> PackageManifest {
        PackageManifest(
            version: "1.1",
            manifest: .init(
                name: "Test Package",
                author: "tester",
                createdAt: "2026-07-21T00:00:00Z",
                description: "desc",
                license: "CC-BY-4.0"
            ),
            videos: [samplePackageVideo(edit: edit)],
            playlists: [],
            packaging: .init(videosIncluded: true, packageSizeBytes: 1024)
        )
    }

    func testRoundTripWithEditMetadata() throws {
        let edit = PackageManifest.PackageVideo.EditMetadata(
            trimStart: 1.5, trimEnd: 9.0, loopStart: 3.0
        )
        let manifest = sampleManifest(edit: edit)

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(PackageManifest.self, from: data)

        XCTAssertEqual(decoded.videos.first?.edit?.trimStart, 1.5)
        XCTAssertEqual(decoded.videos.first?.edit?.trimEnd, 9.0)
        XCTAssertEqual(decoded.videos.first?.edit?.loopStart, 3.0)
        XCTAssertEqual(decoded.videos.first?.duration, 12.5)
        XCTAssertEqual(decoded.videos.first?.hasAudio, false)
        XCTAssertEqual(decoded.manifest.license, "CC-BY-4.0")
    }

    func testRoundTripWithoutEditMetadata() throws {
        let manifest = sampleManifest(edit: nil)

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(PackageManifest.self, from: data)

        XCTAssertNil(decoded.videos.first?.edit)
    }

    /// 1.0時代の.lwpkgには edit/duration/hasAudio/license キー自体が存在しない。
    /// 手書きの旧フォーマットJSONをデコードして後方互換性を実証する。
    func testDecodesLegacyManifestWithoutNewFields() throws {
        let legacyJSON = """
        {
            "version": "1.0",
            "manifest": {
                "name": "Legacy Package",
                "author": "someone",
                "createdAt": "2026-01-01T00:00:00Z",
                "description": "old export"
            },
            "videos": [
                {
                    "id": "video-1",
                    "source": { "fileName": "clip.mp4", "size": 2048 },
                    "displayName": "Clip",
                    "sha256": "abc123",
                    "thumbnail": null,
                    "presentations": {
                        "main": { "fitMode": "fill", "zoom": 1.0, "offsetX": 0, "offsetY": 0 }
                    }
                }
            ],
            "playlists": [],
            "packaging": { "videosIncluded": true, "packageSizeBytes": 2048 }
        }
        """
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(PackageManifest.self, from: data)

        XCTAssertEqual(decoded.version, "1.0")
        XCTAssertNil(decoded.manifest.license)
        XCTAssertNil(decoded.videos.first?.edit)
        XCTAssertNil(decoded.videos.first?.duration)
        XCTAssertNil(decoded.videos.first?.hasAudio)
    }
}

import Foundation
@testable import LiveWallpaper
import XCTest

@MainActor
final class PackageSecurityTests: XCTestCase {
    private let fileManager = FileManager.default

    struct ZipEntry {
        var name: String
        var data: Data
        var isSymlink: Bool = false
        var symlinkTarget: String?
        var spoofedUncompressedSize: UInt32?
    }

    /// Builds a valid ZIP archive in memory with custom entries.
    private func buildZip(entries: [ZipEntry]) -> Data {
        var body = Data()
        var centralDirectory = Data()

        for entry in entries {
            let offset = UInt32(body.count)
            let nameBytes = Array(entry.name.utf8)
            let entryData = entry.isSymlink ? Data((entry.symlinkTarget ?? "").utf8) : entry.data
            let uncompressedSize = entry.spoofedUncompressedSize ?? UInt32(entryData.count)
            let compressedSize = UInt32(entryData.count)
            let crc = crc32Checksum(entryData)

            // Local file header
            var localHeader = Data()
            localHeader.append(contentsOf: [0x50, 0x4B, 0x03, 0x04]) // signature
            localHeader.appendUInt16(20) // version needed
            localHeader.appendUInt16(0) // flags
            localHeader.appendUInt16(0) // compression (stored)
            localHeader.appendUInt16(0) // mod time
            localHeader.appendUInt16(0) // mod date
            localHeader.appendUInt32(crc)
            localHeader.appendUInt32(compressedSize)
            localHeader.appendUInt32(uncompressedSize)
            localHeader.appendUInt16(UInt16(nameBytes.count))
            localHeader.appendUInt16(0) // extra length
            localHeader.append(contentsOf: nameBytes)
            localHeader.append(entryData)
            body.append(localHeader)

            // Central directory header
            centralDirectory.append(contentsOf: [0x50, 0x4B, 0x01, 0x02]) // signature
            centralDirectory.appendUInt16(0x031E) // version made by (UNIX 3.0)
            centralDirectory.appendUInt16(20) // version needed
            centralDirectory.appendUInt16(0) // flags
            centralDirectory.appendUInt16(0) // compression
            centralDirectory.appendUInt16(0) // mod time
            centralDirectory.appendUInt16(0) // mod date
            centralDirectory.appendUInt32(crc)
            centralDirectory.appendUInt32(compressedSize)
            centralDirectory.appendUInt32(uncompressedSize)
            centralDirectory.appendUInt16(UInt16(nameBytes.count))
            centralDirectory.appendUInt16(0) // extra length
            centralDirectory.appendUInt16(0) // comment length
            centralDirectory.appendUInt16(0) // disk start
            centralDirectory.appendUInt16(0) // internal attr
            // external attr: symlink is 0120777 << 16, regular is 0100644 << 16
            let externalAttr: UInt32 = entry.isSymlink ? (0o120777 << 16) : (0o100644 << 16)
            centralDirectory.appendUInt32(externalAttr)
            centralDirectory.appendUInt32(offset)
            centralDirectory.append(contentsOf: nameBytes)
        }

        let cdOffset = UInt32(body.count)
        let cdSize = UInt32(centralDirectory.count)
        let entryCount = UInt16(min(entries.count, 0xFFFF))

        var eocd = Data()
        eocd.append(contentsOf: [0x50, 0x4B, 0x05, 0x06]) // signature
        eocd.appendUInt16(0) // disk num
        eocd.appendUInt16(0) // start disk
        eocd.appendUInt16(entryCount)
        eocd.appendUInt16(entryCount)
        eocd.appendUInt32(cdSize)
        eocd.appendUInt32(cdOffset)
        eocd.appendUInt16(0) // comment len

        var result = body
        result.append(centralDirectory)
        result.append(eocd)
        return result
    }

    private func crc32Checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                let mask = (crc & 1) != 0 ? UInt32(0xEDB8_8320) : 0
                crc = (crc >> 1) ^ mask
            }
        }
        return ~crc
    }

    private func makeValidManifestData(videoID: String = "test-video") throws -> Data {
        let manifest = PackageManifest(
            version: "1.1",
            manifest: .init(
                name: "Test",
                author: "tester",
                createdAt: "2026-11-05T00:00:00Z",
                description: "desc",
                license: nil
            ),
            videos: [
                .init(
                    id: videoID,
                    source: .init(fileName: "\(videoID).mp4", size: nil),
                    displayName: videoID,
                    sha256: nil,
                    thumbnail: nil,
                    presentations: [:],
                    edit: nil,
                    duration: nil,
                    hasAudio: nil
                )
            ],
            playlists: [],
            packaging: .init(videosIncluded: true, packageSizeBytes: nil)
        )
        return try JSONEncoder().encode(manifest)
    }

    /// CASE 1: Zip slip (entry name contains ../)
    func testZipSlipIsRejected() async throws {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let canaryFile = tempDir.appendingPathComponent("escaped.txt")
        let zipData = try buildZip(entries: [
            ZipEntry(name: "content/metadata.json", data: makeValidManifestData()),
            ZipEntry(name: "content/videos/test-video.mp4", data: Data("video-content".utf8)),
            ZipEntry(name: "../escaped.txt", data: Data("pwned".utf8))
        ])
        let zipURL = tempDir.appendingPathComponent("slip.lwpkg")
        try zipData.write(to: zipURL)

        let model = WallpaperModel()
        do {
            try await PackageImporter().importPackage(from: zipURL, into: model)
            XCTFail("Package with zip-slip entry must be rejected")
        } catch PackageImporter.ImportError.unsafeFileReference {
            XCTAssertFalse(fileManager.fileExists(atPath: canaryFile.path))
        }
    }

    /// CASE 2: Symlink pointing outside extraction root
    func testSymlinkPointingOutsideIsRejected() async throws {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let zipData = try buildZip(entries: [
            ZipEntry(name: "content/metadata.json", data: makeValidManifestData()),
            ZipEntry(
                name: "content/videos/test-video.mp4",
                data: Data(),
                isSymlink: true,
                symlinkTarget: "/etc/passwd"
            )
        ])
        let zipURL = tempDir.appendingPathComponent("symlink.lwpkg")
        try zipData.write(to: zipURL)

        let model = WallpaperModel()
        do {
            try await PackageImporter().importPackage(from: zipURL, into: model)
            XCTFail("Symlink pointing to /etc/passwd must be rejected")
        } catch PackageImporter.ImportError.unsafeFileReference {
            // Expected
        }
    }

    /// CASE 3: Declared uncompressed size exceeds limit (Zip bomb)
    func testZipBombWithHugeDeclaredSizeIsRejected() async throws {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        // Spoof uncompressed size to 3GB (> 2GB limit)
        let zipData = try buildZip(entries: [
            ZipEntry(name: "content/metadata.json", data: makeValidManifestData()),
            ZipEntry(
                name: "content/videos/test-video.mp4",
                data: Data("tiny".utf8),
                spoofedUncompressedSize: 3 * 1024 * 1024 * 1024
            )
        ])
        let zipURL = tempDir.appendingPathComponent("bomb.lwpkg")
        try zipData.write(to: zipURL)

        var limits = PackageImporter.Limits.local
        limits.maximumExtractedBytes = 2 * 1024 * 1024 * 1024
        let model = WallpaperModel()
        do {
            try await PackageImporter(limits: limits).importPackage(from: zipURL, into: model)
            XCTFail("Package declaring > 2GB uncompressed size must be rejected before extraction")
        } catch PackageImporter.ImportError.extractedSizeTooLarge {
            // Expected
        }
    }

    /// Packages the user exports are not size-capped, so a multi-GB scene video must still import;
    /// only the Store preset rejects it.
    func testLargeDeclaredSizeIsAcceptedLocallyButNotForStore() throws {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let zipData = try buildZip(entries: [
            ZipEntry(name: "content/metadata.json", data: makeValidManifestData()),
            ZipEntry(
                name: "content/videos/test-video.mp4",
                data: Data("tiny".utf8),
                spoofedUncompressedSize: 3 * 1024 * 1024 * 1024
            )
        ])
        let zipURL = tempDir.appendingPathComponent("large.lwpkg")
        try zipData.write(to: zipURL)

        let local = try PackageImporter.inspectZipArchive(at: zipURL, limits: .local)
        XCTAssertGreaterThan(local.totalUncompressedBytes, 3 * 1024 * 1024 * 1024)
        XCTAssertThrowsError(try PackageImporter.inspectZipArchive(
            at: zipURL,
            limits: .store
        )) { error in
            guard case PackageImporter.ImportError.extractedSizeTooLarge = error else {
                return XCTFail("Expected extractedSizeTooLarge, got \(error)")
            }
        }
    }

    func testNamesContainingDoubleDotsInsideAComponentAreNotTreatedAsTraversal() throws {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let zipData = buildZip(entries: [
            ZipEntry(name: "content/videos/clip..final.mp4", data: Data("x".utf8))
        ])
        let zipURL = tempDir.appendingPathComponent("dots.lwpkg")
        try zipData.write(to: zipURL)
        XCTAssertNoThrow(try PackageImporter.inspectZipArchive(at: zipURL, limits: .local))
    }

    /// CASE 4: Excessive entry count
    func testExcessiveEntryCountIsRejected() async throws {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        var entries: [ZipEntry] = try [
            ZipEntry(name: "content/metadata.json", data: makeValidManifestData()),
            ZipEntry(name: "content/videos/test-video.mp4", data: Data("video".utf8))
        ]
        for i in 0 ..< 5001 {
            entries.append(ZipEntry(name: "content/extra_\(i).txt", data: Data("a".utf8)))
        }
        let zipData = buildZip(entries: entries)
        let zipURL = tempDir.appendingPathComponent("many_files.lwpkg")
        try zipData.write(to: zipURL)

        let model = WallpaperModel()
        do {
            try await PackageImporter(limits: .store).importPackage(from: zipURL, into: model)
            XCTFail("Package with > 5000 entries must be rejected")
        } catch PackageImporter.ImportError.excessiveEntryCount {
            // Expected
        }
    }

    /// CASE 5a: Malformed formatVersion in scene.json
    func testMalformedFormatVersionInSceneIsRejected() async throws {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let malformedSceneJSON = Data("""
        {
            "formatVersion": -1,
            "canvasWidth": 1920,
            "canvasHeight": 1080
        }
        """.utf8)

        let manifest = PackageManifest(
            version: "1.1",
            manifest: .init(
                name: "Test",
                author: "tester",
                createdAt: "2026-11-05T00:00:00Z",
                description: "desc",
                license: nil
            ),
            videos: [
                .init(
                    id: "scene-video",
                    source: .init(fileName: "scene-video.mp4", size: nil),
                    displayName: "Scene",
                    sha256: nil,
                    thumbnail: nil,
                    presentations: [:],
                    edit: nil,
                    duration: nil,
                    hasAudio: nil,
                    scene: true
                )
            ],
            playlists: [],
            packaging: .init(videosIncluded: true, packageSizeBytes: nil)
        )
        let manifestData = try JSONEncoder().encode(manifest)

        let zipData = buildZip(entries: [
            ZipEntry(name: "content/metadata.json", data: manifestData),
            ZipEntry(name: "content/videos/scene-video.mp4", data: Data("mp4".utf8)),
            ZipEntry(name: "content/scenes/scene-video/scene.json", data: malformedSceneJSON)
        ])
        let zipURL = tempDir.appendingPathComponent("bad_format.lwpkg")
        try zipData.write(to: zipURL)

        let model = WallpaperModel()
        do {
            try await PackageImporter().importPackage(from: zipURL, into: model)
            // Note: Broken scene doesn't fail entire package, but scene must not be imported
            XCTAssertNil(model.sceneDocumentsByPath.first { $0.key.contains("scene-video") })
        } catch {
            // Also acceptable if package rejected
        }
    }

    /// CASE 5b: Huge metadata.json (> 10MB limit)
    func testHugeMetadataJSONIsRejected() async throws {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        // Create 11MB of dummy padding in metadata.json
        let hugeMetadata = Data(count: 11 * 1024 * 1024)
        let zipData = buildZip(entries: [
            ZipEntry(name: "content/metadata.json", data: hugeMetadata),
            ZipEntry(name: "content/videos/test-video.mp4", data: Data("mp4".utf8))
        ])
        let zipURL = tempDir.appendingPathComponent("huge_meta.lwpkg")
        try zipData.write(to: zipURL)

        let model = WallpaperModel()
        do {
            try await PackageImporter().importPackage(from: zipURL, into: model)
            XCTFail("Package with >10MB metadata.json must be rejected")
        } catch PackageImporter.ImportError.metadataTooLarge {
            // Expected
        }
    }

    /// CASE 5c: Huge scene.json (> 500MB limit)
    func testHugeSceneJSONIsRejected() throws {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let sceneFile = tempDir.appendingPathComponent("scene.json")
        fileManager.createFile(atPath: sceneFile.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sceneFile)
        try handle.truncate(atOffset: UInt64(SceneStore.maximumSceneJSONBytes + 1024))
        try handle.close()

        XCTAssertThrowsError(try SceneStore.importScene(
            from: tempDir,
            videoPath: "/tmp/video.mp4"
        )) { error in
            guard case SceneStore.ImportError.sceneDefinitionTooLarge = error else {
                XCTFail("Expected sceneDefinitionTooLarge error, got \(error)")
                return
            }
        }
    }

    /// CASE 5d: Unsupported manifest version
    func testUnsupportedManifestVersionIsRejected() async throws {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let manifest = PackageManifest(
            version: "99.0",
            manifest: .init(
                name: "Future",
                author: "tester",
                createdAt: "2026-11-05T00:00:00Z",
                description: "desc",
                license: nil
            ),
            videos: [
                .init(
                    id: "video",
                    source: .init(fileName: "video.mp4", size: nil),
                    displayName: "Video",
                    sha256: nil,
                    thumbnail: nil,
                    presentations: [:],
                    edit: nil,
                    duration: nil,
                    hasAudio: nil
                )
            ],
            playlists: [],
            packaging: .init(videosIncluded: true, packageSizeBytes: nil)
        )
        let manifestData = try JSONEncoder().encode(manifest)
        let zipData = buildZip(entries: [
            ZipEntry(name: "content/metadata.json", data: manifestData),
            ZipEntry(name: "content/videos/video.mp4", data: Data("mp4".utf8))
        ])
        let zipURL = tempDir.appendingPathComponent("future_ver.lwpkg")
        try zipData.write(to: zipURL)

        let model = WallpaperModel()
        do {
            try await PackageImporter().importPackage(from: zipURL, into: model)
            XCTFail("Package with unsupported version must be rejected")
        } catch PackageImporter.ImportError.unsupportedPackageVersion {
            // Expected!
        }
    }

    /// CASE 6: Video path traversal in manifest
    func testVideoPathTraversalInManifestIsRejected() async throws {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let manifest = PackageManifest(
            version: "1.1",
            manifest: .init(
                name: "Test",
                author: "tester",
                createdAt: "2026-11-05T00:00:00Z",
                description: "desc",
                license: nil
            ),
            videos: [
                .init(
                    id: "../evil",
                    source: .init(fileName: "evil.mp4", size: nil),
                    displayName: "Evil",
                    sha256: nil,
                    thumbnail: nil,
                    presentations: [:],
                    edit: nil,
                    duration: nil,
                    hasAudio: nil
                )
            ],
            playlists: [],
            packaging: .init(videosIncluded: true, packageSizeBytes: nil)
        )
        let manifestData = try JSONEncoder().encode(manifest)
        let zipData = buildZip(entries: [
            ZipEntry(name: "content/metadata.json", data: manifestData),
            ZipEntry(name: "content/videos/evil.mp4", data: Data("mp4".utf8))
        ])
        let zipURL = tempDir.appendingPathComponent("evil_id.lwpkg")
        try zipData.write(to: zipURL)

        let model = WallpaperModel()
        do {
            try await PackageImporter().importPackage(from: zipURL, into: model)
            XCTFail("video.id with '../' must be rejected")
        } catch PackageImporter.ImportError.unsafeFileReference {
            // Expected!
        }
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

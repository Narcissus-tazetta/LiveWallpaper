import Foundation
@testable import LiveWallpaper
import XCTest

@MainActor
final class PackageZip64Tests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testPackageWithDirectoryBeyondFourGiBCanBePreviewedAndImported() async throws {
        let archive = try makeArchive(directoryOffset: UInt64(UInt32.max) + 1024)
        let inspection = try PackageImporter.inspectZipArchive(at: archive)
        XCTAssertEqual(inspection.totalEntries, 1)
        XCTAssertGreaterThan(inspection.totalUncompressedBytes, 0)
        let importer = PackageImporter(
            videosDirectory: directory.appendingPathComponent("Videos"), scenePresetStore: nil
        )
        let preview = try await importer.preview(of: archive)
        XCTAssertEqual(preview.manifest.manifest.name, "ZIP64")
        try await importer.importPackage(from: archive, into: WallpaperModel())
    }

    func testZip64EntrySizeStillEnforcesTheExtractionLimit() throws {
        let archive = try makeArchive(uncompressedSize: UInt64.max)
        XCTAssertThrowsError(try PackageImporter.inspectZipArchive(at: archive)) { error in
            guard case PackageImporter.ImportError.extractedSizeTooLarge = error else {
                return XCTFail("Expected extraction limit, got \(error)")
            }
        }
    }

    func testZip64DirectoryCannotPointOutsideTheArchive() throws {
        let archive = try makeArchive(claimedDirectoryOffset: UInt64.max)
        XCTAssertThrowsError(try PackageImporter.inspectZipArchive(at: archive)) { error in
            guard case PackageImporter.ImportError.invalidPackageFormat = error else {
                return XCTFail("Expected invalid archive, got \(error)")
            }
        }
    }

    private func makeArchive(
        directoryOffset: UInt64? = nil,
        uncompressedSize: UInt64? = nil,
        claimedDirectoryOffset: UInt64? = nil
    ) throws -> URL {
        let name = Data("metadata.json".utf8)
        let body = Data("""
        {"version":"1.1","manifest":{"name":"ZIP64","author":"test","createdAt":"2026-11-10T00:00:00Z","description":"test"},"videos":[],"playlists":[],"packaging":{"videosIncluded":true,"packageSizeBytes":0}}
        """.utf8)
        let size = uncompressedSize ?? UInt64(body.count)
        let crc = crc32(body)
        var extra = Data()
        extra.appendLE(UInt16(1))
        extra.appendLE(UInt16(16))
        extra.appendLE(size)
        extra.appendLE(UInt64(body.count))
        var local = Data()
        local.appendLE(UInt32(0x0403_4B50))
        for value: UInt16 in [45, 0, 0, 0, 0] {
            local.appendLE(value)
        }
        local.appendLE(crc)
        local.appendLE(UInt32.max)
        local.appendLE(UInt32.max)
        local.appendLE(UInt16(name.count))
        local.appendLE(UInt16(extra.count))
        local.append(name)
        local.append(extra)
        local.append(body)

        var central = Data()
        central.appendLE(UInt32(0x0201_4B50))
        for value: UInt16 in [45, 45, 0, 0, 0, 0] {
            central.appendLE(value)
        }
        central.appendLE(crc)
        central.appendLE(UInt32.max)
        central.appendLE(UInt32.max)
        central.appendLE(UInt16(name.count))
        central.appendLE(UInt16(extra.count))
        for value: UInt16 in [0, 0, 0] {
            central.appendLE(value)
        }
        central.appendLE(UInt32(0))
        central.appendLE(UInt32(0))
        central.append(name)
        central.append(extra)

        let actualOffset = directoryOffset ?? UInt64(local.count)
        var ending = Data()
        ending.appendLE(UInt32(0x0606_4B50))
        ending.appendLE(UInt64(44))
        ending.appendLE(UInt16(45))
        ending.appendLE(UInt16(45))
        ending.appendLE(UInt32(0))
        ending.appendLE(UInt32(0))
        ending.appendLE(UInt64(1))
        ending.appendLE(UInt64(1))
        ending.appendLE(UInt64(central.count))
        ending.appendLE(claimedDirectoryOffset ?? actualOffset)
        ending.appendLE(UInt32(0x0706_4B50))
        ending.appendLE(UInt32(0))
        ending.appendLE(actualOffset + UInt64(central.count))
        ending.appendLE(UInt32(1))
        ending.appendLE(UInt32(0x0605_4B50))
        ending.appendLE(UInt16(0))
        ending.appendLE(UInt16(0))
        ending.appendLE(UInt16.max)
        ending.appendLE(UInt16.max)
        ending.appendLE(UInt32.max)
        ending.appendLE(UInt32.max)
        ending.appendLE(UInt16(0))

        let archive = directory.appendingPathComponent("\(UUID()).lwpkg")
        try local.write(to: archive)
        let handle = try FileHandle(forWritingTo: archive)
        defer { try? handle.close() }
        try handle.seek(toOffset: actualOffset)
        try handle.write(contentsOf: central)
        try handle.write(contentsOf: ending)
        return archive
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xEDB8_8320)
            }
        }
        return ~crc
    }
}

private extension Data {
    mutating func appendLE(_ value: some FixedWidthInteger) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

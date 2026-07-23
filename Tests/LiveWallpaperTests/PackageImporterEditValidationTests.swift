import XCTest

@testable import LiveWallpaper

/// PackageImporter が manifest内の edit(トリム/ループ)メタデータを、モデルへ適用する
/// 前に WallpaperEditMetadata.isValid で検証することを確認する。Store経由で他人の
/// 環境が作った .lwpkg を取り込めるようになったため、trimEnd<=trimStart のような
/// 不正な値をそのまま受け入れると、再生パスで不正な CMTimeRange を作ってしまう。
@MainActor
final class PackageImporterEditValidationTests: XCTestCase {
    private let fileManager = FileManager.default
    private var importedVideoPaths: [String] = []

    override func tearDown() {
        for path in importedVideoPaths {
            try? fileManager.removeItem(atPath: path)
        }
        importedVideoPaths = []
        super.tearDown()
    }

    private func makePackage(
        videos: [PackageManifest.PackageVideo], in workDir: URL
    ) throws -> URL {
        let contentDir = workDir.appendingPathComponent("content")
        let videosDir = contentDir.appendingPathComponent("videos")
        try fileManager.createDirectory(at: videosDir, withIntermediateDirectories: true)

        for video in videos {
            let videoFile = videosDir.appendingPathComponent("\(video.id).mp4")
            try Data("stand-in bytes for \(video.id)".utf8).write(to: videoFile)
        }

        let manifest = PackageManifest(
            version: "1.1",
            manifest: .init(
                name: "Test Package", author: "tester", createdAt: "2026-07-21T00:00:00Z",
                description: "desc", license: nil
            ),
            videos: videos,
            playlists: [],
            packaging: .init(videosIncluded: true, packageSizeBytes: 0)
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: contentDir.appendingPathComponent("metadata.json"))

        let packageURL = workDir.appendingPathComponent("test.lwpkg")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = [
            "-c", "-k", "--sequesterRsrc", "--keepParent", contentDir.path, packageURL.path
        ]
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw NSError(
                domain: "PackageImporterEditValidationTests",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "package creation failed"]
            )
        }
        return packageURL
    }

    private func packageVideo(
        id: String,
        edit: PackageManifest.PackageVideo.EditMetadata?
    ) -> PackageManifest.PackageVideo {
        PackageManifest.PackageVideo(
            id: id,
            source: .init(fileName: "\(id).mp4", size: nil),
            displayName: id,
            sha256: nil,
            thumbnail: nil,
            presentations: [:],
            edit: edit,
            duration: nil,
            hasAudio: nil
        )
    }

    func testInvalidEditMetadataIsSkippedNotAppliedOrThrown() async throws {
        let workDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDir) }

        let invalidVideo = packageVideo(
            id: "bad-edit",
            // trimEnd <= trimStart は WallpaperEditMetadata.isValid で弾かれる不正値。
            edit: .init(trimStart: 5, trimEnd: 2, loopStart: nil)
        )
        let packageURL = try makePackage(videos: [invalidVideo], in: workDir)

        let model = WallpaperModel()
        try await PackageImporter().importPackage(from: packageURL, into: model)

        let importedPath = model.allRegisteredVideoPaths.first { $0.hasSuffix("bad-edit.mp4") }
        importedPath.map { importedVideoPaths.append($0) }
        let path = try XCTUnwrap(
            importedPath, "video should still import even though its edit metadata is invalid"
        )

        XCTAssertNil(
            model.wallpaperEdit(for: path),
            "an invalid trim/loop range must not be applied to the model"
        )
    }

    func testValidEditMetadataIsAppliedNormally() async throws {
        let workDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDir) }

        let validVideo = packageVideo(
            id: "good-edit",
            edit: .init(trimStart: 1, trimEnd: 9, loopStart: 3)
        )
        let packageURL = try makePackage(videos: [validVideo], in: workDir)

        let model = WallpaperModel()
        try await PackageImporter().importPackage(from: packageURL, into: model)

        let importedPath = model.allRegisteredVideoPaths.first { $0.hasSuffix("good-edit.mp4") }
        importedPath.map { importedVideoPaths.append($0) }
        let path = try XCTUnwrap(importedPath)

        let edit = try XCTUnwrap(model.wallpaperEdit(for: path))
        XCTAssertEqual(edit.trimStart, 1)
        XCTAssertEqual(edit.trimEnd, 9)
        XCTAssertEqual(edit.loopStart, 3)
    }
}

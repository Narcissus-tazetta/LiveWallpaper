import XCTest

@testable import LiveWallpaper

/// exportSingleWallpaperPackage(license:) が実際にパッケージ内の metadata.json へ
/// 反映されることを検証する。以前は StoreClient から渡されたライセンス文字列が
/// この関数の引数として受け取られておらず、常に PackageManifestBuilder のnilデフォルト
/// にフォールバックしていた(Store掲載ページの表示とパッケージ内容が食い違うバグ)。
@MainActor
final class PackageExporterLicenseTests: XCTestCase {
    private let fileManager = FileManager.default

    private func makeStandInVideoFile(in dir: URL) throws -> URL {
        // exportSingleWallpaperPackage は動画ファイルの「存在」と属性取得にしか
        // 依存しない(尺・音声トラック読み込みやサムネイル生成はすべて try? で
        // 失敗を許容する)ため、実際の動画である必要はない。
        let videoPath = dir.appendingPathComponent("clip.mp4")
        try Data("stand-in bytes, not a real video".utf8).write(to: videoPath)
        return videoPath
    }

    private func readManifest(fromPackageAt packageURL: URL) throws -> PackageManifest {
        let extractDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: extractDir) }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-x", "-k", packageURL.path, extractDir.path]
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw NSError(
                domain: "PackageExporterLicenseTests",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "extraction failed"]
            )
        }

        let directURL = extractDir.appendingPathComponent("metadata.json")
        let nestedURL = extractDir.appendingPathComponent("content/metadata.json")
        let metadataURL = fileManager.fileExists(atPath: directURL.path) ? directURL : nestedURL
        let data = try Data(contentsOf: metadataURL)
        return try JSONDecoder().decode(PackageManifest.self, from: data)
    }

    func testExportSingleWallpaperPackageEmbedsCallerLicense() async throws {
        let workDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDir) }

        let videoPath = try makeStandInVideoFile(in: workDir)
        let outputDir = workDir.appendingPathComponent("out")
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let packageURL = try await PackageExporter().exportSingleWallpaperPackage(
            model: WallpaperModel(),
            videoPath: videoPath.path,
            outputFolderURL: outputDir,
            baseFileName: "clip",
            license: "CC-BY-4.0"
        )

        let manifest = try readManifest(fromPackageAt: packageURL)
        XCTAssertEqual(manifest.manifest.license, "CC-BY-4.0")
    }

    func testExportSingleWallpaperPackageDefaultsLicenseToNil() async throws {
        let workDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDir) }

        let videoPath = try makeStandInVideoFile(in: workDir)
        let outputDir = workDir.appendingPathComponent("out")
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let packageURL = try await PackageExporter().exportSingleWallpaperPackage(
            model: WallpaperModel(),
            videoPath: videoPath.path,
            outputFolderURL: outputDir,
            baseFileName: "clip"
        )

        let manifest = try readManifest(fromPackageAt: packageURL)
        XCTAssertNil(manifest.manifest.license)
    }
}

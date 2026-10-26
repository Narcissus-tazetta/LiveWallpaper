import CoreGraphics
import ImageIO
import XCTest
@testable import LiveWallpaper

final class ReconvertedSceneFilesTests: XCTestCase {
    func testReplacesSceneVideoAndPreviewAndBacksUpAllThree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("library.mp4")
        let sourceVideo = root.appendingPathComponent("source.mp4")
        let preview = VideoThumbnailGenerator.expectedSidecarURL(for: video.path)
        let backup = root.appendingPathComponent("backup")
        var old = SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [])
        old.backgroundColor = [1, 0, 0]
        var updated = old
        updated.backgroundColor = [0, 0, 1]
        try SceneStore.save(old, videoPath: video.path)
        try SceneStore.save(updated, videoPath: sourceVideo.path)
        try Data("old video".utf8).write(to: video)
        try Data("old preview".utf8).write(to: preview)
        _ = try await ReconvertedSceneFiles.replace(source: SceneStore.folderURL(forVideoPath: sourceVideo.path),
                                                   videoPath: video.path, backup: backup)
        XCTAssertEqual(try SceneStore.load(videoPath: video.path), updated)
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent(video.lastPathComponent)), "old video")
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent(preview.lastPathComponent)), "old preview")
        let backedScene = backup.appendingPathComponent(SceneStore.folderURL(forVideoPath: video.path).lastPathComponent)
        XCTAssertEqual(try JSONDecoder().decode(SceneDocument.self, from: Data(contentsOf: backedScene.appendingPathComponent("scene.json"))), old)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(preview as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertLessThan(pixel[0], 40)
        XCTAssertGreaterThan(pixel[2], 200)
        XCTAssertGreaterThan(try Data(contentsOf: video).count, 100)
    }

    func testPreparationFailureKeepsExistingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("library.mp4")
        try Data("old video".utf8).write(to: video)
        do {
            _ = try await ReconvertedSceneFiles.replace(source: root.appendingPathComponent("missing"), videoPath: video.path,
                                                       backup: root.appendingPathComponent("backup"))
            XCTFail("A missing source must fail")
        } catch {
            XCTAssertEqual(try String(contentsOf: video), "old video")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["library.mp4"])
        }
    }
}

import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import LiveWallpaper

/// importVideoToAppSupport のアニメ画像分岐を実際のモデル経由で通す統合テスト。
/// 変換されたmp4は実キャッシュディレクトリに作られるため、テスト内で必ず削除する。
@MainActor
final class WallpaperModelMediaImportTests: XCTestCase {
    private var workingDirectory: URL!

    override func setUpWithError() throws {
        workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallpaperModelMediaImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    private func writeAnimatedGIF(frameCount: Int, delay: Double) throws -> URL {
        let url = workingDirectory.appendingPathComponent("import-test.gif")
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        )!
        for index in 0..<frameCount {
            let context = CGContext(
                data: nil,
                width: 64,
                height: 64,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            )!
            let gray = CGFloat(index) / CGFloat(max(frameCount - 1, 1))
            context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            let frameProperties = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]
            ] as CFDictionary
            CGImageDestinationAddImage(destination, context.makeImage()!, frameProperties)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testImportAnimatedGIFProducesPlayableMP4InCache() async throws {
        let model = WallpaperModel()
        let gif = try writeAnimatedGIF(frameCount: 6, delay: 0.5)

        let imported = await model.importVideoToAppSupport(from: gif)
        let url = try XCTUnwrap(imported)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(url.pathExtension, "mp4")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("wallpaper-"))
        XCTAssertFalse(model.isImportingMedia)
        XCTAssertNil(model.mediaImportErrorMessage)
        XCTAssertEqual(model.mediaImportProgress, 1.0, accuracy: 0.001)

        let asset = AVURLAsset(url: url)
        let isPlayable = try await asset.load(.isPlayable)
        XCTAssertTrue(isPlayable)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 3.0, accuracy: 0.05)
    }

    func testImportCorruptImageSetsErrorMessageAndReturnsNil() async throws {
        let model = WallpaperModel()
        let garbage = workingDirectory.appendingPathComponent("garbage.gif")
        try Data(repeating: 0xCD, count: 2048).write(to: garbage)

        let imported = await model.importVideoToAppSupport(from: garbage)

        XCTAssertNil(imported)
        XCTAssertFalse(model.isImportingMedia)
        XCTAssertNotNil(model.mediaImportErrorMessage)
    }

    func testImportRegularVideoStillCopiesUnchanged() async throws {
        let model = WallpaperModel()
        let fakeVideo = workingDirectory.appendingPathComponent("clip.mp4")
        let payload = Data("not-a-real-video-but-copy-path-only".utf8)
        try payload.write(to: fakeVideo)

        let imported = await model.importVideoToAppSupport(from: fakeVideo)
        let url = try XCTUnwrap(imported)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(url.pathExtension, "mp4")
        XCTAssertEqual(try Data(contentsOf: url), payload, "動画はトランスコードせず従来どおり単純コピー")
        XCTAssertFalse(model.isImportingMedia)
    }
}

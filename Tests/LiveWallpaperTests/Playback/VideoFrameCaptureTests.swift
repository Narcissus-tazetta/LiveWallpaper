import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import LiveWallpaper

/// フリーズフレーム生成が生成器のキャッシュ越しでも正しく動くことを、実ファイルで確認する。
/// キャッシュ自体は実装詳細なので、外から見える「毎回ちゃんとデコードできる」ことを見る。
@MainActor
final class VideoFrameCaptureTests: XCTestCase {
    private var workingDirectory: URL!

    override func setUpWithError() throws {
        workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoFrameCaptureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    private func writeAnimatedGIF(named name: String, size: Int) throws -> URL {
        let url = workingDirectory.appendingPathComponent(name)
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 4, nil)
        )
        for index in 0 ..< 4 {
            let context = try XCTUnwrap(
                CGContext(
                    data: nil,
                    width: size,
                    height: size,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                )
            )
            let gray = CGFloat(index) / 3.0
            context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            CGImageDestinationAddImage(
                destination,
                try XCTUnwrap(context.makeImage()),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.5]] as CFDictionary
            )
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func makeVideo(named name: String, size: Int) async throws -> URL {
        let model = WallpaperModel()
        let gif = try writeAnimatedGIF(named: name, size: size)
        let imported = await model.importVideoToAppSupport(from: gif)
        return try XCTUnwrap(imported)
    }

    func testRepeatedCapturesOfSameVideoStayCorrect() async throws {
        let url = try await makeVideo(named: "capture.gif", size: 64)
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try XCTUnwrap(
            VideoFrameCapture.capture(path: url.path, time: .zero)
        )
        // 2回目以降はキャッシュ済みの生成器を通る経路。
        let second = try XCTUnwrap(
            VideoFrameCapture.capture(path: url.path, time: .zero)
        )
        let later = try XCTUnwrap(
            VideoFrameCapture.capture(
                path: url.path,
                time: CMTime(seconds: 1.5, preferredTimescale: 600)
            )
        )

        XCTAssertEqual(first.width, 64)
        XCTAssertEqual(second.width, first.width)
        XCTAssertEqual(second.height, first.height)
        XCTAssertEqual(later.width, first.width)
    }

    /// 複数の動画を交互にキャプチャしても、それぞれ自分のフレームが返る
    /// (キャッシュがパスを取り違えない)。
    func testCapturesFromDifferentVideosDoNotCrossOver() async throws {
        let small = try await makeVideo(named: "small.gif", size: 32)
        defer { try? FileManager.default.removeItem(at: small) }
        let large = try await makeVideo(named: "large.gif", size: 96)
        defer { try? FileManager.default.removeItem(at: large) }

        let smallFrame = try XCTUnwrap(VideoFrameCapture.capture(path: small.path, time: .zero))
        let largeFrame = try XCTUnwrap(VideoFrameCapture.capture(path: large.path, time: .zero))
        let smallAgain = try XCTUnwrap(VideoFrameCapture.capture(path: small.path, time: .zero))

        XCTAssertEqual(smallFrame.width, 32)
        XCTAssertEqual(largeFrame.width, 96)
        XCTAssertEqual(smallAgain.width, 32, "キャッシュが別動画のフレームを返してはいけない")
    }

    func testMissingFileReturnsNilRatherThanThrowing() {
        let missing = workingDirectory.appendingPathComponent("nope.mp4").path
        XCTAssertNil(VideoFrameCapture.capture(path: missing, time: .zero))
    }
}

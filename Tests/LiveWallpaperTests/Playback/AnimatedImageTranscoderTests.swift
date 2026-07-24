import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import LiveWallpaper

final class AnimatedImageTranscoderTests: XCTestCase {
    private var workingDirectory: URL!

    override func setUpWithError() throws {
        workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnimatedImageTranscoderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    // MARK: - Helpers

    private func makeSolidImage(width: Int, height: Int, gray: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )!
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func writeAnimatedGIF(
        frameCount: Int,
        delay: Double,
        width: Int = 64,
        height: Int = 63,
        fileName: String = "test.gif"
    ) throws -> URL {
        let url = workingDirectory.appendingPathComponent(fileName)
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        )!
        let fileProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary
        CGImageDestinationSetProperties(destination, fileProperties)
        for index in 0..<frameCount {
            let frameProperties = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]
            ] as CFDictionary
            let gray = CGFloat(index) / CGFloat(max(frameCount - 1, 1))
            CGImageDestinationAddImage(
                destination,
                makeSolidImage(width: width, height: height, gray: gray),
                frameProperties
            )
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func writeAnimatedAPNG(
        frameCount: Int,
        delay: Double,
        width: Int = 64,
        height: Int = 64
    ) throws -> URL {
        let url = workingDirectory.appendingPathComponent("test.png")
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            frameCount,
            nil
        )!
        let fileProperties = [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]
        ] as CFDictionary
        CGImageDestinationSetProperties(destination, fileProperties)
        for index in 0..<frameCount {
            let frameProperties = [
                kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay]
            ] as CFDictionary
            let gray = CGFloat(index) / CGFloat(max(frameCount - 1, 1))
            CGImageDestinationAddImage(
                destination,
                makeSolidImage(width: width, height: height, gray: gray),
                frameProperties
            )
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func outputURL(_ name: String = "out.mp4") -> URL {
        workingDirectory.appendingPathComponent(name)
    }

    private func loadVideoInfo(_ url: URL) async throws -> (duration: Double, size: CGSize, codec: FourCharCode) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        let descriptions = try await track.load(.formatDescriptions)
        let codec = CMFormatDescriptionGetMediaSubType(try XCTUnwrap(descriptions.first))
        return (duration.seconds, size, codec)
    }

    // MARK: - Tests

    func testSupportedExtensions() {
        XCTAssertTrue(AnimatedImageTranscoder.isSupportedImageExtension("gif"))
        XCTAssertTrue(AnimatedImageTranscoder.isSupportedImageExtension("GIF"))
        XCTAssertTrue(AnimatedImageTranscoder.isSupportedImageExtension("png"))
        XCTAssertTrue(AnimatedImageTranscoder.isSupportedImageExtension("apng"))
        XCTAssertTrue(AnimatedImageTranscoder.isSupportedImageExtension("webp"))
        XCTAssertFalse(AnimatedImageTranscoder.isSupportedImageExtension("mp4"))
        XCTAssertFalse(AnimatedImageTranscoder.isSupportedImageExtension("jpg"))
    }

    func testAnimatedGIFTranscodesWithExpectedDurationAndEvenDimensions() async throws {
        // 4フレーム × 0.5秒 = 2.0秒(最小時間ルールの繰り返しなし)、64×63の奇数辺
        let gif = try writeAnimatedGIF(frameCount: 4, delay: 0.5)
        let output = outputURL()

        var lastProgress = 0.0
        try await AnimatedImageTranscoder.transcode(imageURL: gif, to: output) { value in
            lastProgress = value
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(lastProgress, 1.0, accuracy: 0.001)

        let info = try await loadVideoInfo(output)
        XCTAssertEqual(info.duration, 2.0, accuracy: 0.05)
        XCTAssertEqual(info.size.width, 64)
        XCTAssertEqual(info.size.height, 64, "奇数の高さ63は64へ偶数化される")
        let codecString = String(describing: UTCreateStringForOSType(info.codec).takeRetainedValue())
        XCTAssertTrue(["hvc1", "avc1"].contains(codecString), "unexpected codec: \(codecString)")
    }

    func testShortAnimationIsRepeatedToMinimumDuration() async throws {
        // 4フレーム × 0.1秒 = 0.4秒 → 5回繰り返しで2.0秒
        let gif = try writeAnimatedGIF(frameCount: 4, delay: 0.1)
        let output = outputURL()

        try await AnimatedImageTranscoder.transcode(imageURL: gif, to: output)

        let info = try await loadVideoInfo(output)
        XCTAssertEqual(info.duration, 2.0, accuracy: 0.05)
    }

    func testZeroDelayFramesNormalizeToBrowserDefault() async throws {
        // 0ディレイ25フレーム → 100ms/フレーム = 2.5秒(最小時間ルールに掛からない長さ)
        let gif = try writeAnimatedGIF(frameCount: 25, delay: 0.0)
        let output = outputURL()

        try await AnimatedImageTranscoder.transcode(imageURL: gif, to: output)

        let info = try await loadVideoInfo(output)
        XCTAssertEqual(info.duration, 2.5, accuracy: 0.1)
    }

    func testAnimatedAPNGTranscodes() async throws {
        let apng = try writeAnimatedAPNG(frameCount: 5, delay: 0.5)
        let output = outputURL()

        try await AnimatedImageTranscoder.transcode(imageURL: apng, to: output)

        let info = try await loadVideoInfo(output)
        XCTAssertEqual(info.duration, 2.5, accuracy: 0.05)
        XCTAssertEqual(info.size, CGSize(width: 64, height: 64))
    }

    func testSingleFrameImageBecomesStillLoopVideo() async throws {
        let gif = try writeAnimatedGIF(frameCount: 1, delay: 0.0, fileName: "still.gif")
        let output = outputURL()

        try await AnimatedImageTranscoder.transcode(imageURL: gif, to: output)

        let info = try await loadVideoInfo(output)
        XCTAssertEqual(info.duration, 4.0, accuracy: 0.05)
    }

    func testGarbageFileThrowsAndLeavesNoOutput() async throws {
        let garbage = workingDirectory.appendingPathComponent("garbage.gif")
        try Data(repeating: 0xAB, count: 4096).write(to: garbage)
        let output = outputURL()

        do {
            try await AnimatedImageTranscoder.transcode(imageURL: garbage, to: output)
            XCTFail("garbage input should throw")
        } catch let error as AnimatedImageTranscoder.TranscodeError {
            switch error {
            case .unreadableImage, .zeroFrames:
                break
            default:
                XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: output.appendingPathExtension("tmp").path),
            "失敗時に.tmpが残ってはならない"
        )
    }

    func testMissingFileThrows() async throws {
        let missing = workingDirectory.appendingPathComponent("missing.gif")
        do {
            try await AnimatedImageTranscoder.transcode(imageURL: missing, to: outputURL())
            XCTFail("missing input should throw")
        } catch is AnimatedImageTranscoder.TranscodeError {
            // expected
        }
    }

    func testOversizedCanvasIsCappedToMaxLongEdge() async throws {
        var options = AnimatedImageTranscoder.Options()
        options.maxLongEdge = 100
        let gif = try writeAnimatedGIF(frameCount: 2, delay: 0.5, width: 400, height: 200)
        let output = outputURL()

        try await AnimatedImageTranscoder.transcode(imageURL: gif, to: output, options: options)

        let info = try await loadVideoInfo(output)
        XCTAssertEqual(info.size, CGSize(width: 100, height: 50))
    }
}

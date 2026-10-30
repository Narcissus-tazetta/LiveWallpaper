import AVFoundation
@testable import LiveWallpaper
import Metal
import XCTest

final class SceneVideoFramesTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SceneVideoFramesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// 2 seconds at 10 fps; frame n is filled with grey n * 12.
    private func writeVideo() async throws -> URL {
        let url = directory.appendingPathComponent("clip.mp4")
        let size = 64, fps: Int32 = 10
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size, AVVideoHeightKey: size,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 5]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size, kCVPixelBufferHeightKey as String: size
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0 ..< 20 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)), Int32(frame * 12), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    func testImportedVideoKeepsItsFileAndFirstFrameInTheSceneFolder() async throws {
        let clip = try await writeVideo()
        let videoPath = directory.appendingPathComponent("wallpaper.mp4").path
        let layer = try await SceneStore.importVideo(at: clip, videoPath: videoPath)
        let folder = SceneStore.folderURL(forVideoPath: videoPath)
        XCTAssertEqual(layer.name, "clip")
        let videoFile = try XCTUnwrap(layer.videoFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(videoFile).path))
        XCTAssertEqual(try SceneStore.pixelSize(of: folder.appendingPathComponent(layer.imageFile)), CGSize(width: 64, height: 64))
    }

    private func grey(_ frames: SceneVideoFrames) throws -> Int {
        let texture = try XCTUnwrap(frames.frame?.texture)
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(32, 32, 1, 1), mipmapLevel: 0)
        return Int(pixel[1])
    }

    /// Frame n shows grey n * 12; compression moves it a few levels.
    private func assertShows(_ frames: SceneVideoFrames, frame: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(Double(try grey(frames)), Double(frame * 12), accuracy: 5, "frame \(frame)", file: file, line: line)
    }

    func testFramesFollowTimeAndLoop() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let frames = try await SceneVideoFrames.load(url: try await writeVideo(), device: device)
        XCTAssertEqual(frames.duration, 2, accuracy: 0.01)
        try frames.advance(to: 0)
        try assertShows(frames, frame: 0)
        try frames.advance(to: 0.55)
        try assertShows(frames, frame: 5)
        try frames.advance(to: 1.95)
        try assertShows(frames, frame: 19)
        try frames.advance(to: 2.3)
        try assertShows(frames, frame: 3)
        // Back in time, as the editor scrubs.
        try frames.advance(to: 1.0)
        try assertShows(frames, frame: 10)
    }

    func testRequestsDecodeOnTheVideoQueue() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let frames = try await SceneVideoFrames.load(url: try await writeVideo(), device: device)
        XCTAssertNil(frames.frame)
        for time in [0.0, 0.5, 1.2, 1.9, 2.1] {
            let expected = Int((time.truncatingRemainder(dividingBy: 2) * 10).rounded(.down))
            frames.request(time)
            // request returns at once; the frame arrives from the video's queue.
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if frames.frame != nil, try abs(grey(frames) - expected * 12) <= 5 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try assertShows(frames, frame: expected)
        }
    }

    func testVideoLayerIsAnimatedAndItsFileKept() throws {
        var layer = SceneLayer(name: "clip", imageFile: "poster.png")
        XCTAssertFalse(layer.isAnimated)
        layer.videoFile = "clip.mp4"
        XCTAssertTrue(layer.isAnimated)
        let document = SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [layer])
        XCTAssertEqual(SceneStore.referencedFiles(of: document), ["poster.png", "clip.mp4"])
        let decoded = try JSONDecoder().decode(SceneDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded.layers.first?.videoFile, "clip.mp4")
    }
}

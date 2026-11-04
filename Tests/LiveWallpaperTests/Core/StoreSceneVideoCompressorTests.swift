@preconcurrency import AVFoundation
import XCTest
@testable import LiveWallpaper

@MainActor
final class StoreSceneVideoCompressorTests: XCTestCase {
    private func makeVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.jpeg,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 180,
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 1.0]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 180
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var seed: UInt32 = 12345
        for row in 0..<180 {
            for column in 0..<320 {
                let offset = row * CVPixelBufferGetBytesPerRow(buffer) + column * 4
                pixels[offset] = 255
                for channel in 1...3 {
                    seed = seed &* 1664525 &+ 1013904223
                    pixels[offset + channel] = UInt8(truncatingIfNeeded: seed >> 24)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for frame in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        if let error = writer.error { throw error }
        XCTAssertEqual(writer.status, .completed)
    }

    func testStoreCopyFitsBudgetAndKeepsAllFramesWithoutChangingLocalVideo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try! FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("local.mov")
        try await makeVideo(at: source)
        let content = folder.appendingPathComponent("content")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        let copy = content.appendingPathComponent("video.mov")
        try FileManager.default.copyItem(at: source, to: copy)
        let assetBytes = 512 * 1024
        try Data(repeating: 7, count: assetBytes).write(to: content.appendingPathComponent("texture.bin"))
        let original = try Data(contentsOf: source)
        let limit = 3 * 1024 * 1024
        XCTAssertGreaterThan(original.count, limit)
        try await StoreSceneVideoCompressor.compressIfNeeded(videoURL: copy, contentDirectory: content, maximumPackageBytes: limit)
        XCTAssertLessThan(try Data(contentsOf: copy).count, limit - assetBytes - 1_048_576)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let asset = AVURLAsset(url: copy)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 2, accuracy: 0.001)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let frameRate = try await track.load(.nominalFrameRate)
        XCTAssertEqual(frameRate, 30)
        let reduced = try Data(contentsOf: copy)
        try await StoreSceneVideoCompressor.compressIfNeeded(videoURL: copy, contentDirectory: content, maximumPackageBytes: limit)
        XCTAssertEqual(try Data(contentsOf: copy), reduced)
    }

    func testAssetsOverBudgetFailWithoutChangingVideo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try! FileManager.default.removeItem(at: folder) }
        let video = folder.appendingPathComponent("video.mp4")
        let original = Data([1, 2, 3])
        try original.write(to: video)
        try Data(repeating: 7, count: 2048).write(to: folder.appendingPathComponent("texture.bin"))
        do {
            try await StoreSceneVideoCompressor.compressIfNeeded(videoURL: video, contentDirectory: folder, maximumPackageBytes: 1024)
            XCTFail("The scene assets alone exceed the upload limit")
        } catch StoreClientError.fileTooLarge {
            XCTAssertEqual(try Data(contentsOf: video), original)
        }
    }
}

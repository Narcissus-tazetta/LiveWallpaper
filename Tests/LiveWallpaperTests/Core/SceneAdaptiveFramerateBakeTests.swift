import AppKit
import AVFoundation
@testable import LiveWallpaper
import XCTest

@MainActor
final class SceneAdaptiveFramerateBakeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneAdaptiveFramerateBakeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func makeScene(videoURL: URL, cycles: Int = 1) throws -> SceneDocument {
        var pixels = [UInt8](repeating: 255, count: 64 * 64 * 4)
        for y in 0 ..< 64 {
            for x in 0 ..< 64 {
                let index = (y * 64 + x) * 4
                pixels[index] = UInt8(x * 4)
                pixels[index + 1] = UInt8(y * 4)
                pixels[index + 2] = 0
            }
        }
        let image = CGImage(
            width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )!
        let file = try SceneStore.writeImage(image, prefix: "layer", videoPath: videoURL.path)
        var layer = SceneLayer(name: "gradient", imageFile: file)
        var spin = SceneEffect(kind: .spin)
        spin.cycles = cycles
        layer.effects = [spin]
        var doc = SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [layer])
        doc.loopSeconds = 10
        return doc
    }

    func testBakeGentleSceneProduces30FPSVideo() async throws {
        let video = directory.appendingPathComponent("gentle.mp4")
        // One turn per 10 s moves the rim of a 64x64 canvas well under a pixel per frame
        let scene = try makeScene(videoURL: video, cycles: 1)

        try await SceneVideoBaker.bake(document: scene, videoPath: video.path, to: video) { _ in }

        let asset = AVURLAsset(url: video)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let frameRate = try await track.load(.nominalFrameRate)
        XCTAssertEqual(round(Double(frameRate)), 30.0, "Gentle motion scene should be baked at 30 fps")
    }

    func testBakeRapidMotionKeeps60FPSVideo() async throws {
        let video = directory.appendingPathComponent("rapid.mp4")
        // 300 turns in 10 s = a full spin every 2 frames
        let scene = try makeScene(videoURL: video, cycles: 300)

        try await SceneVideoBaker.bake(document: scene, videoPath: video.path, to: video) { _ in }

        let asset = AVURLAsset(url: video)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let frameRate = try await track.load(.nominalFrameRate)
        XCTAssertEqual(round(Double(frameRate)), 60.0, "Rapid motion scene should be kept at 60 fps")
    }
}

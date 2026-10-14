import AppKit
@testable import LiveWallpaper
import Metal
import XCTest

/// How motion meets the edge of its area: painted masks, held edges, drifting.
@MainActor
final class SceneMotionAreaTests: XCTestCase {
    private var directory: URL!
    private var video: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneMotionAreaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        video = directory.appendingPathComponent("scene.mp4")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func writeImage(_ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> String {
        var pixels = [UInt8](repeating: 255, count: 64 * 64 * 4)
        for y in 0 ..< 64 {
            for x in 0 ..< 64 {
                let (r, g, b) = pixel(x, y)
                pixels[(y * 64 + x) * 4] = r
                pixels[(y * 64 + x) * 4 + 1] = g
                pixels[(y * 64 + x) * 4 + 2] = b
            }
        }
        let image = CGImage(
            width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )!
        return try SceneStore.writeImage(image, prefix: "layer", videoPath: video.path)
    }

    /// BGRA.
    private func frame(_ scene: SceneDocument, time: Double) throws -> [UInt8] {
        let renderer = try SceneRenderer(document: scene, videoPath: video.path)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let command = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
        try renderer.encode(into: texture, commandBuffer: command, input: SceneFrameInput(time: time))
        command.commit()
        command.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        texture.getBytes(&pixels, bytesPerRow: 256, from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
        return pixels
    }

    private func scene(_ file: String, _ effect: SceneEffect) -> SceneDocument {
        var layer = SceneLayer(name: "picture", imageFile: file)
        layer.effects = [effect]
        return SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [layer])
    }

    func testMotionInsideAPaintedAreaDoesNotDragInWhatIsOutside() throws {
        // Red left half outside the area, blue right half painted.
        let file = try writeImage { x, _ in x < 32 ? (255, 0, 0) : (0, 0, 255) }
        var shake = SceneEffect(kind: .shake)
        shake.strength = 1
        shake.maskFile = try SceneStore.writePaintImage(
            (0 ..< 64 * 64).map { $0 % 64 < 32 ? 0 : 255 }, width: 64, height: 64, target: .mask, videoPath: video.path
        )
        // A quarter of the loop: the shake is at its furthest, moving the picture right.
        let pixels = try frame(scene(file, shake), time: 5)
        var reddest = 0
        for y in 0 ..< 64 {
            for x in 32 ..< 64 {
                reddest = max(reddest, Int(pixels[(y * 64 + x) * 4 + 2]))
            }
        }
        XCTAssertLessThan(reddest, 40, "red from outside the area leaked in")
    }

    func testFixedEdgeHoldsThatSideStill() throws {
        let file = try writeImage { x, y in (UInt8(x * 4), UInt8(y * 4), 0) }
        var sway = SceneEffect(kind: .shake)
        sway.strength = 1
        sway.fixedEdge = .top
        let still = try frame(scene(file, SceneEffect(kind: .pulse)), time: 0)
        let moved = try frame(scene(file, sway), time: 5)
        func rowDifference(_ y: Int) -> Int {
            (0 ..< 64).map { x in abs(Int(still[(y * 64 + x) * 4 + 2]) - Int(moved[(y * 64 + x) * 4 + 2])) }.max()!
        }
        XCTAssertLessThanOrEqual(rowDifference(0), 1, "the top stays")
        XCTAssertGreaterThan(rowDifference(63), 4, "the bottom moves")
    }

    func testDriftMovesAndLoops() throws {
        let file = try writeImage { x, y in (UInt8(x * 4), UInt8((x * y) % 256), UInt8(y * 4)) }
        let drift = scene(file, SceneEffect(kind: .drift))
        let start = try frame(drift, time: 0)
        let later = try frame(drift, time: 3)
        let end = try frame(drift, time: Double(drift.loopSeconds) - 1.0 / 60)
        func mean(_ a: [UInt8], _ b: [UInt8]) -> Double {
            Double(zip(a, b).map { abs(Int($0) - Int($1)) }.reduce(0, +)) / Double(a.count)
        }
        XCTAssertGreaterThan(mean(start, later), 1)
        XCTAssertLessThan(mean(start, end), 1, "no jump at the loop's seam")
    }

    func testEffectsSavedBeforeFixedEdgesOpenWithNone() throws {
        let json = #"{"id":"6F1C2A4E-9D38-4B57-9C3A-1E2D3F4A5B6C","kind":"sway"}"#
        let effect = try JSONDecoder().decode(SceneEffect.self, from: Data(json.utf8))
        XCTAssertEqual(effect.fixedEdge, .none)
        XCTAssertNil(effect.areaBounds)
    }

    func testAreaBoundsBoxThePaintedPixels() throws {
        var bytes = [UInt8](repeating: 0, count: 10 * 10)
        bytes[2 * 10 + 3] = 255
        bytes[6 * 10 + 7] = 255
        let bounds = try XCTUnwrap(SceneAreaBounds.of(bytes, width: 10, height: 10))
        XCTAssertEqual(bounds, SceneAreaBounds(minX: 0.3, minY: 0.2, maxX: 0.8, maxY: 0.7))
        XCTAssertNil(SceneAreaBounds.of([UInt8](repeating: 0, count: 4), width: 2, height: 2))
    }
}

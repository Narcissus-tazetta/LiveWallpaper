import AppKit
import ImageIO
@testable import LiveWallpaper
import Metal
import XCTest

/// Adding and painting the real-time effects in the editor.
@MainActor
final class SceneEditorEffectTests: XCTestCase {
    private var directory: URL!
    private var video: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneEditorEffectTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        video = directory.appendingPathComponent("scene.mp4")
        // The editor only paints scenes that already have their folder.
        try FileManager.default.createDirectory(at: SceneStore.folderURL(forVideoPath: video.path), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func bytes(_ image: CGImage) -> [UInt8] {
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    func testPatternsTileWithoutASeam() throws {
        for pattern in [ScenePatternGenerator.Pattern.noise, .normals, .phase] {
            let image = ScenePatternGenerator.image(pattern)
            let size = image.width
            let pixels = bytes(image)
            func column(_ x: Int) -> [Double] { (0 ..< size).map { Double(pixels[($0 * size + x) * 4]) } }
            func row(_ y: Int) -> [Double] { (0 ..< size).map { Double(pixels[(y * size + $0) * 4]) } }
            func difference(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Double(a.count) }
            let neighbours = (0 ..< size - 1).map { difference(column($0), column($0 + 1)) }.reduce(0, +) / Double(size - 1)
            XCTAssertGreaterThan(neighbours, 0.05, "\(pattern) is flat")
            XCTAssertLessThan(difference(column(size - 1), column(0)), neighbours * 2.5, "\(pattern) has a seam left to right")
            XCTAssertLessThan(difference(row(size - 1), row(0)), neighbours * 2.5, "\(pattern) has a seam top to bottom")
            if let dump = ProcessInfo.processInfo.environment["PATTERN_DUMP_DIR"] {
                let url = URL(fileURLWithPath: dump).appendingPathComponent("\(pattern).png")
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
    }

    func testAddedEffectsThatReadAPatternGetOneAndMove() throws {
        let model = WallpaperModel()
        let layerImage = ScenePatternGenerator.image(.noise)
        let file = try SceneStore.writeImage(layerImage, prefix: "layer", videoPath: video.path)
        for kind in [SceneEffectKind.flowMap, .normalRipples, .noiseDrift, .noiseSway, .axisSwing] {
            var effect = try XCTUnwrap(model.makeSceneEffect(kind, path: video.path))
            let pattern = try XCTUnwrap(effect.patternFile, "\(kind)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: SceneStore.folderURL(forVideoPath: video.path).appendingPathComponent(pattern).path))
            if kind == .flowMap {
                // Streams only where a flow is painted: everywhere, to the right.
                effect.flowFile = try SceneStore.writeImage(
                    ScenePatternGenerator.solidForTests(red: 255, green: 128), prefix: "flow", videoPath: video.path
                )
            }
            var layer = SceneLayer(name: "picture", imageFile: file)
            layer.effects = [effect]
            let scene = SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [layer])
            let renderer = try SceneRenderer(document: scene, videoPath: video.path)
            let still = try renderer.renderStill()
            var moved = try frame(renderer, time: 1.3)
            XCTAssertNotEqual(bytes(still), moved, "\(kind) did not move")
            moved = []
        }
    }

    func testFlowPaintedRightIsStoredReversedForAFlowMapAndShownAsDrawn() throws {
        for reversed in [false, true] {
            let painter = SceneMaskPainter()
            var saved: String?
            painter.onCommit = { _, file, _ in saved = file }
            painter.onError = { XCTFail("\($0)") }
            painter.begin(
                SceneMaskPainter.Target(
                    path: video.path, layerID: UUID(), effectID: UUID(), kind: .flow, storesFlowReversed: reversed
                ),
                existingFile: nil, layerPixelSize: CGSize(width: 64, height: 64)
            )
            painter.brushSize = 0.3
            painter.strokeBegan(at: SIMD2(0.2, 0.5))
            for step in 1 ... 12 {
                painter.strokeMoved(to: SIMD2(0.2 + Float(step) * 0.05, 0.5))
            }
            let arrows = painter.flowArrows(columns: 8)
            painter.strokeEnded()

            XCTAssertFalse(arrows.isEmpty)
            XCTAssertTrue(arrows.allSatisfy { $0.flow.x > 0 }, "arrows show the way it was drawn")
            let file = try XCTUnwrap(saved)
            let bytes = try SceneStore.readPaintImage(file, width: 64, height: 64, target: .flow, videoPath: video.path)
            let centre = (32 * 64 + 32) * 4
            if reversed {
                XCTAssertLessThan(bytes[centre], 100, "a flow map stores the stroke reversed")
            } else {
                XCTAssertGreaterThan(bytes[centre], 156)
            }
        }
    }

    func testTimeOffsetIsPaintedAsItsOwnGreyFile() throws {
        let painter = SceneMaskPainter()
        var saved: (ScenePaintOverride.Target, String)?
        painter.onCommit = { target, file, _ in saved = (target.kind, file) }
        painter.onError = { XCTFail("\($0)") }
        painter.begin(
            SceneMaskPainter.Target(path: video.path, layerID: UUID(), effectID: UUID(), kind: .timeOffset),
            existingFile: nil, layerPixelSize: CGSize(width: 64, height: 64)
        )
        painter.fillAll()
        let (kind, file) = try XCTUnwrap(saved)
        XCTAssertEqual(kind, .timeOffset)
        let bytes = try SceneStore.readPaintImage(file, width: 64, height: 64, target: .timeOffset, videoPath: video.path)
        XCTAssertEqual(bytes.count, 64 * 64)
        XCTAssertTrue(bytes.allSatisfy { $0 == 255 })
    }

    private func frame(_ renderer: SceneRenderer, time: Double) throws -> [UInt8] {
        let (width, height) = SceneRenderer.outputSize(for: renderer.document, maxEdge: SceneRenderer.maxTextureEdge)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let command = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
        try renderer.encode(into: texture, commandBuffer: command, input: SceneFrameInput(time: time))
        command.commit()
        command.waitUntilCompleted()
        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bgra, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        var rgba = bgra
        for i in 0 ..< width * height { rgba[i * 4] = bgra[i * 4 + 2]; rgba[i * 4 + 2] = bgra[i * 4]; rgba[i * 4 + 3] = 255 }
        return rgba
    }
}

private extension ScenePatternGenerator {
    static func solidForTests(red: UInt8, green: UInt8) -> CGImage {
        let pixels = [UInt8]((0 ..< 64 * 64).flatMap { _ in [red, green, 0, 255] })
        return CGImage(
            width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }
}

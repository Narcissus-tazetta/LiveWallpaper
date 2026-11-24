import CoreGraphics
@testable import LiveWallpaper
import Metal
import XCTest

@MainActor
final class SceneCoverTests: XCTestCase {
    private var directory: URL!
    private let size = 64

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneCoverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private var videoPath: String {
        directory.appendingPathComponent("cover.mp4").path
    }

    private func layer(seed: Int, alpha: (Int, Int) -> UInt8 = { _, _ in
        255
    }) throws -> SceneLayer {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0 ..< size {
            for x in 0 ..< size {
                let index = (y * size + x) * 4
                let a = alpha(x, y)
                // Premultiplied: colour no brighter than alpha.
                pixels[index] = UInt8((x * 4 + seed * 37) % 256) & a
                pixels[index + 1] = UInt8((y * 4 + seed * 91) % 256) & a
                pixels[index + 2] = UInt8((x + y + seed * 13) % 256) & a
                pixels[index + 3] = a
            }
        }
        let image = CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )!
        let file = try SceneStore.writeImage(image, prefix: "layer", videoPath: videoPath)
        return SceneLayer(name: "layer \(seed)", imageFile: file)
    }

    private var hidden = 0

    private func render(_ layers: [SceneLayer], scripts: [SceneScript] = []) throws -> [UInt8] {
        var document = SceneDocument(canvasWidth: size, canvasHeight: size, layers: layers)
        document.scripts = scripts
        let renderer = try SceneRenderer(document: document, videoPath: videoPath)
        let input = SceneFrameInput()
        let frame = scripts.isEmpty ? nil : try SceneFrameEvaluator()
            .evaluate(document, input: input, timeOfDay: .day)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let command = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
        try renderer.encode(into: texture, commandBuffer: command, input: input, frame: frame)
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        hidden = renderer.layersHiddenByCover
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        texture.getBytes(
            &pixels, bytesPerRow: size * 4,
            from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0
        )
        return pixels
    }

    func testOpaqueFullLayerShowsExactlyItselfOverAnything() throws {
        let cover = try layer(seed: 3)
        var tinted = try layer(seed: 1)
        tinted.blendMode = .screen
        let below = try [
            layer(seed: 1),
            tinted,
            layer(seed: 2, alpha: { x, _ in x < 32 ? 0 : 128 })
        ]
        let covered = try render(below + [cover])
        XCTAssertEqual(hidden, below.count)
        XCTAssertEqual(covered, try render([cover]))
    }

    func testTransparentOrMovedTopLayerStillShowsWhatIsBelow() throws {
        let bottom = try layer(seed: 1)
        let holed = try layer(seed: 3, alpha: { x, y in x == 10 && y == 10 ? 0 : 255 })
        XCTAssertNotEqual(try render([bottom, holed]), try render([holed]))
        _ = try render([bottom, holed])
        XCTAssertEqual(hidden, 0)

        var shrunk = try layer(seed: 3)
        shrunk.transform.scale = 0.5
        XCTAssertNotEqual(try render([bottom, shrunk]), try render([shrunk]))

        var faded = try layer(seed: 3)
        faded.opacity = 0.99
        XCTAssertNotEqual(try render([bottom, faded]), try render([faded]))
    }

    func testCoverWhoseScriptTurnsAnEffectOnStillShowsWhatIsBelow() throws {
        let bottom = try layer(seed: 1)
        var cover = try layer(seed: 3)
        var mask = SceneEffect(kind: .opacityMask)
        mask.values = ["alpha": 0.5]
        mask.isEnabled = false
        cover.effects = [mask]
        var script = SceneScript(
            source: """
            export function update(c){return [{id:c.targets[0].id,\
            effects:[{id:c.targets[0].effects[0].id,isEnabled:true}]}];}
            """,
            layerIDs: [cover.id]
        )
        script.modules = [:]
        script.isAuthorized = true
        // Half transparent, the cover lets the layer below through.
        _ = try render([bottom, cover], scripts: [script])
        XCTAssertEqual(hidden, 0)
        XCTAssertNotEqual(
            try render([bottom, cover], scripts: [script]),
            try render([cover], scripts: [script])
        )
    }

    func testOnlyPicturesWithoutTransparentPixelsCountAsOpaque() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let opaque = try layer(seed: 4)
        let holed = try layer(seed: 5, alpha: { x, _ in x == 63 ? 254 : 255 })
        let folder = SceneStore.folderURL(forVideoPath: videoPath)
        XCTAssertTrue(try SceneRenderer.isOpaque(SceneRenderer.decodeRGBA(
            url: folder.appendingPathComponent(opaque.imageFile), device: device
        )))
        XCTAssertFalse(try SceneRenderer.isOpaque(SceneRenderer.decodeRGBA(
            url: folder.appendingPathComponent(holed.imageFile), device: device
        )))
    }
}

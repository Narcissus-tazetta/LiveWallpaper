import CoreGraphics
import Foundation
import ImageIO
@testable import LiveWallpaper
import UniformTypeIdentifiers
import XCTest

final class SceneScriptInputTests: XCTestCase {
    private func scene(_ source: String) -> SceneDocument {
        let layer = SceneLayer(name: "Image", imageFile: "image.png")
        var script = SceneScript(source: source, layerIDs: [layer.id])
        script.modules = [:]
        script.isAuthorized = true
        var document = SceneDocument(canvasWidth: 100, canvasHeight: 80, layers: [layer])
        document.scripts = [script]
        return document
    }

    func testPressesAndMediaOnlyReachScriptsThatAskForThem() throws {
        var document = scene("""
        export function update(c){return [{id:c.targets[0].id,values:{offsetX:c.pointerPresses.length/10+c.pointer.x,
          offsetY:c.media.isAvailable?c.media.title.length/100:0}}];}
        """)
        var input = SceneFrameInput(cursor: SIMD2(0.25, 0.5))
        input.pointerPresses = [.init(isDown: true, position: SIMD2(0.25, 0.5)), .init(isDown: false, position: SIMD2(0.25, 0.5))]
        input.media = SceneMediaState(isAvailable: true, playback: .playing, title: "Song")
        XCTAssertThrowsError(try SceneFrameEvaluator().evaluate(document, input: input, timeOfDay: .day))
        document.scripts[0].usesCursor = true
        XCTAssertThrowsError(try SceneFrameEvaluator().evaluate(document, input: input, timeOfDay: .day)) {
            XCTAssertTrue(($0 as? SceneScriptIssue)?.message.contains("media") == true, "\($0)")
        }
        document.scripts[0].usesMedia = true
        let id = document.layers[0].id
        let frame = try SceneFrameEvaluator().evaluate(document, input: input, timeOfDay: .day)
        XCTAssertEqual(frame.layers[id]!.transform.offsetX, 0.45, accuracy: 1e-6)
        XCTAssertEqual(frame.layers[id]!.transform.offsetY, 0.04, accuracy: 1e-6)
        // A bake has no player to read from: the script sees media as unavailable.
        input.media = nil
        let baked = try SceneFrameEvaluator().evaluate(document, input: input, timeOfDay: .day)
        XCTAssertEqual(baked.layers[id]!.transform.offsetY, 0)
    }

    func testOldDocumentsDecodeWithoutTheMediaInput() throws {
        let script = SceneScript(source: "function update(c){return []}", layerIDs: [])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(script)) as? [String: Any])
        json["usesMedia"] = nil
        let decoded = try JSONDecoder().decode(SceneScript.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(decoded.usesMedia)
    }

    func testArtworkPaletteRanksColoursAndPicksReadableText() throws {
        let navy: [UInt8] = [20, 30, 90], yellow: [UInt8] = [250, 220, 40], white: [UInt8] = [255, 255, 255]
        var pixels: [UInt8] = []
        for index in 0 ..< 100 {
            pixels += (index < 60 ? navy : index < 90 ? yellow : white) + [255]
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: 10, height: 10, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 40,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let palette = try SceneMediaPalette(imageData: data as Data)
        func assertColor(_ color: SIMD3<Double>, _ bytes: [UInt8], _ name: String) {
            for (value, byte) in zip([color.x, color.y, color.z], bytes) {
                XCTAssertEqual(value, Double(byte) / 255, accuracy: 0.02, name)
            }
        }
        assertColor(palette.primary, navy, "primary")
        assertColor(palette.secondary, yellow, "secondary")
        assertColor(palette.tertiary, white, "tertiary")
        assertColor(palette.text, yellow, "text")
        assertColor(palette.highContrast, white, "highContrast")
        XCTAssertThrowsError(try SceneMediaPalette(imageData: Data("not an image".utf8)))
    }
}

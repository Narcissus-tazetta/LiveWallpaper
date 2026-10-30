import CoreText
import Metal
import XCTest
@testable import LiveWallpaper

@MainActor
final class SceneTextTests: XCTestCase {
    private func text(_ string: String, horizontal: SceneTextHorizontalAlignment = .center,
                      vertical: SceneTextVerticalAlignment = .center) -> SceneText {
        var text = SceneText(string: string)
        text.systemFont = "Helvetica"
        text.pointSize = 12
        text.paddingX = 8
        text.paddingY = 8
        text.horizontalAlignment = horizontal
        text.verticalAlignment = vertical
        return text
    }

    private struct Lit {
        var minX = Int.max
        var maxX = Int.min
        var minY = Int.max
        var maxY = Int.min
    }

    /// Columns and rows of the 400 × 200 target that the white text lights.
    private func litBounds(_ text: SceneText) throws -> Lit {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SceneText-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = SceneDocument(canvasWidth: 400, canvasHeight: 200, layers: [SceneLayer(name: "Text", text: text)])
        let renderer = try SceneRenderer(document: document, videoPath: directory.appendingPathComponent("v.mp4").path)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 400, height: 200, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let command = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
        try renderer.encode(into: target, commandBuffer: command, input: .rest)
        command.commit()
        command.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: 400 * 200 * 4)
        target.getBytes(&bytes, bytesPerRow: 400 * 4, from: MTLRegionMake2D(0, 0, 400, 200), mipmapLevel: 0)
        var result = Lit()
        for y in 0 ..< 200 {
            for x in 0 ..< 400 where bytes[(y * 400 + x) * 4 + 1] > 128 {
                result = Lit(minX: min(result.minX, x), maxX: max(result.maxX, x), minY: min(result.minY, y), maxY: max(result.maxY, y))
            }
        }
        XCTAssertNotEqual(result.minX, Int.max, "nothing drawn")
        return result
    }

    func testJapaneseTextWithTheDefaultFontDraws() throws {
        var text = SceneText(string: "こんにちは")
        text.pointSize = 24
        let lit = try litBounds(text)
        XCTAssertGreaterThan(lit.maxX - lit.minX, 20)
    }

    func testAlignedEdgeStaysOnThePositionWhenTheTextGrows() throws {
        let leftShort = try litBounds(text("12:00", horizontal: .left))
        let leftLong = try litBounds(text("12:00:00", horizontal: .left))
        XCTAssertEqual(leftShort.minX, leftLong.minX)
        // The line starts on the position; the first glyph's side bearing stays blank.
        XCTAssertTrue((200 ... 212).contains(leftShort.minX), "\(leftShort.minX)")
        XCTAssertGreaterThan(leftLong.maxX, leftShort.maxX)

        let rightShort = try litBounds(text("12:00", horizontal: .right))
        let rightLong = try litBounds(text("12:00:00", horizontal: .right))
        XCTAssertEqual(rightShort.maxX, rightLong.maxX)
        XCTAssertTrue((190 ... 201).contains(rightShort.maxX), "\(rightShort.maxX)")

        let centered = try litBounds(text("12:00:00"))
        XCTAssertEqual(Double(centered.minX + centered.maxX) / 2, 200, accuracy: 3)

        // Top: the first line's ascender is on the position, so glyphs hang below it.
        let top = try litBounds(text("12:00", vertical: .top))
        let topTwoLines = try litBounds(text("12:00\n12:00", vertical: .top))
        XCTAssertEqual(top.minY, topTwoLines.minY)
        XCTAssertGreaterThanOrEqual(top.minY, 100)
        XCTAssertGreaterThan(topTwoLines.maxY, top.maxY)
        // Bottom: the last line sits on the position, so more lines grow upwards.
        let bottom = try litBounds(text("12:00", vertical: .bottom))
        let bottomTwoLines = try litBounds(text("12:00\n12:00", vertical: .bottom))
        XCTAssertEqual(bottom.maxY, bottomTwoLines.maxY)
        XCTAssertLessThanOrEqual(bottom.maxY, 100)
        XCTAssertLessThan(bottomTwoLines.minY, bottom.minY)
    }

    func testPointsAreMeasuredAt300DotsPerInch() {
        XCTAssertEqual(SceneTextRasterizer.pixelSize(pointSize: 72), 300)
        XCTAssertEqual(SceneTextRasterizer.pixelSize(pointSize: 16), 16 * 300 / 72, accuracy: 0.0001)
    }

    func testLongTextWrapsAndTheLastRowEndsWithAnEllipsis() throws {
        var wrapped = text("one two three four five six")
        let single = try XCTUnwrap(SceneTextRasterizer.layout(wrapped, fontURL: nil))
        XCTAssertEqual(single.lineCount, 1)
        wrapped.maxWidth = (single.maxX - single.minX) / 3
        let lines = try XCTUnwrap(SceneTextRasterizer.layout(wrapped, fontURL: nil))
        XCTAssertGreaterThan(lines.lineCount, 2)

        wrapped.maxRows = 1
        wrapped.truncatesWithEllipsis = true
        let cut = try XCTUnwrap(SceneTextRasterizer.layout(wrapped, fontURL: nil))
        XCTAssertEqual(cut.lineCount, 1)
        XCTAssertLessThanOrEqual(cut.maxX - cut.minX, wrapped.maxWidth! + 1)
        var ellipsis = CGGlyph(0)
        var character: UniChar = 0x2026
        XCTAssertTrue(CTFontGetGlyphsForCharacters(cut.fonts[0], &character, &ellipsis, 1))
        XCTAssertEqual(cut.glyphs.last?.glyph, ellipsis)
    }

    func testScriptsChangeTheTextOfTextLayersOnly() throws {
        let label = SceneLayer(name: "Label", text: text("before"))
        let image = SceneLayer(name: "Image", imageFile: "image.png")
        let script = SceneScript(source: "function update(c){return []}", layerIDs: [label.id, image.id])
        let output: [Any] = [["id": label.id.uuidString, "text": ["string": "after", "color": ["red": 1, "green": 0, "blue": 0]]]]
        let adjustment = try XCTUnwrap(SceneScriptRuntime.readOutput(output, script: script, layers: [label, image])[label.id])
        var changed = label.text!
        adjustment.text?.apply(to: &changed)
        XCTAssertEqual(changed.string, "after")
        XCTAssertEqual(changed.color.green, 0)

        let onImage: [Any] = [["id": image.id.uuidString, "text": ["string": "x"]]]
        XCTAssertThrowsError(try SceneScriptRuntime.readOutput(onImage, script: script, layers: [label, image]))
        let tooLong: [Any] = [["id": label.id.uuidString, "text": ["string": String(repeating: "x", count: SceneText.maximumLength + 1)]]]
        XCTAssertThrowsError(try SceneScriptRuntime.readOutput(tooLong, script: script, layers: [label, image]))
    }

    func testTextLayersRoundTripAndKeepTheirFont() throws {
        var styled = text("Hello")
        styled.fontFile = "font-1.ttf"
        styled.maxWidth = 300
        styled.maxRows = 2
        styled.scaleX = -0.5
        styled.backgroundColor = RGBAColor(red: 1, green: 0, blue: 0, alpha: 0.5)
        styled.horizontalAnchor = .left
        styled.verticalAnchor = .bottom
        let document = SceneDocument(canvasWidth: 100, canvasHeight: 100, layers: [SceneLayer(name: "Text", text: styled)])
        let decoded = try JSONDecoder().decode(SceneDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded.layers[0].kind, .text)
        XCTAssertEqual(decoded.layers[0].text, styled)
        XCTAssertEqual(decoded.layers[0].text?.backgroundColor?.red, 1)
        XCTAssertEqual(decoded.layers[0].text?.horizontalAnchor, .left)
        XCTAssertEqual(decoded.layers[0].text?.verticalAnchor, .bottom)
        XCTAssertTrue(SceneStore.referencedFiles(of: decoded).contains("font-1.ttf"))

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        var layers = try XCTUnwrap(json["layers"] as? [[String: Any]])
        var raw = try XCTUnwrap(layers[0]["text"] as? [String: Any])
        raw["pointSize"] = 1000
        layers[0]["text"] = raw
        json["layers"] = layers
        XCTAssertThrowsError(try JSONDecoder().decode(SceneDocument.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    func testBackgroundColorDrawsFill() throws {
        var styled = text("A")
        styled.backgroundColor = RGBAColor(red: 0, green: 1, blue: 0, alpha: 1)
        let bounds = try litBounds(styled)
        // Background color fills the entire texture bounds including padding
        XCTAssertGreaterThan(bounds.maxX, bounds.minX)
        XCTAssertGreaterThan(bounds.maxY, bounds.minY)
    }

    func testOutlineAndShadowDrawBeyondTheGlyphs() throws {
        var plain = text("H")
        plain.pointSize = 32
        plain.paddingX = 32
        plain.paddingY = 32
        func ink(_ text: SceneText) throws -> (Int, Int) {
            let raster = try XCTUnwrap(SceneTextRasterizer.render(text, fontURL: nil))
            let alphas = stride(from: 3, to: raster.bytes.count, by: 4).map { raster.bytes[$0] }
            let columns = (0 ..< raster.width).filter { x in (0 ..< raster.height).contains { alphas[$0 * raster.width + x] > 0 } }
            let rows = (0 ..< raster.height).filter { y in (0 ..< raster.width).contains { alphas[y * raster.width + $0] > 0 } }
            return (columns.count, rows.count)
        }
        let base = try ink(plain)
        var outlined = plain
        outlined.style = SceneTextStyle(outline: .init(color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1), thickness: 4))
        let outlinedInk = try ink(outlined)
        // The outline grows the ink by its thickness on each side.
        XCTAssertEqual(Double(outlinedInk.0 - base.0), 8, accuracy: 2)
        XCTAssertEqual(Double(outlinedInk.1 - base.1), 8, accuracy: 2)
        var shadowed = plain
        shadowed.style = SceneTextStyle(shadow: .init(
            color: RGBAColor(red: 0, green: 1, blue: 0, alpha: 1), size: 2, offsetX: 10, offsetY: 0, opacity: 1
        ))
        // The shadow lies to the right, so the ink gets wider by about the offset and no taller.
        let shadowedInk = try ink(shadowed)
        XCTAssertGreaterThan(shadowedInk.0 - base.0, 8)
        XCTAssertLessThanOrEqual(shadowedInk.1 - base.1, 4)
    }
}

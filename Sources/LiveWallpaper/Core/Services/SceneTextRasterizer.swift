import CoreGraphics
import CoreText
import Foundation

/// Lays out and draws a text layer. The rules follow how imported scene packages
/// expect their text to sit (FreeType metrics at 300 dpi, whole-pixel advances,
/// alignment relative to the ink box), so their clocks and titles keep their place.
enum SceneTextRasterizer {
    static let maxTextureEdge = 8192

    struct Glyph: Equatable {
        var glyph: CGGlyph
        var fontIndex: Int
        /// Baseline position in text pixels, y up.
        var x: Double
        var y: Double
    }

    struct Layout {
        var glyphs: [Glyph]
        var fonts: [CTFont]
        var lineCount: Int
        var minX: Double
        var maxX: Double
        var minY: Double
        var maxY: Double
        /// Where the centre of the bounds sits relative to the layer's position, in
        /// text pixels with y up.
        var anchorOffset: SIMD2<Double>

        var center: SIMD2<Double> {
            SIMD2((minX + maxX) / 2, (minY + maxY) / 2)
        }
    }

    struct Raster {
        var width: Int
        var height: Int
        /// sRGB RGBA8, premultiplied, top row first.
        var bytes: [UInt8]
        /// The texture's size on the canvas at a transform scale of 1.
        var canvasSize: SIMD2<Double>
        /// From the layer's position to the texture's centre in canvas pixels, y up,
        /// before the layer's rotation and scale.
        var centerOffset: SIMD2<Double>
    }

    enum Failure: LocalizedError {
        case unreadableFont(String)
        case drawingFailed

        var errorDescription: String? {
            switch self {
            case let .unreadableFont(name): "Cannot read the font \(name)"
            case .drawingFailed: "Cannot draw the text"
            }
        }
    }

    /// nil when there is nothing to draw.
    static func render(_ text: SceneText, fontURL: URL?) throws -> Raster? {
        guard let layout = try layout(text, fontURL: fontURL), !layout.glyphs.isEmpty else {
            return nil
        }
        let scale = SIMD2(abs(text.scaleX), abs(text.scaleY))
        let size = SIMD2(layout.maxX - layout.minX + 2 * text.paddingX, layout.maxY - layout.minY + 2 * text.paddingY) * scale
        let fit = min(1, Double(maxTextureEdge) / max(size.x, size.y, 1))
        let width = max(Int((size.x * fit).rounded(.up)), 1)
        let height = max(Int((size.y * fit).rounded(.up)), 1)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drew: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.setShouldAntialias(true)
            context.setShouldSmoothFonts(false)
            context.setAllowsFontSubpixelPositioning(true)
            context.setShouldSubpixelPositionFonts(true)
            if let bg = text.backgroundColor, bg.alpha > 0 {
                context.setFillColor(bg.nsColor.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            context.setFillColor(text.color.nsColor.withAlphaComponent(1).cgColor)
            context.translateBy(x: Double(width) / 2, y: Double(height) / 2)
            context.scaleBy(x: text.scaleX * fit, y: text.scaleY * fit)
            context.translateBy(x: -layout.center.x, y: -layout.center.y)
            for (index, font) in layout.fonts.enumerated() {
                let glyphs = layout.glyphs.filter { $0.fontIndex == index }
                guard !glyphs.isEmpty else { continue }
                CTFontDrawGlyphs(font, glyphs.map(\.glyph), glyphs.map { CGPoint(x: $0.x, y: $0.y) }, glyphs.count, context)
            }
            return true
        }
        guard drew else { throw Failure.drawingFailed }
        return Raster(
            width: width, height: height, bytes: bytes,
            canvasSize: SIMD2(Double(width), Double(height)) / fit,
            centerOffset: layout.anchorOffset * SIMD2(text.scaleX, text.scaleY)
        )
    }

    /// The pixel size FreeType uses for a point size at 300 dpi; it takes the size in
    /// 26.6 fixed point, dropping the rest.
    static func pixelSize(pointSize: Double) -> Double {
        let points = min(max(pointSize, SceneText.pointSizeRange.lowerBound), SceneText.pointSizeRange.upperBound)
        return (points * 64).rounded(.down) / 64 * 300 / 72
    }

    static func font(_ text: SceneText, fontURL: URL?) throws -> CTFont {
        let size = pixelSize(pointSize: text.pointSize)
        if let fontURL {
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as? [CTFontDescriptor],
                  let descriptor = descriptors.first
            else { throw Failure.unreadableFont(fontURL.lastPathComponent) }
            return CTFontCreateWithFontDescriptor(descriptor, size, nil)
        }
        if let name = text.systemFont {
            return CTFontCreateWithName(name as CFString, size, nil)
        }
        return CTFontCreateUIFontForLanguage(.system, size, nil)!
    }

    private struct ShapedGlyph {
        var glyph: CGGlyph
        var fontIndex: Int
        var cluster: Int
        var character: UInt32
        var advance: Double
        var offsetX: Double
        var offsetY: Double
        /// Ink box relative to the pen, whole pixels.
        var left: Double
        var bottom: Double
        var right: Double
        var top: Double
    }

    private struct Line {
        var glyphs: [ShapedGlyph]
        var wrapped: Bool
    }

    /// A line in its own pen space, with every glyph's pen position.
    private struct MeasuredLine {
        var glyphs: [(glyph: ShapedGlyph, pen: Double)]
        var minX: Double
        var maxX: Double
        var minY: Double
        var maxY: Double
    }

    private static func isBreakingSpace(_ character: UInt32) -> Bool {
        character == 0x09 || character == 0x0D || character == 0x20
    }

    static func layout(_ text: SceneText, fontURL: URL?) throws -> Layout? {
        guard !text.string.isEmpty else { return nil }
        let base = try font(text, fontURL: fontURL)
        // FreeType's grid-fitted size metrics: ascender rounded up, descender down,
        // line height to the nearest pixel.
        let ascender = CTFontGetAscent(base).rounded(.up)
        let descender = (-CTFontGetDescent(base)).rounded(.down)
        let lineHeight = (CTFontGetAscent(base) + CTFontGetDescent(base) + CTFontGetLeading(base)).rounded() + text.lineSpacing
        var fonts: [CTFont] = [base]
        let measured = breakLines(text) { shape($0, base: base, letterSpacing: text.letterSpacing, fonts: &fonts) }
            .map { measure($0, text: text) }

        let blockWidth = measured.map { $0.maxX - $0.minX }.max() ?? 0
        var minX = 0.0, maxX = 0.0, inkMinY = 0.0, inkMaxY = 0.0
        var glyphs: [Glyph] = []
        for (row, line) in measured.enumerated() {
            minX = min(minX, line.minX)
            maxX = max(maxX, line.maxX)
            let baseline = -Double(row) * lineHeight
            inkMinY = min(inkMinY, baseline + line.minY)
            inkMaxY = max(inkMaxY, baseline + line.maxY)
            let width = line.maxX - line.minX
            let start = switch text.horizontalAlignment {
            case .left: 0.0
            case .center: (blockWidth - width) * 0.5
            case .right: blockWidth - width
            }
            for (glyph, pen) in line.glyphs {
                glyphs.append(Glyph(glyph: glyph.glyph, fontIndex: glyph.fontIndex,
                                    x: start + pen + glyph.offsetX, y: baseline + glyph.offsetY))
            }
        }
        let rows = Double(measured.count)
        let maxY = max(ascender, inkMaxY)
        let minY = min(ascender - rows * lineHeight, inkMinY)
        let centerY = (minY + maxY) / 2
        let width = maxX - minX
        let anchorX = switch text.horizontalAnchor ?? text.horizontalAlignment {
        case .left: width * 0.5
        case .center: 0.0
        case .right: -width * 0.5
        }
        let anchorY = switch text.verticalAnchor ?? text.verticalAlignment {
        case .top: centerY - ascender
        case .center: centerY - (ascender - (rows - 1) * lineHeight) * 0.5
        case .bottom: centerY - (descender - (rows - 1) * lineHeight)
        }
        return Layout(
            glyphs: glyphs, fonts: fonts, lineCount: measured.count,
            minX: minX, maxX: maxX, minY: minY, maxY: maxY, anchorOffset: SIMD2(anchorX, anchorY)
        )
    }

    /// Glyphs of one paragraph; fonts CoreText falls back to are added to `fonts`.
    private static func shape(_ string: String, base: CTFont, letterSpacing: Double, fonts: inout [CTFont]) -> [ShapedGlyph] {
        let attributed = NSAttributedString(string: string, attributes: [.init(kCTFontAttributeName as String): base])
        let line = CTLineCreateWithAttributedString(attributed)
        let scalars = Array(string.unicodeScalars)
        let utf16Starts = scalarUTF16Offsets(string)
        var result: [ShapedGlyph] = []
        var ctPen = 0.0
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName as String].map { $0 as! CTFont } ?? base // swiftlint:disable:this force_cast
            let fontIndex: Int
            if let existing = fonts.firstIndex(where: { CFEqual($0, runFont) }) {
                fontIndex = existing
            } else {
                fonts.append(runFont)
                fontIndex = fonts.count - 1
            }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            var boxes = [CGRect](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            CTFontGetBoundingRectsForGlyphs(runFont, .horizontal, glyphs, &boxes, count)
            for index in 0 ..< count {
                let scalarIndex = utf16Starts.lastIndex { $0 <= indices[index] } ?? 0
                let box = boxes[index]
                let empty = box.isEmpty || box.isNull
                result.append(ShapedGlyph(
                    glyph: glyphs[index], fontIndex: fontIndex, cluster: indices[index],
                    character: scalars.indices.contains(scalarIndex) ? scalars[scalarIndex].value : 0,
                    // The advance is truncated to whole pixels before the spacing is added.
                    advance: Double(advances[index].width).rounded(.down) + letterSpacing,
                    offsetX: (Double(positions[index].x) - ctPen).rounded(.down),
                    offsetY: Double(positions[index].y).rounded(.down),
                    left: empty ? 0 : Double(box.minX).rounded(.down),
                    bottom: empty ? 0 : Double(box.minY).rounded(.down),
                    right: empty ? 0 : Double(box.maxX).rounded(.up),
                    top: empty ? 0 : Double(box.maxY).rounded(.up)
                ))
                ctPen += Double(advances[index].width)
            }
        }
        return result
    }

    /// Paragraphs split at line feeds, wrapped at `maxWidth` before the glyph that
    /// crosses it (spaces may hang over), and cut at `maxRows`.
    private static func breakLines(_ text: SceneText, shape: (String) -> [ShapedGlyph]) -> [Line] {
        let ellipsis = shape("\u{2026}")
        var paragraphs = text.string.components(separatedBy: "\n")
        if let maxRows = text.maxRows, paragraphs.count > maxRows {
            paragraphs = Array(paragraphs.prefix(maxRows))
            if text.truncatesWithEllipsis { paragraphs[maxRows - 1] += "\u{2026}" }
        }
        var lines: [Line] = []
        for paragraph in paragraphs {
            var remaining = shape(paragraph)
            while true {
                guard let maxWidth = text.maxWidth, let cut = wrapIndex(remaining, maxWidth: maxWidth) else {
                    lines.append(Line(glyphs: remaining, wrapped: false))
                    break
                }
                if let maxRows = text.maxRows, lines.count + 1 >= maxRows {
                    var kept = Array(remaining[..<cut])
                    if text.truncatesWithEllipsis {
                        let ellipsisWidth = ellipsis.first.map { $0.offsetX + $0.right } ?? 0
                        while !kept.isEmpty, kept.reduce(0, { $0 + $1.advance }) + ellipsisWidth > maxWidth {
                            kept.removeLast()
                        }
                        kept += ellipsis
                    }
                    lines.append(Line(glyphs: kept, wrapped: false))
                    return lines
                }
                lines.append(Line(glyphs: Array(remaining[..<cut]), wrapped: true))
                remaining = Array(remaining[cut...])
            }
            if let maxRows = text.maxRows, lines.count >= maxRows { break }
        }
        return lines
    }

    private static func wrapIndex(_ glyphs: [ShapedGlyph], maxWidth: Double) -> Int? {
        var pen = 0.0
        for (index, glyph) in glyphs.enumerated() {
            if index > 0, !isBreakingSpace(glyph.character), glyph.cluster != glyphs[index - 1].cluster,
               pen + glyph.offsetX + glyph.right > maxWidth
            {
                return index
            }
            pen += glyph.advance
        }
        return nil
    }

    /// The ink box of a line, never left of its start or below its baseline origin.
    private static func measure(_ line: Line, text: SceneText) -> MeasuredLine {
        var glyphs = line.glyphs
        var pen = 0.0
        var minX = 0.0, maxX = 0.0, minY = 0.0, maxY = 0.0
        for glyph in glyphs {
            minX = min(minX, pen + glyph.offsetX + glyph.left)
            maxX = max(maxX, pen + glyph.offsetX + glyph.right)
            minY = min(minY, glyph.offsetY + glyph.bottom)
            maxY = max(maxY, glyph.offsetY + glyph.top)
            pen += glyph.advance
        }
        let spaces = glyphs.indices.filter { isBreakingSpace(glyphs[$0].character) }
        if text.justifies, line.wrapped, let maxWidth = text.maxWidth, !spaces.isEmpty {
            let extra = (maxWidth - (maxX - minX)) / Double(spaces.count)
            for index in spaces { glyphs[index].advance += extra }
            maxX = minX + maxWidth
        }
        var placed: [(glyph: ShapedGlyph, pen: Double)] = []
        pen = 0
        for glyph in glyphs {
            placed.append((glyph, pen))
            pen += glyph.advance
        }
        return MeasuredLine(glyphs: placed, minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    /// The UTF-16 offset where each Unicode scalar starts; CoreText reports clusters
    /// in UTF-16 units.
    private static func scalarUTF16Offsets(_ string: String) -> [Int] {
        var offsets: [Int] = []
        var offset = 0
        for scalar in string.unicodeScalars {
            offsets.append(offset)
            offset += scalar.utf16.count
        }
        return offsets
    }
}

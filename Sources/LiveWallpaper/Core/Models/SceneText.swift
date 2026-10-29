import Foundation

enum SceneTextHorizontalAlignment: String, Codable, CaseIterable {
    case left
    case center
    case right
}

enum SceneTextVerticalAlignment: String, Codable, CaseIterable {
    case top
    case center
    case bottom
}

/// The outline, blur and drop shadow of Wallpaper Engine's text shader. Sizes are in text pixels.
struct SceneTextStyle: Codable, Equatable {
    struct Outline: Codable, Equatable {
        var color: RGBAColor
        var thickness: Double
    }

    struct Shadow: Codable, Equatable {
        var color: RGBAColor
        var size: Double
        /// Positive x is right, positive y is down.
        var offsetX: Double
        var offsetY: Double
        var opacity: Double
    }

    var outline: Outline?
    var blur: Double?
    var shadow: Shadow?

    var isEmpty: Bool { outline == nil && blur == nil && shadow == nil }

    /// Packages come from anyone: out-of-range values fail the layer instead of reaching the drawing code.
    func validate(in container: KeyedDecodingContainer<SceneText.CodingKeys>) throws {
        var values = [blur ?? 0]
        if let outline { values.append(outline.thickness) }
        if let shadow { values += [shadow.size, shadow.offsetX, shadow.offsetY, shadow.opacity] }
        guard values.allSatisfy({ $0.isFinite && (-1000 ... 1000).contains($0) }) else {
            throw DecodingError.dataCorruptedError(forKey: .style, in: container, debugDescription: "Out of range")
        }
    }
}

/// A text layer's content and style. Sizes are in text pixels, which `scaleX` and
/// `scaleY` turn into canvas pixels.
struct SceneText: Codable, Equatable {
    static let maximumLength = 4096
    static let pointSizeRange = 1.0 ... 256.0
    static let maximumRows = 1000

    var string: String
    /// File in the scene folder; nil uses `systemFont`.
    var fontFile: String?
    /// Family or PostScript name of an installed font, for text without a file.
    var systemFont: String?
    /// Points at 300 dots per inch.
    var pointSize: Double = 32
    var color = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
    var backgroundColor: RGBAColor?
    /// Which edge of the text stays on the layer's position.
    var horizontalAlignment: SceneTextHorizontalAlignment = .center
    var verticalAlignment: SceneTextVerticalAlignment = .center
    var horizontalAnchor: SceneTextHorizontalAlignment?
    var verticalAnchor: SceneTextVerticalAlignment?
    /// Added to every character's advance.
    var letterSpacing: Double = 0
    /// Added to the font's line height.
    var lineSpacing: Double = 0
    /// Clear room around the text, so effects that spread it out are not cut off.
    var paddingX: Double = 0
    var paddingY: Double = 0
    /// Wraps lines longer than this; nil never wraps.
    var maxWidth: Double?
    /// nil shows every line.
    var maxRows: Int?
    /// Ends the last allowed row with "…" when text is cut off there.
    var truncatesWithEllipsis = false
    /// Spreads a wrapped line to `maxWidth` by widening its spaces.
    var justifies = false
    /// Canvas pixels per text pixel at rest; a negative value mirrors that axis.
    var scaleX: Double = 1
    var scaleY: Double = 1
    var style: SceneTextStyle?

    init(string: String) {
        self.string = string
    }

    enum CodingKeys: String, CodingKey {
        case string, fontFile, systemFont, pointSize, color, backgroundColor
        case horizontalAlignment, verticalAlignment, horizontalAnchor, verticalAnchor
        case letterSpacing, lineSpacing, paddingX, paddingY, maxWidth, maxRows, truncatesWithEllipsis
        case justifies, scaleX, scaleY, style
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Packages come from anyone: out-of-range values fail the layer instead of
        // reaching the layout code.
        func finite(_ key: CodingKeys, _ fallback: Double, in range: ClosedRange<Double>) throws -> Double {
            let value = try container.decodeIfPresent(Double.self, forKey: key) ?? fallback
            guard value.isFinite, range.contains(value) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Out of range")
            }
            return value
        }
        string = try container.decode(String.self, forKey: .string)
        guard string.count <= Self.maximumLength else {
            throw DecodingError.dataCorruptedError(forKey: .string, in: container, debugDescription: "Text too long")
        }
        fontFile = try container.decodeIfPresent(String.self, forKey: .fontFile)
        systemFont = try container.decodeIfPresent(String.self, forKey: .systemFont)
        pointSize = try finite(.pointSize, 32, in: Self.pointSizeRange)
        color = try container.decodeIfPresent(RGBAColor.self, forKey: .color) ?? color
        backgroundColor = try container.decodeIfPresent(RGBAColor.self, forKey: .backgroundColor)
        horizontalAlignment = try container.decodeIfPresent(SceneTextHorizontalAlignment.self, forKey: .horizontalAlignment) ?? .center
        verticalAlignment = try container.decodeIfPresent(SceneTextVerticalAlignment.self, forKey: .verticalAlignment) ?? .center
        horizontalAnchor = try container.decodeIfPresent(SceneTextHorizontalAlignment.self, forKey: .horizontalAnchor)
        verticalAnchor = try container.decodeIfPresent(SceneTextVerticalAlignment.self, forKey: .verticalAnchor)
        letterSpacing = try finite(.letterSpacing, 0, in: -10000 ... 10000)
        lineSpacing = try finite(.lineSpacing, 0, in: -10000 ... 10000)
        paddingX = try finite(.paddingX, 0, in: 0 ... 512)
        paddingY = try finite(.paddingY, 0, in: 0 ... 512)
        if container.contains(.maxWidth) {
            maxWidth = try finite(.maxWidth, 0, in: 1 ... 100_000)
        }
        maxRows = try container.decodeIfPresent(Int.self, forKey: .maxRows)
        if let maxRows, !(1 ... Self.maximumRows).contains(maxRows) {
            throw DecodingError.dataCorruptedError(forKey: .maxRows, in: container, debugDescription: "Out of range")
        }
        truncatesWithEllipsis = try container.decodeIfPresent(Bool.self, forKey: .truncatesWithEllipsis) ?? false
        justifies = try container.decodeIfPresent(Bool.self, forKey: .justifies) ?? false
        scaleX = try finite(.scaleX, 1, in: -1000 ... 1000)
        scaleY = try finite(.scaleY, 1, in: -1000 ... 1000)
        style = try container.decodeIfPresent(SceneTextStyle.self, forKey: .style)
        try style?.validate(in: container)
        guard scaleX != 0, scaleY != 0 else {
            throw DecodingError.dataCorruptedError(forKey: .scaleX, in: container, debugDescription: "Zero scale")
        }
    }
}

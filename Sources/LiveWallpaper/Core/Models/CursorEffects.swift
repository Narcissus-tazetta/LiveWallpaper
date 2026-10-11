import AppKit

enum CursorEffectLevel: String, Codable, CaseIterable {
    case low
    case medium
    case high
}

enum CursorTrailColor: String, Codable, CaseIterable {
    case white
    case accent
    case rainbow
    case custom
}

struct RGBAColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: NSColor) {
        let srgb = color.usingColorSpace(.sRGB) ?? .white
        self.init(
            red: Double(srgb.redComponent), green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent), alpha: Double(srgb.alphaComponent)
        )
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// Cursor-driven effects drawn on top of video wallpapers (not web wallpapers).
struct CursorEffectsSettings: Codable, Equatable {
    var parallaxEnabled = false
    var parallaxStrength: CursorEffectLevel = .medium
    var spotlightEnabled = false
    var spotlightSize: CursorEffectLevel = .medium
    var spotlightDarkness: CursorEffectLevel = .medium
    var trailEnabled = false
    var trailColor: CursorTrailColor = .white
    var trailCustomColor = RGBAColor(red: 1, green: 0.8, blue: 0.35, alpha: 1)
    var trailAmount: CursorEffectLevel = .medium

    init() {}

    // Missing keys fall back to the defaults so settings saved by an older build,
    // before an effect existed, still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CursorEffectsSettings()
        parallaxEnabled = try c.decodeIfPresent(Bool.self, forKey: .parallaxEnabled) ?? d.parallaxEnabled
        parallaxStrength = try c.decodeIfPresent(CursorEffectLevel.self, forKey: .parallaxStrength) ?? d.parallaxStrength
        spotlightEnabled = try c.decodeIfPresent(Bool.self, forKey: .spotlightEnabled) ?? d.spotlightEnabled
        spotlightSize = try c.decodeIfPresent(CursorEffectLevel.self, forKey: .spotlightSize) ?? d.spotlightSize
        spotlightDarkness = try c.decodeIfPresent(CursorEffectLevel.self, forKey: .spotlightDarkness) ?? d.spotlightDarkness
        trailEnabled = try c.decodeIfPresent(Bool.self, forKey: .trailEnabled) ?? d.trailEnabled
        trailColor = try c.decodeIfPresent(CursorTrailColor.self, forKey: .trailColor) ?? d.trailColor
        trailCustomColor = try c.decodeIfPresent(RGBAColor.self, forKey: .trailCustomColor) ?? d.trailCustomColor
        trailAmount = try c.decodeIfPresent(CursorEffectLevel.self, forKey: .trailAmount) ?? d.trailAmount
    }

    var anyEnabled: Bool {
        parallaxEnabled || spotlightEnabled || trailEnabled
    }

    /// Largest shift as a fraction of the screen size; the content is scaled up by
    /// twice this so the edges never show.
    var parallaxAmplitude: CGFloat {
        switch parallaxStrength {
        case .low: 0.01
        case .medium: 0.02
        case .high: 0.03
        }
    }

    var spotlightRadius: CGFloat {
        switch spotlightSize {
        case .low: 140
        case .medium: 220
        case .high: 320
        }
    }

    var spotlightOpacity: CGFloat {
        switch spotlightDarkness {
        case .low: 0.25
        case .medium: 0.4
        case .high: 0.6
        }
    }

    var trailBirthRate: Float {
        switch trailAmount {
        case .low: 40
        case .medium: 90
        case .high: 180
        }
    }
}

enum CursorEffectGeometry {
    /// Shift for a cursor at `cursor` (in the screen's own coordinates, origin at its
    /// bottom-left). The content moves against the cursor: centre gives zero, an edge
    /// gives the full amplitude, and positions past the edge are clamped.
    static func parallaxOffset(cursor: CGPoint, screenSize: CGSize, amplitude: CGFloat) -> CGSize {
        guard screenSize.width > 0, screenSize.height > 0 else {
            return .zero
        }
        func normalized(_ value: CGFloat, _ length: CGFloat) -> CGFloat {
            min(max((value - length / 2) / (length / 2), -1), 1)
        }
        return CGSize(
            width: -normalized(cursor.x, screenSize.width) * amplitude * screenSize.width,
            height: -normalized(cursor.y, screenSize.height) * amplitude * screenSize.height
        )
    }

    static func parallaxScale(amplitude: CGFloat) -> CGFloat {
        1 + 2 * amplitude
    }
}

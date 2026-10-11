import AppKit

enum CursorEffectLevel: String, Codable, CaseIterable {
    case low
    case medium
    case high
}

enum CursorTrailShape: String, Codable, CaseIterable {
    case glow
    case sparkle
    case bubble
    case snow
}

enum CursorClickStyle: String, Codable, CaseIterable {
    case ripple
    case burst
}

enum CursorEffectColor: String, Codable, CaseIterable {
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

    /// Clamped: packages can come from anyone.
    var nsColor: NSColor {
        func unit(_ value: Double) -> CGFloat {
            CGFloat(min(max(value.isFinite ? value : 1, 0), 1))
        }
        return NSColor(srgbRed: unit(red), green: unit(green), blue: unit(blue), alpha: unit(alpha))
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
    var trailColor: CursorEffectColor = .white
    var trailCustomColor = RGBAColor(red: 1, green: 0.8, blue: 0.35, alpha: 1)
    var trailAmount: CursorEffectLevel = .medium
    var trailShape: CursorTrailShape = .glow
    var clickEnabled = false
    var clickStyle: CursorClickStyle = .ripple
    var clickColor: CursorEffectColor = .white
    var clickCustomColor = RGBAColor(red: 0.45, green: 0.75, blue: 1, alpha: 1)
    /// Stop everything, mouse monitoring included, while another app is frontmost.
    var onlyWhileDesktopActive = true

    init() {}

    // Missing keys, and values this version does not know (a shape added later, say),
    // fall back to the default for that field only: settings arrive in packages made
    // by other versions, and one unknown value must not fail the whole import.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CursorEffectsSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            do {
                return try c.decodeIfPresent(T.self, forKey: key) ?? fallback
            } catch {
                AppLog.persistence.error(
                    "cursor effect setting \(key.stringValue, privacy: .public) unreadable; using the default"
                )
                return fallback
            }
        }
        parallaxEnabled = value(.parallaxEnabled, d.parallaxEnabled)
        parallaxStrength = value(.parallaxStrength, d.parallaxStrength)
        spotlightEnabled = value(.spotlightEnabled, d.spotlightEnabled)
        spotlightSize = value(.spotlightSize, d.spotlightSize)
        spotlightDarkness = value(.spotlightDarkness, d.spotlightDarkness)
        trailEnabled = value(.trailEnabled, d.trailEnabled)
        trailColor = value(.trailColor, d.trailColor)
        trailCustomColor = value(.trailCustomColor, d.trailCustomColor)
        trailAmount = value(.trailAmount, d.trailAmount)
        trailShape = value(.trailShape, d.trailShape)
        clickEnabled = value(.clickEnabled, d.clickEnabled)
        clickStyle = value(.clickStyle, d.clickStyle)
        clickColor = value(.clickColor, d.clickColor)
        clickCustomColor = value(.clickCustomColor, d.clickCustomColor)
        onlyWhileDesktopActive = value(.onlyWhileDesktopActive, d.onlyWhileDesktopActive)
    }

    var anyEnabled: Bool {
        parallaxEnabled || spotlightEnabled || trailEnabled || clickEnabled
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

    var trailAppearance: CursorTrailAppearance {
        CursorTrailAppearance(
            shape: trailShape, color: trailColor, customColor: trailCustomColor, birthRate: trailBirthRate
        )
    }

    var trailBirthRate: Float {
        switch trailAmount {
        case .low: 40
        case .medium: 90
        case .high: 180
        }
    }
}

struct CursorTrailAppearance: Equatable {
    var shape: CursorTrailShape
    var color: CursorEffectColor
    var customColor: RGBAColor
    var birthRate: Float
}

/// One on-screen window as CGWindowList reports it (front to back), reduced to
/// what deciding "was this click on the desktop" needs. Readable without Screen
/// Recording permission; only window titles are withheld.
struct OnScreenWindow: Equatable {
    var ownerPID: pid_t
    /// Owned by the window server itself (menu bar, backdrop strips), which has no
    /// running-application entry to match by PID.
    var isWindowServer: Bool
    var layer: Int
    /// Global coordinates with the origin at the top-left of the main display.
    var bounds: CGRect
    var alpha: Double
}

enum DesktopClickDetector {
    /// kCGDesktopIconWindowLevel: Finder's desktop (icons) window.
    static let desktopIconLayer = Int(CGWindowLevelForKey(.desktopIconWindow))

    /// Whether the frontmost window under `point` is Finder's desktop. The Dock owns a
    /// transparent window over the whole screen and the window server owns
    /// invisible strips below the menu bar, so those are looked through. Desktop
    /// widgets sit just above the desktop and do count as being in front of it.
    static func isDesktopClick(
        at point: CGPoint, windows: [OnScreenWindow], finderPID: pid_t?, dockPID: pid_t?, ownPID: pid_t
    ) -> Bool {
        for window in windows {
            guard window.alpha > 0, !window.bounds.isEmpty, window.bounds.contains(point) else {
                continue
            }
            if window.ownerPID == dockPID || window.ownerPID == ownPID {
                continue
            }
            if window.isWindowServer, window.layer < 0 {
                continue
            }
            return window.ownerPID == finderPID && window.layer == desktopIconLayer
        }
        return false
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

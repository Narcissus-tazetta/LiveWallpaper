import CoreImage
import Foundation
import simd

/// How a web wallpaper's page is shown: mirrored, and colour-adjusted as the original's
/// colour options do it. The package names which of its properties drive each part.
struct WebDisplayAdjustment: Equatable {
    /// The original's colour pass on the page's 8-bit colours: contrast about mid grey, then
    /// value, saturation and hue in HSV, in that order.
    struct Color: Equatable {
        var value: Float
        var contrast: Float
        var saturation: Float
        var hue: Float
    }

    var flipsHorizontally = false
    /// Nil when the colour options are off or leave every colour as it is.
    var color: Color?

    /// `keys` maps `flipHorizontally`, `colorEnabled`, `brightness`, `contrast`, `saturation`
    /// and `hue` to property ids. The sliders run 0 to 100 with 50 as neutral.
    init(keys: [String: String]?, values: [String: WebPropertyValue]) {
        guard let keys else { return }
        func flag(_ name: String) -> Bool {
            guard let id = keys[name], case let .bool(value)? = values[id] else { return false }
            return value
        }
        func slider(_ name: String) -> Float {
            guard let id = keys[name], case let .number(value)? = values[id] else { return 50 }
            return Float(value)
        }
        flipsHorizontally = flag("flipHorizontally")
        let brightness = slider("brightness") / 50
        let contrast = slider("contrast") / 50
        let saturation = slider("saturation") / 50
        let hue = slider("hue") / 100 - 0.5
        // The original skips the pass when every slider is at its neutral value.
        guard flag("colorEnabled"), brightness != 1 || contrast != 1 || saturation != 1 || hue != 0
        else { return }
        color = Color(
            value: pow(brightness, 2),
            contrast: pow(contrast, 0.5),
            saturation: pow(saturation, 0.5),
            hue: hue
        )
    }

    init() {}
}

extension WebDisplayAdjustment.Color {
    static let cubeDimension = 64

    func apply(red: Float, green: Float, blue: Float) -> SIMD3<Float> {
        let albedo = SIMD3<Float>(repeating: 0.5) + (SIMD3(red, green, blue) - 0.5) * contrast
        var hsv = Self.hsv(albedo)
        hsv.z *= value
        hsv.y *= saturation
        hsv.x += hue
        return simd_clamp(Self.rgb(hsv), SIMD3(repeating: 0), SIMD3(repeating: 1))
    }

    /// The original shader's conversions, kept exact (including the 1e-10 guards and the
    /// unclamped input) so that the colours match it.
    private static func hsv(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let p: SIMD4<Float> = rgb.y < rgb.z
            ? SIMD4(rgb.z, rgb.y, -1, 2.0 / 3.0) : SIMD4(rgb.y, rgb.z, 0, -1.0 / 3.0)
        let q: SIMD4<Float> = rgb.x < p.x
            ? SIMD4(p.x, p.y, p.w, rgb.x) : SIMD4(rgb.x, p.y, p.z, p.x)
        let chroma = q.x - min(q.w, q.y)
        let hue = abs((q.w - q.y) / (6 * chroma + 1e-10) + q.z)
        return SIMD3(hue, chroma / (q.x + 1e-10), q.x)
    }

    private static func rgb(_ hsv: SIMD3<Float>) -> SIMD3<Float> {
        let shifted = SIMD3<Float>(repeating: hsv.x) + SIMD3(1, 2.0 / 3.0, 1.0 / 3.0)
        let p = abs((shifted - shifted.rounded(.down)) * 6 - 3)
        let mixed = simd_clamp(p - 1, SIMD3(repeating: 0), SIMD3(repeating: 1))
        return hsv.z * (SIMD3(repeating: 1) + (mixed - 1) * hsv.y)
    }

    /// Layer filters that run the pass on a layer's content. Only Core Image's built-in
    /// filters run on a layer that hosts web content, so the pass is baked into a colour
    /// cube; the tone curves around it make the cube read and write the 8-bit sRGB values
    /// the original works on rather than linear light.
    func layerFilters() -> [CIFilter] {
        let size = Self.cubeDimension
        var cube = [Float]()
        cube.reserveCapacity(size * size * size * 4)
        let scale = 1 / Float(size - 1)
        for blue in 0 ..< size {
            for green in 0 ..< size {
                for red in 0 ..< size {
                    let color = apply(red: Float(red) * scale, green: Float(green) * scale, blue: Float(blue) * scale)
                    cube += [color.x, color.y, color.z, 1]
                }
            }
        }
        let filter = CIFilter(name: "CIColorCube")!
        filter.setValue(size, forKey: "inputCubeDimension")
        filter.setValue(cube.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: "inputCubeData")
        return [CIFilter(name: "CILinearToSRGBToneCurve")!, filter, CIFilter(name: "CISRGBToneCurveToLinear")!]
    }
}

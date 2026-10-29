import Foundation

/// Wallpaper Engine's text shader draws outline, blur and drop shadow from a signed distance
/// field of the glyphs. This builds that field from a coverage picture and evaluates the same
/// formulas, in output pixels.
enum SceneTextEffects {
    /// The shader's MSDF range, in atlas texels on each side of an edge.
    private static let atlasRange = 24.0

    /// `coverage` is the glyphs' alpha, top row first; `pixelsPerTextPixel` is how large a text pixel is in it.
    /// Returns premultiplied RGBA8, `background` (premultiplied) underneath.
    static func render(
        coverage: [UInt8], width: Int, height: Int, style: SceneTextStyle, fill: RGBAColor,
        background: RGBAColor?, pointSize: Double, pixelsPerTextPixel s: Double
    ) -> [UInt8] {
        let distance = signedDistance(coverage: coverage, width: width, height: height)
        // The atlas holds 32 texels per em at the size the uniforms are scaled for: `a * size` texels
        // are `size` text pixels, so a texel is `pointSize / 7.68` text pixels wide.
        let texel = s * pointSize / 7.68
        let reach = atlasRange / 2 * texel
        let blurOn = style.blur != nil
        let smooth = blurOn || style.shadow != nil
        let outlineWidth = (style.outline?.thickness ?? 0) * s
        // Without blur the main picture reads the distance in screen pixels and smooths over half a pixel.
        let mainHalf = blurOn ? max((style.blur ?? 0) * s, 0.5 * texel) : 0.5

        func coverageAt(_ d: Double, extra: Double, half: Double, smoothed: Bool) -> Double {
            if smoothed {
                let t = min(max((d + extra + half) / (2 * half), 0), 1)
                return t * t * (3 - 2 * t)
            }
            return min(max(d + 0.5 + extra, 0), 1)
        }
        func sample(_ x: Double, _ y: Double) -> Double {
            let fx = min(max(x, 0), Double(width - 1)), fy = min(max(y, 0), Double(height - 1))
            let x0 = Int(fx), y0 = Int(fy), x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
            let tx = fx - Double(x0), ty = fy - Double(y0)
            let d00 = Double(distance[y0 * width + x0]), d10 = Double(distance[y0 * width + x1])
            let d01 = Double(distance[y1 * width + x0]), d11 = Double(distance[y1 * width + x1])
            let top: Double = d00 * (1 - tx) + d10 * tx
            let bottom: Double = d01 * (1 - tx) + d11 * tx
            return top * (1 - ty) + bottom * ty
        }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let bg = background.map { ($0.red * $0.alpha, $0.green * $0.alpha, $0.blue * $0.alpha, $0.alpha) } ?? (0, 0, 0, 0)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let d = min(max(Double(distance[y * width + x]), -reach), reach)
                let fillCoverage = coverageAt(d, extra: 0, half: mainHalf, smoothed: smooth)
                var rgb = SIMD3(fill.red, fill.green, fill.blue)
                var alpha = fillCoverage
                if let outline = style.outline {
                    let outlineCoverage = coverageAt(d, extra: outlineWidth, half: mainHalf, smoothed: smooth)
                    let edge = SIMD3(outline.color.red, outline.color.green, outline.color.blue)
                    rgb = edge + (rgb - edge) * fillCoverage
                    alpha = outlineCoverage
                }
                if let shadow = style.shadow {
                    let shifted = min(max(sample(Double(x) - shadow.offsetX * s, Double(y) - shadow.offsetY * s), -reach), reach)
                    let extra = style.outline == nil ? 0 : outlineWidth
                    let half = max(shadow.size * s, 0.5 * texel)
                    let shadowAlpha = min(max(shadow.opacity * coverageAt(shifted, extra: extra, half: half, smoothed: true), 0), 1)
                    let out = alpha + shadowAlpha * (1 - alpha)
                    let color = SIMD3(shadow.color.red, shadow.color.green, shadow.color.blue)
                    rgb = out > 1e-6 ? (rgb * alpha + color * shadowAlpha * (1 - alpha)) / out : rgb
                    alpha = out
                }
                let index = (y * width + x) * 4
                let premultiplied = rgb * alpha
                let channels = [
                    premultiplied.x + bg.0 * (1 - alpha), premultiplied.y + bg.1 * (1 - alpha),
                    premultiplied.z + bg.2 * (1 - alpha), alpha + bg.3 * (1 - alpha),
                ]
                for (offset, value) in channels.enumerated() {
                    bytes[index + offset] = UInt8((min(max(value, 0), 1) * 255).rounded())
                }
            }
        }
        return bytes
    }

    /// Signed distance to the glyph edge in pixels, positive inside. A pixel only partly covered puts the edge
    /// `coverage - 0.5` from its centre, which keeps the field smooth across anti-aliased edges.
    static func signedDistance(coverage: [UInt8], width: Int, height: Int) -> [Float] {
        let far = 1e20
        var outside = [Double](repeating: 0, count: width * height)
        var inside = [Double](repeating: 0, count: width * height)
        for index in coverage.indices {
            let c = Double(coverage[index]) / 255
            if c >= 1 {
                outside[index] = 0
                inside[index] = far
            } else if c <= 0 {
                outside[index] = far
                inside[index] = 0
            } else {
                let edge = 0.5 - c
                outside[index] = max(0, edge) * max(0, edge)
                inside[index] = max(0, -edge) * max(0, -edge)
            }
        }
        squaredDistance(&outside, width: width, height: height)
        squaredDistance(&inside, width: width, height: height)
        return (0 ..< width * height).map { Float(inside[$0].squareRoot() - outside[$0].squareRoot()) }
    }

    /// Felzenszwalb–Huttenlocher squared Euclidean distance transform, in place.
    private static func squaredDistance(_ grid: inout [Double], width: Int, height: Int) {
        let size = max(width, height)
        var f = [Double](repeating: 0, count: size)
        var out = [Double](repeating: 0, count: size)
        var v = [Int](repeating: 0, count: size)
        var z = [Double](repeating: 0, count: size + 1)
        func transform(count: Int) {
            var k = 0
            v[0] = 0
            z[0] = -.infinity
            z[1] = .infinity
            func intersection(_ q: Int, _ p: Int) -> Double {
                ((f[q] + Double(q * q)) - (f[p] + Double(p * p))) / Double(2 * q - 2 * p)
            }
            for q in 1 ..< max(count, 1) {
                var s = intersection(q, v[k])
                while s <= z[k] {
                    k -= 1
                    s = intersection(q, v[k])
                }
                k += 1
                v[k] = q
                z[k] = s
                z[k + 1] = .infinity
            }
            k = 0
            for q in 0 ..< count {
                while z[k + 1] < Double(q) { k += 1 }
                let p = v[k]
                out[q] = Double((q - p) * (q - p)) + f[p]
            }
            for q in 0 ..< count { f[q] = out[q] }
        }
        for x in 0 ..< width {
            for y in 0 ..< height { f[y] = grid[y * width + x] }
            transform(count: height)
            for y in 0 ..< height { grid[y * width + x] = f[y] }
        }
        for y in 0 ..< height {
            for x in 0 ..< width { f[x] = grid[y * width + x] }
            transform(count: width)
            for x in 0 ..< width { grid[y * width + x] = f[x] }
        }
    }
}

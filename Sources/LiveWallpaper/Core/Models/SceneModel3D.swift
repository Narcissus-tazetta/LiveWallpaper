import Foundation
import simd

/// How a model layer the editor imported is shaded: glTF's metallic-roughness material,
/// drawn by the app's own shader (`SceneModelShading`).
struct SceneModelSurface: Codable, Equatable {
    enum AlphaMode: String, Codable { case opaque, mask, blend }

    /// Straight RGBA, linear.
    var baseColor: [Double] = [1, 1, 1, 1]
    var metallic: Double = 1
    var roughness: Double = 1
    /// Linear RGB.
    var emissive: [Double] = [0, 0, 0]
    var alphaMode: AlphaMode = .opaque
    var alphaCutoff: Double = 0.5
    var doubleSided = false
    var normalScale: Double = 1
    var occlusionStrength: Double = 1
    /// Shows the base colour as it is, without light (KHR_materials_unlit).
    var unlit = false
    /// Image files in the scene folder: base colour (sRGB, straight alpha), metallic in
    /// blue and roughness in green, a tangent-space normal map, occlusion in red, emission (sRGB).
    var baseColorImage: String?
    var metallicRoughnessImage: String?
    var normalImage: String?
    var occlusionImage: String?
    var emissiveImage: String?
    var repeats = true

    var images: [String] {
        [baseColorImage, metallicRoughnessImage, normalImage, occlusionImage, emissiveImage].compactMap { $0 }
    }

    var isValid: Bool {
        baseColor.count == 4 && emissive.count == 3
            && (baseColor + emissive + [metallic, roughness, alphaCutoff, normalScale, occlusionStrength]).allSatisfy(\.isFinite)
    }
}

/// Where a model layer the editor imported stands on the canvas. The layer's own transform
/// places it: its position is where `center` lands, its scale multiplies `unitScale`, and its
/// rotation turns the model in the canvas plane after `turn` and `tilt`.
struct SceneModelPlacement: Codable, Equatable {
    /// The point in the model's own units that sits at the layer's position.
    var center: [Double]
    /// Canvas pixels per model unit at scale 1.
    var unitScale: Double
    /// The model's footprint at scale 1, in canvas pixels (width, height), for selecting it.
    var size: [Double]
    /// Degrees about the vertical axis, positive turning the front to the right.
    var turn: Double = 0
    /// Degrees about the horizontal axis, positive leaning the top toward the viewer.
    var tilt: Double = 0
    /// Canvas pixels toward the viewer.
    var depth: Double = 0

    var isValid: Bool {
        center.count == 3 && size.count == 2 && (center + size + [unitScale, turn, tilt, depth]).allSatisfy(\.isFinite) && unitScale > 0
    }

    /// From the model's units to scene pixels (origin bottom left, y up, z toward the viewer).
    func world(transform: SceneTransform, canvasWidth: Double, canvasHeight: Double) -> simd_float4x4 {
        let position = SIMD3(
            Float((0.5 + transform.offsetX) * canvasWidth), Float((0.5 - transform.offsetY) * canvasHeight), Float(depth)
        )
        let scale = SIMD3(
            Float(transform.scale * unitScale), Float((transform.scaleY ?? transform.scale) * unitScale), Float(transform.scale * unitScale)
        )
        // The layer's rotation is clockwise on the canvas, which is negative about +z.
        let roll = simd_float4x4(simd_quatf(angle: Float(-transform.rotation * .pi / 180), axis: SIMD3(0, 0, 1)))
        let lean = simd_float4x4(simd_quatf(angle: Float(-tilt * .pi / 180), axis: SIMD3(1, 0, 0)))
        let spin = simd_float4x4(simd_quatf(angle: Float(turn * .pi / 180), axis: SIMD3(0, 1, 0)))
        var translate = matrix_identity_float4x4
        translate.columns.3 = SIMD4(position, 1)
        var recenter = matrix_identity_float4x4
        recenter.columns.3 = SIMD4(-Float(center[0]), -Float(center[1]), -Float(center[2]), 1)
        return translate * roll * simd_float4x4(diagonal: SIMD4(scale, 1)) * lean * spin * recenter
    }
}

/// How the scene's imported models are seen and lit. Image layers are not affected: the
/// view is built so that the canvas plane (z = 0) looks the same through it when the
/// view is not turned.
struct SceneModelStage: Codable, Equatable {
    static let maximumLights = 4

    struct Light: Codable, Equatable, Identifiable {
        enum Kind: String, Codable, CaseIterable { case directional, point, spot }
        var id = UUID()
        var kind: Kind = .directional
        /// Linear RGB.
        var color: [Double] = [1, 1, 1]
        var intensity: Double = 2.5
        /// The direction the light comes from, in degrees: around the vertical axis
        /// (0 from the front, positive from the right) and above the horizon.
        var azimuth: Double = -35
        var elevation: Double = 40
        /// Point and spot: canvas fraction (x right, y down) and pixels toward the viewer.
        var position: [Double] = [0.3, 0.2, 800]
        /// Point and spot: the distance, in canvas heights, at which the light falls to a quarter.
        var range: Double = 1
        /// Spot: half the cone's angle, in degrees.
        var coneAngle: Double = 30
        /// Point lights cast none.
        var castsShadow = true

        var casts: Bool { castsShadow && kind != .point }

        var isValid: Bool {
            color.count == 3 && position.count == 3
                && (color + position + [intensity, azimuth, elevation, range, coneAngle]).allSatisfy(\.isFinite)
                && range > 0 && (1 ... 89).contains(coneAngle)
        }

        /// Unit vector toward where the light comes from.
        var fromDirection: SIMD3<Float> {
            let a = Float(azimuth * .pi / 180), e = Float(elevation * .pi / 180)
            return SIMD3(sin(a) * cos(e), sin(e), cos(a) * cos(e))
        }
    }

    /// A transparent floor that shows only the shadows falling on it.
    struct Floor: Codable, Equatable {
        /// Canvas fraction from the top.
        var height: Double = 0.85
        var opacity: Double = 0.6

        var isValid: Bool { [height, opacity].allSatisfy(\.isFinite) }
    }

    /// 0 shows the models without perspective; otherwise the vertical field of view in degrees.
    var fieldOfView: Double = 30
    /// The view turns about the canvas centre: degrees around the vertical axis and above it.
    var orbitAzimuth: Double = 0
    var orbitElevation: Double = 0
    /// Light from all round: from above and from below, linear RGB.
    var skyColor: [Double] = [0.32, 0.34, 0.38]
    var groundColor: [Double] = [0.16, 0.15, 0.14]
    var lights: [Light] = [Light()]
    var floor: Floor?

    var isValid: Bool {
        skyColor.count == 3 && groundColor.count == 3 && lights.count <= Self.maximumLights
            && (skyColor + groundColor + [fieldOfView, orbitAzimuth, orbitElevation]).allSatisfy(\.isFinite)
            && (0 ..< 120).contains(fieldOfView) && lights.allSatisfy(\.isValid) && (floor?.isValid ?? true)
    }

    /// The scene camera the renderer lights models with: the lights as script-movable
    /// lights in the order of `lights`, and those that cast as shadow lights.
    func camera(canvasWidth: Double, canvasHeight: Double) -> SceneCamera {
        let center = SIMD3(canvasWidth / 2, canvasHeight / 2, 0)
        var dynamic: [SceneDynamicLight] = []
        var shadows: [SceneShadowLight] = []
        for (index, light) in lights.enumerated() {
            let origin = lightOrigin(light, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
            let axis = -light.fromDirection
            let color = light.color.map { $0 * light.intensity }
            dynamic.append(SceneDynamicLight(
                objectID: -1 - index, origin: [Double(origin.x), Double(origin.y), Double(origin.z)],
                axis: [Double(axis.x), Double(axis.y), Double(axis.z)], color: color
            ))
            if light.casts {
                shadows.append(SceneShadowLight(
                    kind: light.kind == .spot ? .spot : .directional,
                    origin: [Double(origin.x), Double(origin.y), Double(origin.z)],
                    axis: [Double(axis.x), Double(axis.y), Double(axis.z)],
                    outerCone: light.coneAngle, cascadeDistance: 0, dynamicLight: index
                ))
            }
        }
        return SceneCamera(
            perspective: false, eye: [center.x, center.y, 2000], center: [center.x, center.y, 0], up: [0, 1, 0],
            fov: fieldOfView, nearZ: 1, farZ: 50000, ambientColor: groundColor, skylightColor: skyColor,
            shadowLights: shadows.isEmpty ? nil : shadows, dynamicLights: dynamic
        )
    }

    private func lightOrigin(_ light: Light, canvasWidth: Double, canvasHeight: Double) -> SIMD3<Float> {
        switch light.kind {
        case .directional:
            // Far along where it comes from; only its direction is used.
            SIMD3(Float(canvasWidth / 2), Float(canvasHeight / 2), 0) + light.fromDirection * Float(canvasHeight * 10)
        case .point, .spot:
            SIMD3(Float(light.position[0] * canvasWidth), Float((1 - light.position[1]) * canvasHeight), Float(light.position[2]))
        }
    }

    /// Per light, what the shader needs beyond its origin, axis and colour:
    /// kind (0 directional, 1 point, 2 spot), cosine of the cone's half angle, range in
    /// pixels and the shadow map slot (−1 without one). Keys `light<i>.0`...`.3`.
    func materialValues(canvasHeight: Double) -> [String: Double] {
        var values: [String: Double] = [:]
        var slot = 0
        for (index, light) in lights.enumerated() {
            let kind: Double = switch light.kind {
            case .directional: 0
            case .point: 1
            case .spot: 2
            }
            values["light\(index).0"] = kind
            values["light\(index).1"] = cos(light.coneAngle * .pi / 180)
            values["light\(index).2"] = light.range * canvasHeight
            values["light\(index).3"] = light.casts ? Double(slot) : -1
            if light.casts { slot += 1 }
        }
        values["floor.0"] = floor?.opacity ?? 0
        return values
    }

    /// Scene pixels to clip space for a target showing `viewport` of the canvas (origin
    /// and size in canvas UV, y down): the canvas plane maps as the flat canvas does when
    /// the view is not turned. Returns the eye too.
    func viewProjection(canvasWidth: Double, canvasHeight: Double, viewport: SIMD4<Float>) -> (simd_float4x4, SIMD3<Float>) {
        let w = Float(canvasWidth), h = Float(canvasHeight)
        let center = SIMD3(w / 2, h / 2, 0)
        let turn = simd_quatf(angle: Float(orbitAzimuth * .pi / 180), axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: Float(-orbitElevation * .pi / 180), axis: SIMD3(1, 0, 0))
        let backward = turn.act(SIMD3(0, 0, 1)), up = turn.act(SIMD3(0, 1, 0))
        let projection: simd_float4x4
        let eye: SIMD3<Float>
        if fieldOfView > 0.5 {
            let f = 1 / tan(Float(fieldOfView) * .pi / 360)
            // At this distance the canvas plane fills the view exactly.
            let distance = h / 2 * f
            eye = center + backward * distance
            let near = distance * 0.02, far = distance * 50
            projection = simd_float4x4(columns: (
                SIMD4(f * h / w, 0, 0, 0), SIMD4(0, f, 0, 0),
                SIMD4(0, 0, far / (near - far), -1), SIMD4(0, 0, near * far / (near - far), 0)
            ))
            return (Self.viewportAdjust(viewport) * projection * Self.lookAt(eye: eye, center: center, up: up), eye)
        }
        eye = center + backward * 2000
        let depthRange: Float = 40000
        projection = simd_float4x4(columns: (
            SIMD4(2 / w, 0, 0, 0), SIMD4(0, 2 / h, 0, 0), SIMD4(0, 0, -1 / depthRange, 0), SIMD4(0, 0, 0.5, 1)
        ))
        // Turned about the canvas centre, which stays where it is.
        var toCenter = matrix_identity_float4x4
        toCenter.columns.3 = SIMD4(-center, 1)
        return (Self.viewportAdjust(viewport) * projection * simd_float4x4(turn.inverse) * toCenter, eye)
    }

    private static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - center)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        return simd_float4x4(columns: (
            SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0), SIMD4(x.z, y.z, z.z, 0),
            SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)
        ))
    }

    /// Clip space of the whole canvas to that of a target showing `viewport` of it, as
    /// `SceneModelRenderer.canvasProjection` places it.
    private static func viewportAdjust(_ viewport: SIMD4<Float>) -> simd_float4x4 {
        let vx = viewport.x, vy = viewport.y, vw = viewport.z, vh = viewport.w
        return simd_float4x4(columns: (
            SIMD4(1 / vw, 0, 0, 0), SIMD4(0, 1 / vh, 0, 0), SIMD4(0, 0, 1, 0),
            SIMD4(1 / vw - 2 * vx / vw - 1, 1 / vh + 1 - 2 * (1 - vy) / vh, 0, 1)
        ))
    }
}

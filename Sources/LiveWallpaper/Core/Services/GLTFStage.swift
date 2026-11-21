import Foundation
import simd

extension GLTFAsset {
    struct Camera: Decodable {
        struct Perspective: Decodable {
            let yfov: Double
            let znear: Double
            let zfar: Double?
            let aspectRatio: Double?
        }

        struct Orthographic: Decodable {
            let xmag: Double
            let ymag: Double
            let znear: Double
            let zfar: Double
        }

        enum Kind: String, Decodable { case perspective, orthographic }
        let type: Kind
        let perspective: Perspective?
        let orthographic: Orthographic?

        func placed(
            at eye: SIMD3<Double>,
            rotation: simd_quatf,
            unit: Double
        ) throws -> SceneModelStage.Camera {
            let forward = rotation.act(SIMD3(0, 0, -1))
            let up = rotation.act(SIMD3(0, 1, 0))
            let projection: SceneModelStage.Camera.Projection
            switch type {
            case .perspective:
                guard let perspective
                else { throw ReadError(detail: "missing perspective camera parameters") }
                projection = .perspective(
                    verticalFOV: perspective.yfov, aspect: perspective.aspectRatio,
                    near: unit * perspective.znear, far: perspective.zfar.map { unit * $0 }
                )
            case .orthographic:
                guard let orthographic
                else { throw ReadError(detail: "missing orthographic camera parameters") }
                projection = .orthographic(
                    halfWidth: unit * orthographic.xmag, halfHeight: unit * orthographic.ymag,
                    near: unit * orthographic.znear, far: unit * orthographic.zfar
                )
            }
            let camera = SceneModelStage.Camera(
                eye: [eye.x, eye.y, eye.z],
                direction: [forward.x, forward.y, forward.z].map(Double.init),
                up: [up.x, up.y, up.z].map(Double.init),
                projection: projection
            )
            guard camera.isValid
            else { throw ReadError(detail: "invalid camera projection or transform") }
            return camera
        }
    }

    struct Light: Decodable {
        private struct Spot: Decodable {
            let innerConeAngle: Double?
            let outerConeAngle: Double?
        }

        let type: SceneModelStage.Light.Kind
        let color: [Double]?
        let intensity: Double?
        let range: Double?
        private let spot: Spot?

        func placed(
            at position: SIMD3<Double>, rotation: simd_quatf, unit: Double,
            canvasSize: SIMD2<Double>
        ) throws -> SceneModelStage.Light {
            let direction = rotation.act(SIMD3(0, 0, 1))
            let inner = spot?.innerConeAngle ?? 0
            let outer = spot?.outerConeAngle ?? .pi / 4
            guard (0 ..< outer).contains(inner), outer <= .pi / 2,
                  (range ?? 1) > 0, (intensity ?? 1) >= 0,
                  (color ?? []).allSatisfy({ (0 ... 1).contains($0) })
            else { throw ReadError(detail: "invalid punctual light parameters") }
            let light = SceneModelStage.Light(
                kind: type,
                color: color ?? [1, 1, 1],
                intensity: (intensity ?? 1) / .pi,
                azimuth: Double(atan2(direction.x, direction.z)) * 180 / .pi,
                elevation: Double(asin(max(-1, min(1, direction.y)))) * 180 / .pi,
                position: [position.x / canvasSize.x, 1 - position.y / canvasSize.y, position.z],
                range: range.map { $0 * unit / canvasSize.y } ?? 1,
                coneAngle: outer * 180 / .pi,
                castsShadow: false,
                photometry: .init(
                    canvasUnitsPerMeter: unit,
                    innerConeAngle: inner * 180 / .pi,
                    hasRange: range != nil
                )
            )
            guard light.isValid else { throw ReadError(detail: "invalid punctual light transform") }
            return light
        }
    }

    func modelStage(
        order: [Int], global: [Int: simd_float4x4], rotations: [Int: simd_quatf],
        placement: SceneModelPlacement, canvasSize: SIMD2<Double>,
        skeleton: UUID?, boneIndex: [Int: Int]
    ) throws -> SceneModelStage? {
        var stage = SceneModelStage()
        let center = SIMD3<Double>(placement.center)
        let canvasCenter = SIMD3(canvasSize.x / 2, canvasSize.y / 2, 0)
        var moving = Set(animations.flatMap(\.channels).filter { $0.path != .weights }.map(\.node))
        for index in order where moving.contains(index) {
            moving.formUnion(nodes[index].children)
        }
        var importedLights: [SceneModelStage.Light] = []
        for index in order {
            let node = nodes[index]
            guard node.camera != nil || node.light != nil else { continue }
            let t = global[index]!.columns.3
            let position = (SIMD3(Double(t.x), Double(t.y), Double(t.z)) - center)
                * placement.unitScale + canvasCenter
            let rotation = rotations[index]!
            let binding = (moving.contains(index) ? skeleton : nil).map { id in
                SceneModelStage.Binding(
                    skeleton: id, bone: boneIndex[index]!, restOrigin: [t.x, t.y, t.z],
                    restRotation: [
                        rotation.vector.x,
                        rotation.vector.y,
                        rotation.vector.z,
                        rotation.vector.w
                    ],
                    canvasUnitsPerMeter: placement.unitScale
                )
            }
            if let camera = node.camera, stage.importedCamera == nil {
                stage.importedCamera = try cameras[camera].placed(
                    at: position, rotation: rotation, unit: placement.unitScale
                )
                stage.importedCamera?.binding = binding
            }
            if let light = node.light, importedLights.count < SceneModelStage.maximumLights {
                var placed = try lights[light].placed(
                    at: position, rotation: rotation, unit: placement.unitScale,
                    canvasSize: canvasSize
                )
                placed.binding = binding
                importedLights.append(placed)
            }
        }
        if !importedLights.isEmpty {
            stage.lights = importedLights
            stage.skyColor = [0, 0, 0]
            stage.groundColor = [0, 0, 0]
        }
        return stage.importedCamera != nil || !importedLights.isEmpty ? stage : nil
    }
}

import Foundation
import simd

extension SceneModelStage {
    struct Binding: Codable, Equatable {
        var skeleton: UUID
        var bone: Int
        var restOrigin: [Float]
        var restRotation: [Float]
        var canvasUnitsPerMeter: Double

        var isValid: Bool {
            bone >= 0 && restOrigin.count == 3 && restRotation.count == 4
                && (restOrigin + restRotation).allSatisfy(\.isFinite)
                && abs(simd_length(SIMD4<Float>(restRotation)) - 1) < 0.001
                && canvasUnitsPerMeter.isFinite && canvasUnitsPerMeter > 0
        }

        func offset(
            rigs: SceneSkeletonRegistry,
            time: Double
        ) throws -> (position: SIMD3<Double>, rotation: simd_quatf)? {
            // Removing the imported layer can leave an edited stage in use by other models.
            guard let rig = rigs.skeletons[skeleton] else { return nil }
            guard rig.bones.indices.contains(bone) else {
                throw SceneSkeletonEvaluator
                    .InvalidSkeleton(detail: "stage animation names an unknown bone")
            }
            let pose = try rigs.evaluator(skeleton).evaluate(time: time)
            let origin = pose.world[bone].columns.3
            let rest = SIMD3<Float>(restOrigin)
            let shift = SIMD3(origin.x, origin.y, origin.z) - rest
            let rotation = pose.rotations[bone] * simd_quatf(vector: SIMD4<Float>(restRotation))
                .inverse
            return (
                SIMD3(Double(shift.x), Double(shift.y), Double(shift.z)) * canvasUnitsPerMeter,
                rotation
            )
        }
    }

    var animationRigs: [UUID] {
        let camera = importedCameraEnabled != false ? importedCamera?.binding?.skeleton : nil
        return [camera].compactMap { $0 } + lights.compactMap { $0.binding?.skeleton }
    }

    func posed(
        rigs: SceneSkeletonRegistry,
        time: Double,
        canvasSize: SIMD2<Double>
    ) throws -> Self {
        var stage = self
        if importedCameraEnabled != false, var camera = importedCamera,
           let binding = camera.binding, let offset = try binding.offset(rigs: rigs, time: time)
        {
            let p = SIMD3<Double>(camera.eye) + offset.position
            let direction = offset.rotation.act(SIMD3<Float>(camera.direction.map(Float.init)))
            let up = offset.rotation.act(SIMD3<Float>(camera.up.map(Float.init)))
            camera.eye = [p.x, p.y, p.z]
            camera.direction = [Double(direction.x), Double(direction.y), Double(direction.z)]
            camera.up = [Double(up.x), Double(up.y), Double(up.z)]
            stage.importedCamera = camera
        }
        for i in lights.indices {
            guard let binding = lights[i].binding, let offset = try binding.offset(
                rigs: rigs,
                time: time
            ) else { continue }
            let from = offset.rotation.act(lights[i].fromDirection)
            stage.lights[i].position[0] += offset.position.x / canvasSize.x
            stage.lights[i].position[1] -= offset.position.y / canvasSize.y
            stage.lights[i].position[2] += offset.position.z
            stage.lights[i].azimuth = Double(atan2(from.x, from.z)) * 180 / .pi
            stage.lights[i].elevation = Double(asin(max(-1, min(1, from.y)))) * 180 / .pi
        }
        return stage
    }
}

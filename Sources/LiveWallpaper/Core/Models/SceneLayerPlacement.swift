import Foundation
import simd

struct SceneLayerPlacement: Codable, Equatable {
    struct Step: Codable, Equatable {
        var matrix: [Float]
        var skeletonID: UUID?
        var attachment: String?
    }

    var steps: [Step]
    var referenceTransform: SceneTransform
}

final class ScenePlacementEvaluator {
    private struct Step {
        var matrix: simd_float4x4
        var skeleton: SceneSkeletonEvaluator?
        var attachment: String?
    }

    private let layers: [UUID: [Step]]

    init(layers: [SceneLayer], rigs: SceneSkeletonRegistry) throws {
        var compiled: [UUID: [Step]] = [:]
        for layer in layers {
            guard let placement = layer.placement else { continue }
            let reference = placement.referenceTransform
            guard [reference.offsetX, reference.offsetY, reference.rotation, reference.scale]
                .allSatisfy(\.isFinite),
                reference.scale != 0
            else {
                throw SceneSkeletonEvaluator
                    .InvalidSkeleton(detail: "invalid placement reference for \(layer.name)")
            }
            compiled[layer.id] = try placement.steps.map { step in
                guard step.matrix.count == 16, step.matrix.allSatisfy(\.isFinite) else {
                    throw SceneSkeletonEvaluator
                        .InvalidSkeleton(detail: "invalid placement matrix for \(layer.name)")
                }
                let matrix = Self.matrix(step.matrix)
                guard matrix.columns.0.w == 0, matrix.columns.1.w == 0,
                      matrix.columns.2.w == 0, matrix.columns.3.w == 1,
                      simd_determinant(matrix) != 0
                else {
                    throw SceneSkeletonEvaluator
                        .InvalidSkeleton(
                            detail: "placement must be invertible and affine: \(layer.name)"
                        )
                }
                guard (step.skeletonID == nil) == (step.attachment == nil) else {
                    throw SceneSkeletonEvaluator
                        .InvalidSkeleton(detail: "incomplete attachment for \(layer.name)")
                }
                let skeleton = try step.skeletonID.map(rigs.evaluator)
                if let skeleton, skeleton.evaluate(time: 0).attachments[step.attachment!] == nil {
                    throw SceneSkeletonEvaluator
                        .InvalidSkeleton(
                            detail: "unknown attachment \(step.attachment!) for \(layer.name)"
                        )
                }
                return Step(matrix: matrix, skeleton: skeleton, attachment: step.attachment)
            }
        }
        self.layers = compiled
    }

    func evaluate(time: Double) -> [UUID: simd_float3x3] {
        layers.mapValues { steps in
            var world = matrix_identity_float4x4
            for step in steps {
                world *= step.matrix
                if let skeleton = step.skeleton {
                    world *= skeleton.evaluate(time: time).attachments[step.attachment!]!
                }
            }
            return simd_float3x3(columns: (
                SIMD3(world.columns.0.x, world.columns.0.y, 0),
                SIMD3(world.columns.1.x, world.columns.1.y, 0),
                SIMD3(world.columns.3.x, world.columns.3.y, 1)
            ))
        }
    }

    private static func matrix(_ values: [Float]) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(values[0], values[1], values[2], values[3]),
            SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]),
            SIMD4(values[12], values[13], values[14], values[15])
        ))
    }
}

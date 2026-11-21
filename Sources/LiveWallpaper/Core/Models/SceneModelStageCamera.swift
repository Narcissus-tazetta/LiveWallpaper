import Foundation
import simd

extension SceneModelStage {
    struct Camera: Codable, Equatable {
        enum Projection: Codable, Equatable {
            case perspective(verticalFOV: Double, aspect: Double?, near: Double, far: Double?)
            case orthographic(halfWidth: Double, halfHeight: Double, near: Double, far: Double)

            var isValid: Bool {
                switch self {
                case let .perspective(fov, aspect, near, far):
                    fov.isFinite && fov > 0 && fov < .pi
                        && (aspect.map { $0.isFinite && $0 > 0 } ?? true)
                        && near
                        .isFinite && near > 0 && (far.map { $0.isFinite && $0 > near } ?? true)
                case let .orthographic(width, height, near, far):
                    [width, height, near, far].allSatisfy(\.isFinite)
                        && width > 0 && height > 0 && near >= 0 && far > near
                }
            }

            func matrix(canvasAspect: Float) -> simd_float4x4 {
                let projection: simd_float4x4
                let cameraAspect: Float
                switch self {
                case let .perspective(fov, aspect, near, far):
                    cameraAspect = aspect.map(Float.init) ?? canvasAspect
                    let f = 1 / tan(Float(fov) / 2)
                    let depth = far.map { Float($0 / (near - $0)) } ?? -1
                    projection = simd_float4x4(columns: (
                        SIMD4(f / cameraAspect, 0, 0, 0), SIMD4(0, f, 0, 0),
                        SIMD4(0, 0, depth, -1), SIMD4(0, 0, Float(near) * depth, 0)
                    ))
                case let .orthographic(width, height, near, far):
                    cameraAspect = Float(width / height)
                    let depth = Float(1 / (near - far))
                    projection = simd_float4x4(columns: (
                        SIMD4(Float(1 / width), 0, 0, 0), SIMD4(0, Float(1 / height), 0, 0),
                        SIMD4(0, 0, depth, 0), SIMD4(0, 0, Float(near) * depth, 1)
                    ))
                }
                let fit = simd_float4x4(diagonal: SIMD4(
                    min(1, cameraAspect / canvasAspect), min(1, canvasAspect / cameraAspect), 1, 1
                ))
                return fit * projection
            }
        }

        var eye: [Double]
        var direction: [Double]
        var up: [Double]
        var projection: Projection
        var binding: Binding?

        var isValid: Bool {
            [eye, direction, up].allSatisfy { $0.count == 3 && $0.allSatisfy(\.isFinite) }
                && simd_length_squared(simd_cross(SIMD3<Double>(direction), SIMD3<Double>(up))) > 0
                && projection.isValid && (binding?.isValid ?? true)
        }
    }
}

import Foundation
import simd

struct SceneMorphCurve: Codable, Equatable {
    var times: [Float]
    var values: [Float]
    var interpolation: String
    var width: Int

    var isValid: Bool {
        guard (1 ... 4096).contains(width) else { return false }
        let stride = width * (interpolation == "CUBICSPLINE" ? 3 : 1)
        return !times.isEmpty && values.count / stride == times.count
            && values.count % stride == 0 && times.allSatisfy(\.isFinite)
            && values.allSatisfy(\.isFinite) && zip(times, times.dropFirst()).allSatisfy { $0 < $1 }
            && ["STEP", "LINEAR", "CUBICSPLINE"].contains(interpolation)
    }

    func sample(at time: Float) -> [Float] {
        let cubic = interpolation == "CUBICSPLINE"
        let stride = cubic ? width * 3 : width
        func start(_ key: Int) -> Int {
            key * stride + (cubic ? width : 0)
        }
        if time <= times[0] { return Array(values[start(0) ..< start(0) + width]) }
        let last = times.count - 1
        if time >= times[last] { return Array(values[start(last) ..< start(last) + width]) }
        var lo = 0, hi = last
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if times[mid] <= time { lo = mid } else { hi = mid }
        }
        let left = start(lo), right = start(hi)
        if interpolation == "STEP" { return Array(values[left ..< left + width]) }
        let span = times[hi] - times[lo]
        let t = (time - times[lo]) / span
        if cubic {
            let t2 = t * t, t3 = t2 * t
            return (0 ..< width).map { i in
                let p0 = values[left + i], p1 = values[right + i]
                let m0 = values[left + width + i] * span, m1 = values[right - width + i] * span
                return (2 * t3 - 3 * t2 + 1) * p0 + (t3 - 2 * t2 + t) * m0
                    + (-2 * t3 + 3 * t2) * p1 + (t3 - t2) * m1
            }
        }
        return (0 ..< width)
            .map { values[left + $0] + (values[right + $0] - values[left + $0]) * t }
    }
}

struct SceneMorphPatch: Codable, Equatable {
    struct Target: Codable, Equatable {
        var positions: Data?
        var normals: Data?
        var tangents: Data?

        func isValid(count: Int) -> Bool {
            [positions, normals, tangents].compactMap { $0 }.allSatisfy { $0.count == count * 12 }
        }
    }

    var bone: Int
    var start: Int
    var count: Int
    var targets: [Target]
    var flatNormals: Bool

    func isValid(vertexCount: Int) -> Bool {
        bone >= 0 && start >= 0 && start <= vertexCount && count >= 1 && count <= vertexCount -
            start
            && !targets.isEmpty && targets.allSatisfy { $0.isValid(count: count) }
            && (!flatNormals || count.isMultiple(of: 3))
    }

    func applyPositions(weights: [Float], to positions: inout [Float]) {
        for (target, weight) in zip(targets, weights) where weight != 0 {
            add(target.positions, to: &positions, stride: 3, offset: 0, weight: weight)
        }
    }

    func apply(weights: [Float], to vertices: inout [Float], stride: Int, tangentOffset: Int?) {
        for (target, weight) in zip(targets, weights) where weight != 0 {
            add(target.positions, to: &vertices, stride: stride, offset: 0, weight: weight)
            if !flatNormals {
                add(target.normals, to: &vertices, stride: stride, offset: 3, weight: weight)
            }
            if let tangentOffset {
                add(
                    target.tangents,
                    to: &vertices,
                    stride: stride,
                    offset: tangentOffset,
                    weight: weight
                )
            }
        }
        if flatNormals {
            for corner in Swift.stride(
                from: start * stride,
                to: (start + count) * stride,
                by: 3 * stride
            ) {
                func position(_ i: Int) -> SIMD3<Float> {
                    SIMD3(vertices[i], vertices[i + 1], vertices[i + 2])
                }
                let origin = position(corner)
                let normal = simd_cross(
                    position(corner + stride) - origin,
                    position(corner + 2 * stride) - origin
                )
                let unit = simd_length_squared(normal) > 0 ? simd_normalize(normal) : SIMD3(0, 0, 1)
                for i in 0 ..< 3 {
                    let offset = corner + i * stride + 3
                    vertices[offset] = unit.x
                    vertices[offset + 1] = unit.y
                    vertices[offset + 2] = unit.z
                }
            }
        }
    }

    private func add(
        _ bytes: Data?,
        to vertices: inout [Float],
        stride: Int,
        offset: Int,
        weight: Float
    ) {
        guard let bytes else { return }
        bytes.withUnsafeBytes { raw in
            for i in 0 ..< count {
                let output = (start + i) * stride + offset
                for axis in 0 ..< 3 {
                    let bits = raw.loadUnaligned(
                        fromByteOffset: (i * 3 + axis) * 4,
                        as: UInt32.self
                    )
                    vertices[output + axis] += Float(bitPattern: bits.littleEndian) * weight
                }
            }
        }
    }
}

extension SceneStaticModel {
    func hasValidMorphs(in rig: SceneSkeleton) -> Bool {
        (morphs ?? []).allSatisfy { patch in
            rig.bones.indices.contains(patch.bone)
                && rig.bones[patch.bone].morphWeights?.count == patch.targets.count
        }
    }
}

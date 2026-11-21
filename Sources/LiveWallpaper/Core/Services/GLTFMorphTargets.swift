import simd

extension GLTFAsset.Primitive {
    func morphed(weights: [Float]) throws -> Self {
        guard weights.contains(where: { $0 != 0 }) else { return self }
        var result = self
        for (target, weight) in zip(targets, weights) where weight != 0 {
            try Self.add(target.position, weight: weight, to: &result.positions)
            if let deltas = target.normal, result.normals != nil {
                try Self.add(deltas, weight: weight, to: &result.normals!)
            }
            if let deltas = target.tangent, result.tangents != nil {
                for i in deltas.indices {
                    result.tangents![i] += SIMD4(deltas[i], 0) * weight
                    let tangent = result.tangents![i]
                    guard tangent.x.isFinite, tangent.y.isFinite, tangent.z.isFinite else {
                        throw GLTFAsset
                            .ReadError(detail: "morph weights produce a non-finite tangent")
                    }
                }
            }
        }
        return result
    }

    private static func add(
        _ deltas: [SIMD3<Float>]?, weight: Float, to points: inout [SIMD3<Float>]
    ) throws {
        guard let deltas else { return }
        for i in deltas.indices {
            points[i] += deltas[i] * weight
            let value = points[i]
            guard value.x.isFinite, value.y.isFinite, value.z.isFinite else {
                throw GLTFAsset
                    .ReadError(detail: "morph weights produce a non-finite vertex attribute")
            }
        }
    }
}

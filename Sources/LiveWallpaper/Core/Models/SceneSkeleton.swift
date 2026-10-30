import Foundation
import simd

struct SceneSkeleton: Codable, Equatable {
    struct Transform: Codable, Equatable {
        var translation: [Float] = [0, 0, 0]
        var rotation: [Float] = [0, 0, 0, 1]
        var scale: [Float] = [1, 1, 1]
    }

    struct Bone: Codable, Equatable {
        var name: String
        var parent: Int?
        var rest: Transform
        var inverseBind: [Float]
    }

    struct Track: Codable, Equatable {
        var bone: Int
        var transforms: [Transform]
        var opacity: [Float]?
    }

    struct Clip: Codable, Equatable {
        var name: String
        var framesPerSecond: Double
        var frameCount: Int
        var tracks: [Track]
    }

    struct Playback: Codable, Equatable {
        var clip: Int
        var rate: Double = 1
        var startFrame: Double = 0
        var loops: Bool = true
        var mirrors: Bool?
        var weight: Float = 1
        var additive: Bool = false
    }

    struct Attachment: Codable, Equatable {
        var name: String
        var bone: Int
        var transform: [Float]
    }

    var bones: [Bone]
    var clips: [Clip]
    var playback: [Playback]
    var attachments: [Attachment] = []
}

final class SceneSkeletonEvaluator {
    struct InvalidSkeleton: LocalizedError {
        let detail: String
        var errorDescription: String? {
            "Scene skeleton: \(detail)"
        }
    }

    struct Pose {
        var matrices: [simd_float4x4]
        var opacity: [Float]
        var attachments: [String: simd_float4x4]
    }

    private let skeleton: SceneSkeleton
    private var order: [Int] = []
    private var inverseBind: [simd_float4x4] = []
    private var playbackOverride: [SceneSkeleton.Playback]?
    private var cachedPose: (time: Double, pose: Pose)?

    init(_ skeleton: SceneSkeleton) throws {
        self.skeleton = skeleton
        try validate()
        inverseBind = skeleton.bones.map { Self.matrix($0.inverseBind) }
        var visited = Set<Int>()
        func visit(_ index: Int) {
            guard visited.insert(index).inserted else { return }
            if let parent = skeleton.bones[index].parent { visit(parent) }
            order.append(index)
        }
        for index in skeleton.bones.indices {
            visit(index)
        }
    }

    func setPlaybackOverride(_ playback: [SceneSkeleton.Playback]?) {
        if playbackOverride != playback {
            playbackOverride = playback
            cachedPose = nil
        }
    }

    func evaluate(time: Double) -> Pose {
        if let cachedPose, cachedPose.time == time { return cachedPose.pose }
        var transforms = skeleton.bones.map(\.rest)
        var opacity = Array(repeating: Float(1), count: transforms.count)
        for playback in playbackOverride ?? skeleton.playback where playback.weight > 0 {
            let clip = skeleton.clips[playback.clip]
            var frame = playback.startFrame + time * playback.rate * clip.framesPerSecond
            if playback.loops, clip.frameCount > 0 {
                let period = Double(clip.frameCount) * (playback.mirrors == true ? 2 : 1)
                frame = frame.truncatingRemainder(dividingBy: period)
                if frame < 0 { frame += period }
                if frame > Double(clip.frameCount) { frame = period - frame }
            } else {
                frame = min(Double(clip.frameCount), max(0, frame))
            }
            let first = Int(frame), next = min(first + 1, clip.frameCount)
            let fraction = Float(frame - Double(first))
            for track in clip.tracks {
                let sampled = Self.mix(track.transforms[first], track.transforms[next], fraction)
                let bone = track.bone
                if playback.additive {
                    transforms[bone] = Self.add(
                        transforms[bone], sampled, rest: skeleton.bones[bone].rest,
                        weight: playback.weight
                    )
                } else {
                    transforms[bone] = Self.mix(transforms[bone], sampled, playback.weight, normalizedLerp: true)
                }
                if let values = track.opacity {
                    let value = values[first] + (values[next] - values[first]) * fraction
                    if playback.additive {
                        opacity[bone] += (value - 1) * playback.weight
                    } else {
                        opacity[bone] += (value - opacity[bone]) * playback.weight
                    }
                }
            }
        }
        var world = Array(repeating: matrix_identity_float4x4, count: transforms.count)
        for index in order {
            let local = Self.matrix(transforms[index])
            world[index] = skeleton.bones[index].parent.map { world[$0] * local } ?? local
        }
        let pose = Pose(
            matrices: world.indices.map { world[$0] * inverseBind[$0] },
            opacity: opacity.map { min(1, max(0, $0)) },
            attachments: Dictionary(uniqueKeysWithValues: skeleton.attachments.map {
                ($0.name, world[$0.bone] * Self.matrix($0.transform))
            })
        )
        cachedPose = (time, pose)
        return pose
    }

    /// `normalizedLerp` blends layers the way the original client does (measured on a skinned
    /// model: nlerp matches its bone matrices to 2.1e-5, slerp is off by 1.6e-3); the samples
    /// of one clip, a frame apart, are interpolated with slerp.
    private static func mix(
        _ lhs: SceneSkeleton.Transform, _ rhs: SceneSkeleton.Transform, _ weight: Float,
        normalizedLerp: Bool = false
    ) -> SceneSkeleton.Transform {
        let rotation: SIMD4<Float>
        if normalizedLerp {
            let from = quaternion(lhs.rotation).vector
            var to = quaternion(rhs.rotation).vector
            if simd_dot(from, to) < 0 { to = -to }
            rotation = simd_normalize(from * (1 - weight) + to * weight)
        } else {
            rotation = simd_slerp(quaternion(lhs.rotation), quaternion(rhs.rotation), weight).vector
        }
        return .init(
            translation: zip(lhs.translation, rhs.translation).map { $0 + ($1 - $0) * weight },
            rotation: [rotation.x, rotation.y, rotation.z, rotation.w],
            scale: zip(lhs.scale, rhs.scale).map { $0 + ($1 - $0) * weight }
        )
    }

    private static func add(
        _ base: SceneSkeleton.Transform, _ sample: SceneSkeleton.Transform,
        rest: SceneSkeleton.Transform, weight: Float
    ) -> SceneSkeleton.Transform {
        let delta = quaternion(rest.rotation).inverse * quaternion(sample.rotation)
        let rotation = (quaternion(base.rotation) * simd_slerp(
            simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), delta, weight
        )).vector
        return .init(
            translation: base.translation.indices.map {
                base.translation[$0] + (sample.translation[$0] - rest.translation[$0]) * weight
            },
            rotation: [rotation.x, rotation.y, rotation.z, rotation.w],
            scale: base.scale.indices.map {
                base.scale[$0] * (1 + (sample.scale[$0] / rest.scale[$0] - 1) * weight)
            }
        )
    }

    private static func quaternion(_ values: [Float]) -> simd_quatf {
        simd_quatf(ix: values[0], iy: values[1], iz: values[2], r: values[3])
    }

    private static func matrix(_ values: [Float]) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(values[0], values[1], values[2], values[3]),
            SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]),
            SIMD4(values[12], values[13], values[14], values[15])
        ))
    }

    private static func matrix(_ transform: SceneSkeleton.Transform) -> simd_float4x4 {
        var matrix = simd_float4x4(quaternion(transform.rotation))
        matrix.columns.0 *= transform.scale[0]
        matrix.columns.1 *= transform.scale[1]
        matrix.columns.2 *= transform.scale[2]
        matrix.columns.3 = SIMD4(
            transform.translation[0], transform.translation[1], transform.translation[2], 1
        )
        return matrix
    }

    private func validate() throws {
        func require(_ condition: Bool, _ detail: String) throws {
            if !condition { throw InvalidSkeleton(detail: detail) }
        }
        func transform(_ value: SceneSkeleton.Transform) throws {
            try require(
                value.translation.count == 3 && value.rotation.count == 4 && value.scale.count == 3,
                "invalid transform components"
            )
            try require(
                (value.translation + value.rotation + value.scale).allSatisfy(\.isFinite),
                "non-finite transform"
            )
            try require(
                abs(simd_length(Self.quaternion(value.rotation).vector) - 1) < 0.001,
                "rotation quaternion must be normalized"
            )
        }
        for (index, bone) in skeleton.bones.enumerated() {
            try transform(bone.rest)
            try require(bone.rest.scale.allSatisfy { $0 != 0 }, "rest scale must be invertible")
            try require(
                bone.inverseBind.count == 16 && bone.inverseBind.allSatisfy(\.isFinite),
                "invalid inverse bind matrix"
            )
            var seen: Set<Int> = [index]
            var parent = bone.parent
            while let current = parent {
                try require(skeleton.bones.indices.contains(current), "unknown parent bone")
                try require(seen.insert(current).inserted, "cyclic bone hierarchy")
                parent = skeleton.bones[current].parent
            }
        }
        for clip in skeleton.clips {
            try require(
                clip.framesPerSecond.isFinite && clip.framesPerSecond > 0 &&
                    clip.frameCount >= 0 && clip.frameCount < Int.max,
                "invalid clip timing"
            )
            try require(
                Set(clip.tracks.map(\.bone)).count == clip.tracks.count,
                "duplicate bone track"
            )
            for track in clip.tracks {
                try require(skeleton.bones.indices.contains(track.bone), "unknown track bone")
                try require(
                    track.transforms.count == clip.frameCount + 1,
                    "missing transform samples"
                )
                for value in track.transforms {
                    try transform(value)
                }
                if let opacity = track.opacity {
                    try require(
                        opacity.count == track.transforms.count && opacity.allSatisfy(\.isFinite),
                        "invalid opacity samples"
                    )
                }
            }
        }
        for playback in skeleton.playback {
            try require(skeleton.clips.indices.contains(playback.clip), "unknown playback clip")
            try require(
                playback.rate.isFinite && playback.startFrame.isFinite &&
                    playback.weight.isFinite && (0 ... 1).contains(playback.weight),
                "invalid playback"
            )
        }
        try require(
            Set(skeleton.attachments.map(\.name)).count == skeleton.attachments.count,
            "duplicate attachment name"
        )
        for attachment in skeleton.attachments {
            try require(
                skeleton.bones.indices.contains(attachment.bone) &&
                    attachment.transform.count == 16 && attachment.transform.allSatisfy(\.isFinite),
                "invalid attachment"
            )
        }
    }
}

final class SceneSkeletonRegistry {
    private let evaluators: [UUID: SceneSkeletonEvaluator]
    let skeletons: [UUID: SceneSkeleton]

    init(_ skeletons: [UUID: SceneSkeleton] = [:]) throws {
        self.skeletons = skeletons
        evaluators = try skeletons.mapValues(SceneSkeletonEvaluator.init)
    }

    func setPlaybackOverrides(_ overrides: [UUID: [SceneSkeleton.Playback]]) {
        for (id, evaluator) in evaluators { evaluator.setPlaybackOverride(overrides[id]) }
    }

    func evaluator(_ id: UUID) throws -> SceneSkeletonEvaluator {
        guard let evaluator = evaluators[id] else {
            throw SceneSkeletonEvaluator.InvalidSkeleton(detail: "unknown rig \(id)")
        }
        return evaluator
    }
}

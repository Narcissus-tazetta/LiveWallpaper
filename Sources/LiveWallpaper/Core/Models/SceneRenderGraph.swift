import Foundation

struct SceneRenderGraph: Codable, Equatable {
    struct Target: Codable, Equatable {
        enum Format: String, Codable { case rgba8, rgba16Float, r8, rg16Float }
        var name: String
        var scale: Double = 1
        var format: Format = .rgba8
    }

    struct Texture: Codable, Equatable {
        var index: Int
        var source: String
        var repeats: Bool = false
        var linear: Bool = true
    }

    struct UniformUpdate: Codable, Equatable {
        /// `audioSpectrum` writes `components` bands (16, 32 or 64) of the `key` channel
        /// ("left" or "right"), `stride` bytes apart.
        enum Value: String, Codable { case time, cursor, textureSize, boneMatrices, boneOpacity, effectValue, audioSpectrum }
        var offset: Int
        var value: Value
        var texture: String?
        var stride: Int?
        var key: String?
        var components: Int?
    }

    struct Stage: Codable, Equatable {
        var source: String
        var entryPoint: String
        var uniforms: Data = .init()
        var updates: [UniformUpdate] = []
    }

    struct Attribute: Codable, Equatable {
        enum Format: String, Codable { case float, float2, float3, float4, uint4 }
        var location: Int
        var offset: Int
        var format: Format
    }

    struct Draw: Codable, Equatable {
        enum Blend: String, Codable { case sourceOver, additive, maximum }
        struct Command: Codable, Equatable {
            var firstIndex: Int
            var indexCount: Int
            var textures: [Texture]?
            var fragmentUniforms: Data?
        }
        var vertex: Stage
        var fragment: Stage
        var vertices: Data
        var vertexStride: Int
        var vertexCount: Int
        var attributes: [Attribute]
        var textures: [Texture]
        var skeleton: SceneSkeleton?
        var skeletonID: UUID?
        var indices: Data?
        var blend: Blend?
        var commands: [Command]?
    }

    struct Pass: Codable, Equatable {
        enum Operation: String, Codable { case draw, copy }
        var operation: Operation
        var target: String
        var source: String?
        var draw: Draw?
    }

    // Input is the layer's image; named targets retain their contents between frames.
    // Keeping copy passes explicit preserves feedback without reading a render attachment.
    var targets: [Target]
    var passes: [Pass]
    var output: String
    /// Resource name to a plain file name in the scene folder.
    var images: [String: String] = [:]
    var straightAlphaImages: Bool?

    var usesAudio: Bool {
        uses(.audioSpectrum)
    }

    func uses(_ value: UniformUpdate.Value) -> Bool {
        passes.contains { pass in
            guard let draw = pass.draw else { return false }
            return (draw.vertex.updates + draw.fragment.updates).contains { $0.value == value }
        }
    }
}

/// The system audio's loudness per frequency band, low to high, each 0...1.
struct SceneAudioSpectrum: Equatable {
    static let bandCount = 64
    var left: [Float]
    var right: [Float]

    /// `count` bands (a divisor of 64), each the mean of the bands it covers.
    func bands(_ count: Int, right isRight: Bool) -> [Float] {
        let source = isRight ? right : left
        let group = Self.bandCount / count
        return (0 ..< count).map { band in
            source[band * group ..< (band + 1) * group].reduce(0, +) / Float(group)
        }
    }
}

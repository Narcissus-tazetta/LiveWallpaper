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
        enum Value: String, Codable { case time, cursor, textureSize, boneMatrices, boneOpacity, effectValue }
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

    func uses(_ value: UniformUpdate.Value) -> Bool {
        passes.contains { pass in
            guard let draw = pass.draw else { return false }
            return (draw.vertex.updates + draw.fragment.updates).contains { $0.value == value }
        }
    }
}

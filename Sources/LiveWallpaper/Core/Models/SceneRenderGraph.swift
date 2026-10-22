import Foundation

struct SceneRenderGraph: Codable, Equatable {
    struct Target: Codable, Equatable {
        enum Format: String, Codable { case rgba8, rgba16Float, r8, r16Float, rg16Float }
        var name: String
        /// Applied last, after `width`/`height` and `fit`.
        var scale: Double = 1
        var format: Format = .rgba8
        /// Fixed pixel sizes in place of the input's.
        var width: Int?
        var height: Int?
        /// The longer side is brought down to this many pixels, keeping the aspect;
        /// never enlarged.
        var fit: Int?
        /// The colour the target holds when it is made (straight RGBA); transparent
        /// black when absent.
        var clearColor: [Double]?
    }

    struct Texture: Codable, Equatable {
        var index: Int
        var source: String
        var repeats: Bool = false
        var linear: Bool = true
    }

    struct UniformUpdate: Codable, Equatable {
        /// `audioSpectrum` writes `components` bands (16, 32 or 64) of the `key` channel
        /// ("left" or "right"), `stride` bytes apart. `pointer` and `previousPointer` are
        /// the cursor in canvas UV this frame and the last, held where it was when the
        /// cursor is away. `layerFromCanvas` is a 4×4 matrix taking a point in canvas
        /// clip space (y up) to the clip space of the layer the graph draws, and
        /// `canvasFromLayer` its inverse; `screenFromLayer` is `canvasFromLayer` with y
        /// pointing down, so that clip × 0.5 + 0.5 reads `background` the way its rows
        /// run. `frameTime` is the seconds since the graph last
        /// drew; `pointerState` is 1 in z while the primary button is held (x, y, w are 0);
        /// `parallaxPosition` is the eased parallax input as 0...1 per axis. For `texture`,
        /// `texelSize` is one pixel of it in UV and `texelOffsets` that pixel both ways
        /// (x, y, −x, −y).
        enum Value: String, Codable {
            case time, cursor, textureSize, boneMatrices, boneOpacity, effectValue, audioSpectrum
            case pointer, previousPointer, layerFromCanvas, canvasFromLayer, screenFromLayer, frameTime, pointerState
            case parallaxPosition, texelSize, texelOffsets
        }
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
        /// `sourceOver`, `additive` and `maximum` take premultiplied colour; the two `alpha`
        /// cases weight straight colour by its own alpha (source alpha, then one or one
        /// minus source alpha), alpha channel included.
        enum Blend: String, Codable { case sourceOver, additive, maximum, alphaAdditive, alphaOver }
        struct Command: Codable, Equatable {
            var firstIndex: Int
            var indexCount: Int
            var textures: [Texture]?
            var fragmentUniforms: Data?
        }
        var vertex: Stage
        var fragment: Stage
        /// Ignored when `dynamic` is set.
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
        /// Quads that a script sends every frame instead of the fixed `vertices`.
        var dynamic: DynamicMesh?
        /// Whether the pass starts from a cleared target (the default). A pass that
        /// accumulates onto what an earlier pass drew sets this to false.
        var clears: Bool?
        /// false leaves the target's alpha as it was.
        var writesAlpha: Bool?
    }

    /// Geometry made at run time. Each mesh frame is four vertices per quad of nine
    /// floats (position xyz, uv, colour rgba), so `vertexStride` is 36.
    struct DynamicMesh: Codable, Equatable {
        /// Only meshes made for this parent are drawn by the pass.
        var parent: String
        /// Quads the pass draws per frame, at most 16383 (16-bit indices).
        var capacity: Int
        /// A mesh's material to the textures it samples. A `textureSize` update of the
        /// fragment stage names `slot:<index>` for the texture bound at that index.
        var materials: [String: [Texture]]
    }

    struct Pass: Codable, Equatable {
        /// `swap` exchanges the contents of `source` and `target` (two targets of the
        /// same size and format), for ping-pong simulations that run on across frames.
        enum Operation: String, Codable { case draw, copy, swap }
        var operation: Operation
        var target: String
        var source: String?
        var draw: Draw?
    }

    /// Reserved resource: the canvas as drawn below the layer, at the size it is drawn.
    static let background = "background"

    // Input is the layer's image; named targets retain their contents between frames.
    // Keeping copy passes explicit preserves feedback without reading a render attachment.
    var targets: [Target]
    var passes: [Pass]
    var output: String
    /// Resource name to a plain file name in the scene folder.
    var images: [String: String] = [:]
    var straightAlphaImages: Bool?

    var readsBackground: Bool {
        passes.contains { pass in
            pass.source == Self.background || (pass.draw.map { draw in
                (draw.textures + (draw.commands ?? []).flatMap { $0.textures ?? [] }).contains { $0.source == Self.background }
            } ?? false)
        }
    }

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

/// One mesh a script made, as it should look this frame.
struct SceneMeshFrame: Equatable {
    static let floatsPerQuad = 36
    static let vertexStride = 36
    var parent: String
    var material: String
    /// Whole quads: 36 floats each.
    var vertices: [Float]
}

/// The system audio's loudness per frequency band, low to high, normally 0...1.
struct SceneAudioSpectrum: Equatable {
    static let bandCount = 64
    var left: [Float]
    var right: [Float]

    /// `count` bands (a divisor of 64), each the loudest of the bands it covers.
    func bands(_ count: Int, right isRight: Bool) -> [Float] {
        let source = isRight ? right : left
        let group = Self.bandCount / count
        return (0 ..< count).map { band in
            source[band * group ..< (band + 1) * group].max()!
        }
    }
}

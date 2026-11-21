import Foundation
import simd

/// Reads the parts of a glTF 2.0 file (`.gltf` with its buffers, or `.glb`) that a scene's
/// model layer can show: triangle meshes, metallic-roughness materials with PNG/JPEG
/// images, skins and node animations.
struct GLTFAsset {
    struct ReadError: LocalizedError {
        let detail: String
        var errorDescription: String? {
            "glTF: \(detail)"
        }
    }

    struct MorphTarget {
        let position: [SIMD3<Float>]?
        let normal: [SIMD3<Float>]?
        let tangent: [SIMD3<Float>]?
    }

    struct Primitive {
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]?
        var tangents: [SIMD4<Float>]?
        var uvs: [SIMD2<Float>]?
        var colors: [SIMD4<Float>]?
        var joints: [SIMD4<UInt32>]?
        var weights: [SIMD4<Float>]?
        /// Three to a triangle.
        var indices: [UInt32]
        var material: Int?
        var targets: [MorphTarget]
    }

    struct Node {
        var name: String
        var children: [Int]
        var mesh: Int?
        var skin: Int?
        var camera: Int?
        var light: Int?
        var morphWeights: [Float]
        var translation: SIMD3<Float>
        var rotation: simd_quatf
        var scale: SIMD3<Float>

        var local: simd_float4x4 {
            var matrix = simd_float4x4(rotation)
            matrix.columns.0 *= scale.x
            matrix.columns.1 *= scale.y
            matrix.columns.2 *= scale.z
            matrix.columns.3 = SIMD4(translation, 1)
            return matrix
        }
    }

    struct Skin {
        var joints: [Int]
        var inverseBind: [simd_float4x4]
    }

    struct TextureRef {
        var image: Int
        var repeats: Bool
        var scale: Float
    }

    struct Material {
        var name: String
        var baseColor: SIMD4<Float>
        var baseColorTexture: TextureRef?
        var metallic: Float
        var roughness: Float
        var metallicRoughnessTexture: TextureRef?
        var normalTexture: TextureRef?
        var occlusionTexture: TextureRef?
        var emissive: SIMD3<Float>
        var emissiveTexture: TextureRef?
        var alphaMode: String
        var alphaCutoff: Float
        var doubleSided: Bool
        var unlit: Bool
    }

    struct Image {
        var data: Data
        /// "png" or "jpg".
        var fileExtension: String
    }

    struct Channel {
        enum Path: String { case translation, rotation, scale, weights }
        var node: Int
        var path: Path
        var times: [Float]
        /// Three or four floats a key; three keys' worth (in-tangent, value, out-tangent) for a
        /// cubic spline.
        var values: [Float]
        var interpolation: String
    }

    struct Animation {
        var name: String
        var channels: [Channel]
    }

    var nodes: [Node]
    var cameras: [Camera]
    var lights: [Light]
    var meshes: [[Primitive]]
    var skins: [Skin]
    var materials: [Material]
    var images: [Image]
    var animations: [Animation]
    /// The nodes of the scene to show.
    var roots: [Int]
}

extension GLTFAsset {
    private struct JSONRoot: Decodable {
        struct Buffer: Decodable { var uri: String?; var byteLength: Int }
        struct BufferView: Decodable {
            struct Extensions: Decodable {
                let extMeshopt: GLTFMeshCompression?
                let khrMeshopt: GLTFMeshCompression?

                enum CodingKeys: String, CodingKey {
                    case extMeshopt = "EXT_meshopt_compression"
                    case khrMeshopt = "KHR_meshopt_compression"
                }
            }

            var buffer: Int; var byteOffset: Int?; var byteLength: Int; var byteStride: Int?
            var extensions: Extensions?
        }

        struct Accessor: Decodable {
            struct Sparse: Decodable {
                struct Indices: Decodable {
                    let bufferView: Int
                    let byteOffset: Int?
                    let componentType: Int
                }

                struct Values: Decodable {
                    let bufferView: Int
                    let byteOffset: Int?
                }

                let count: Int
                let indices: Indices
                let values: Values
            }

            var bufferView: Int?
            var byteOffset: Int?
            var componentType: Int
            var normalized: Bool?
            var count: Int
            var type: String
            var sparse: Sparse?
        }

        struct Primitive: Decodable {
            struct Extensions: Decodable {
                struct Draco: Decodable {
                    let bufferView: Int
                    let attributes: [String: UInt32]
                }

                let draco: Draco?

                enum CodingKeys: String, CodingKey {
                    case draco = "KHR_draco_mesh_compression"
                }
            }

            var extensions: Extensions?
            var attributes: [String: Int]
            var indices: Int?
            var material: Int?
            var mode: Int?
            var targets: [[String: Int]]?
        }

        struct Mesh: Decodable {
            var primitives: [Primitive]
            var weights: [Float]?
        }

        struct Node: Decodable {
            struct Extensions: Decodable {
                struct Punctual: Decodable { let light: Int }
                let punctual: Punctual?

                enum CodingKeys: String, CodingKey {
                    case punctual = "KHR_lights_punctual"
                }
            }

            var extensions: Extensions?
            var camera: Int?
            var name: String?
            var children: [Int]?
            var mesh: Int?
            var skin: Int?
            var weights: [Float]?
            var matrix: [Float]?
            var translation: [Float]?
            var rotation: [Float]?
            var scale: [Float]?
        }

        struct Skin: Decodable { var joints: [Int]; var inverseBindMatrices: Int? }
        struct TextureInfo: Decodable {
            var index: Int; var texCoord: Int?; var scale: Float?; var strength: Float?
        }

        struct PBR: Decodable {
            var baseColorFactor: [Float]?
            var baseColorTexture: TextureInfo?
            var metallicFactor: Float?
            var roughnessFactor: Float?
            var metallicRoughnessTexture: TextureInfo?
        }

        struct Material: Decodable {
            var name: String?
            var pbrMetallicRoughness: PBR?
            var normalTexture: TextureInfo?
            var occlusionTexture: TextureInfo?
            var emissiveTexture: TextureInfo?
            var emissiveFactor: [Float]?
            var alphaMode: String?
            var alphaCutoff: Float?
            var doubleSided: Bool?
            var extensions: [String: AnyCodable]?
        }

        struct Texture: Decodable { var sampler: Int?; var source: Int? }
        struct Sampler: Decodable { var wrapS: Int?; var wrapT: Int? }
        struct Image: Decodable { var uri: String?; var mimeType: String?; var bufferView: Int? }
        struct AnimationChannel: Decodable {
            struct Target: Decodable { var node: Int?; var path: String }
            var sampler: Int
            var target: Target
        }

        struct AnimationSampler: Decodable {
            var input: Int; var output: Int; var interpolation: String?
        }

        struct Animation: Decodable {
            var name: String?; var channels: [AnimationChannel]; var samplers: [AnimationSampler]
        }

        struct Scene: Decodable { var nodes: [Int]? }
        struct Asset: Decodable { var version: String }

        struct Extensions: Decodable {
            struct Punctual: Decodable { let lights: [GLTFAsset.Light] }
            let punctual: Punctual?

            enum CodingKeys: String, CodingKey {
                case punctual = "KHR_lights_punctual"
            }
        }

        var extensions: Extensions?
        var cameras: [GLTFAsset.Camera]?
        var asset: Asset
        var extensionsRequired: [String]?
        var buffers: [Buffer]?
        var bufferViews: [BufferView]?
        var accessors: [Accessor]?
        var meshes: [Mesh]?
        var nodes: [Node]?
        var skins: [Skin]?
        var materials: [Material]?
        var textures: [Texture]?
        var samplers: [Sampler]?
        var images: [Image]?
        var animations: [Animation]?
        var scenes: [Scene]?
        var scene: Int?
    }

    /// Present or not is all that is read of these.
    private struct AnyCodable: Decodable {
        init(from _: Decoder) throws {}
    }

    /// Extensions whose absence changes how the model looks; others that a file requires
    /// are refused.
    private static let supportedExtensions: Set<String> = [
        "KHR_materials_unlit", "KHR_mesh_quantization", "EXT_meshopt_compression",
        "KHR_meshopt_compression",
        "KHR_draco_mesh_compression", "KHR_lights_punctual"
    ]

    /// An accessor without a buffer view is filled with zeros, so its count alone sizes the
    /// allocation.
    private static let maximumElements = 1 << 26

    private struct BufferReader {
        private let buffers: [JSONRoot.Buffer]
        let views: [JSONRoot.BufferView]
        private let folder: URL
        private let binary: Data?
        private var loadedBuffers: [Int: Data] = [:]
        private var decodedViews: [Int: Data] = [:]
        private var remainingDecodedBytes = 256 * 1024 * 1024

        init(root: JSONRoot, folder: URL, binary: Data?) {
            buffers = root.buffers ?? []
            views = root.bufferViews ?? []
            self.folder = folder
            self.binary = binary
        }

        private mutating func bufferBytes(_ index: Int, offset: Int, length: Int) throws -> Data {
            guard buffers.indices.contains(index) else {
                throw ReadError(detail: "unknown buffer \(index)")
            }
            let buffer = buffers[index]
            guard offset >= 0, length >= 0, offset <= buffer.byteLength,
                  length <= buffer.byteLength - offset
            else { throw ReadError(detail: "byte range runs past buffer \(index)") }
            let data: Data
            if let loaded = loadedBuffers[index] {
                data = loaded
            } else {
                if let uri = buffer.uri {
                    data = try load(uri: uri, folder: folder)
                } else if index == 0, let binary {
                    data = binary
                } else {
                    throw ReadError(detail: "buffer \(index) has no data")
                }
                guard data.count >= buffer.byteLength else {
                    throw ReadError(detail: "buffer \(index) is shorter than it says")
                }
                loadedBuffers[index] = data
            }
            return data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + length)
        }

        mutating func viewBytes(_ index: Int) throws -> Data {
            guard views.indices.contains(index) else {
                throw ReadError(detail: "unknown buffer view \(index)")
            }
            let view = views[index]
            guard let compression = view.extensions?.khrMeshopt ?? view.extensions?.extMeshopt
            else {
                return try bufferBytes(
                    view.buffer,
                    offset: view.byteOffset ?? 0,
                    length: view.byteLength
                )
            }
            if let decoded = decodedViews[index] {
                return decoded
            }
            guard view.byteLength <= remainingDecodedBytes else {
                throw ReadError(detail: "meshopt buffers exceed the 256 MiB decoded limit")
            }
            let source = try bufferBytes(
                compression.buffer, offset: compression.byteOffset ?? 0,
                length: compression.byteLength
            )
            let decoded = try compression.decode(
                source,
                length: view.byteLength,
                stride: view.byteStride
            )
            remainingDecodedBytes -= decoded.count
            decodedViews[index] = decoded
            return decoded
        }
    }

    static func read(url: URL) throws -> GLTFAsset {
        let file = try Data(contentsOf: url)
        let folder = url.deletingLastPathComponent()
        var json = file
        var binary: Data?
        if file.count >= 12, file.prefix(4) == Data("glTF".utf8) {
            (json, binary) = try splitGLB(file)
        }
        let root: JSONRoot
        do {
            root = try JSONDecoder().decode(JSONRoot.self, from: json)
        } catch {
            throw ReadError(detail: "the file is not glTF JSON (\(error.localizedDescription))")
        }
        guard root.asset.version.hasPrefix("2.") else {
            throw ReadError(detail: "version \(root.asset.version) is not glTF 2")
        }
        let unsupported = Set(root.extensionsRequired ?? []).subtracting(supportedExtensions)
        guard unsupported.isEmpty else {
            throw ReadError(
                detail: "needs \(unsupported.sorted().joined(separator: ", ")), which this app does not read"
            )
        }

        var reader = BufferReader(root: root, folder: folder, binary: binary)
        let accessors = root.accessors ?? []

        /// The accessor's elements in `bytes`: their start and the distance between them.
        /// The file's numbers are checked before any arithmetic, which would trap on overflow.
        func layout(
            _ index: Int,
            _ accessor: JSONRoot.Accessor,
            viewIndex: Int,
            elementSize: Int,
            bytes: Data
        ) throws -> (offset: Int, stride: Int) {
            let stride = reader.views[viewIndex].byteStride ?? elementSize
            let offset = accessor.byteOffset ?? 0
            guard (elementSize ... 256).contains(stride), (0 ... bytes.count).contains(offset),
                  accessor.count <= bytes.count
            else {
                throw ReadError(detail: "accessor \(index) runs past its buffer view")
            }
            // Bound the multiplication by the available bytes before computing any element offsets.
            // swiftlint:disable:next empty_count
            if accessor.count > 0 {
                let remaining = bytes.count - offset
                guard elementSize <= remaining,
                      accessor.count - 1 <= (remaining - elementSize) / stride
                else {
                    throw ReadError(detail: "accessor \(index) runs past its buffer view")
                }
            }
            return (offset, stride)
        }

        struct AccessorBytes {
            let bytes: Data
            let offset: Int
            let stride: Int
        }

        func accessorBytes(
            _ index: Int, accessor: JSONRoot.Accessor, elementSize: Int, decoded: Data?
        ) throws -> AccessorBytes? {
            let base: AccessorBytes?
            if let decoded {
                base = AccessorBytes(bytes: decoded, offset: 0, stride: elementSize)
            } else if let viewIndex = accessor.bufferView {
                let bytes = try reader.viewBytes(viewIndex)
                let (offset, stride) = try layout(
                    index, accessor, viewIndex: viewIndex, elementSize: elementSize, bytes: bytes
                )
                base = AccessorBytes(bytes: bytes, offset: offset, stride: stride)
            } else {
                base = nil
            }
            guard let sparse = accessor.sparse else { return base }
            guard sparse.count >= 1, sparse.count <= accessor.count,
                  accessor.count <= (256 * 1024 * 1024) / elementSize,
                  [5121, 5123, 5125].contains(sparse.indices.componentType)
            else { throw ReadError(detail: "accessor \(index) has an invalid sparse layout") }
            let size = try componentSize(sparse.indices.componentType)
            let indices = try reader.viewBytes(sparse.indices.bufferView)
            let values = try reader.viewBytes(sparse.values.bufferView)
            let indexOffset = sparse.indices.byteOffset ?? 0
            let valueOffset = sparse.values.byteOffset ?? 0
            guard (0 ... indices.count).contains(indexOffset),
                  (0 ... values.count).contains(valueOffset),
                  sparse.count <= (indices.count - indexOffset) / size,
                  sparse.count <= (values.count - valueOffset) / elementSize
            else { throw ReadError(detail: "accessor \(index) has truncated sparse data") }

            var bytes = Data(count: accessor.count * elementSize)
            try bytes.withUnsafeMutableBytes { output in
                if let base {
                    base.bytes.withUnsafeBytes { input in
                        for i in 0 ..< accessor.count {
                            output.baseAddress!.advanced(by: i * elementSize).copyMemory(
                                from: input.baseAddress!
                                    .advanced(by: base.offset + i * base.stride),
                                byteCount: elementSize
                            )
                        }
                    }
                }
                try indices.withUnsafeBytes { rawIndices in
                    try values.withUnsafeBytes { rawValues in
                        var previous = -1
                        for i in 0 ..< sparse.count {
                            let at = indexOffset + i * size
                            let target = switch size {
                            case 1: Int(rawIndices.loadUnaligned(
                                    fromByteOffset: at,
                                    as: UInt8.self
                                ))
                            case 2: Int(rawIndices
                                    .loadUnaligned(fromByteOffset: at, as: UInt16.self)
                                    .littleEndian)
                            default: Int(rawIndices.loadUnaligned(
                                    fromByteOffset: at,
                                    as: UInt32.self
                                ).littleEndian)
                            }
                            guard target > previous, target < accessor.count else {
                                throw ReadError(
                                    detail: "accessor \(index) has unordered or out-of-range sparse indices"
                                )
                            }
                            output.baseAddress!.advanced(by: target * elementSize).copyMemory(
                                from: rawValues.baseAddress!
                                    .advanced(by: valueOffset + i * elementSize),
                                byteCount: elementSize
                            )
                            previous = target
                        }
                    }
                }
            }
            return AccessorBytes(bytes: bytes, offset: 0, stride: elementSize)
        }

        /// Each element's components as floats, normalized integers mapped as the spec says.
        func floats(
            _ index: Int,
            components expected: Set<Int>,
            decoded: Data? = nil
        ) throws -> (values: [Float], components: Int) {
            guard accessors.indices.contains(index)
            else { throw ReadError(detail: "unknown accessor \(index)") }
            let accessor = accessors[index]
            let components = try componentCount(accessor.type)
            guard expected.contains(components)
            else { throw ReadError(detail: "accessor \(index) has type \(accessor.type)") }
            guard (0 ... maximumElements).contains(accessor.count)
            else { throw ReadError(detail: "accessor \(index) has \(accessor.count) elements") }
            let size = try componentSize(accessor.componentType)
            guard let source = try accessorBytes(
                index, accessor: accessor, elementSize: size * components, decoded: decoded
            ) else {
                return (Array(repeating: 0, count: accessor.count * components), components)
            }
            let normalized = accessor.normalized == true
            var values = [Float]()
            values.reserveCapacity(accessor.count * components)
            source.bytes.withUnsafeBytes { raw in
                for element in 0 ..< accessor.count {
                    for component in 0 ..< components {
                        let at = source.offset + element * source.stride + component * size
                        let value: Float = switch accessor.componentType {
                        case 5126: Float(bitPattern: raw.loadUnaligned(
                                fromByteOffset: at,
                                as: UInt32.self
                            ).littleEndian)
                        case 5120:
                            // swiftlint:disable:next void_function_in_ternary
                            normalized ? max(
                                Float(raw.loadUnaligned(fromByteOffset: at, as: Int8.self)) / 127,
                                -1
                            )
                                : Float(raw.loadUnaligned(fromByteOffset: at, as: Int8.self))
                        case 5121:
                            Float(raw.loadUnaligned(fromByteOffset: at, as: UInt8.self)) /
                                (normalized ? 255 : 1)
                        case 5122:
                            // swiftlint:disable:next void_function_in_ternary
                            normalized ? max(
                                Float(Int16(littleEndian: raw.loadUnaligned(
                                    fromByteOffset: at,
                                    as: Int16.self
                                ))) / 32767,
                                -1
                            )
                                : Float(Int16(littleEndian: raw.loadUnaligned(
                                    fromByteOffset: at,
                                    as: Int16.self
                                )))
                        case 5123:
                            Float(UInt16(littleEndian: raw.loadUnaligned(
                                fromByteOffset: at,
                                as: UInt16.self
                            ))) / (normalized ? 65535 : 1)
                        default:
                            Float(UInt32(littleEndian: raw.loadUnaligned(
                                fromByteOffset: at,
                                as: UInt32.self
                            )))
                        }
                        values.append(value)
                    }
                }
            }
            return (values, components)
        }

        func integers(
            _ index: Int,
            components expected: Int,
            decoded: Data? = nil
        ) throws -> [UInt32] {
            guard accessors.indices.contains(index)
            else { throw ReadError(detail: "unknown accessor \(index)") }
            let accessor = accessors[index]
            guard try componentCount(accessor.type) == expected,
                  [5121, 5123, 5125].contains(accessor.componentType)
            else {
                throw ReadError(detail: "accessor \(index) does not hold unsigned integers")
            }
            guard (0 ... maximumElements).contains(accessor.count)
            else { throw ReadError(detail: "accessor \(index) has \(accessor.count) elements") }
            let size = try componentSize(accessor.componentType)
            guard let source = try accessorBytes(
                index, accessor: accessor, elementSize: size * expected, decoded: decoded
            ) else {
                return Array(repeating: 0, count: accessor.count * expected)
            }
            var values = [UInt32]()
            values.reserveCapacity(accessor.count * expected)
            source.bytes.withUnsafeBytes { raw in
                for element in 0 ..< accessor.count {
                    for component in 0 ..< expected {
                        let at = source.offset + element * source.stride + component * size
                        let value = switch accessor.componentType {
                        case 5121: UInt32(raw.loadUnaligned(fromByteOffset: at, as: UInt8.self))
                        case 5123: UInt32(UInt16(littleEndian: raw.loadUnaligned(
                                fromByteOffset: at,
                                as: UInt16.self
                            )))
                        default: UInt32(littleEndian: raw.loadUnaligned(
                                fromByteOffset: at,
                                as: UInt32.self
                            ))
                        }
                        values.append(value)
                    }
                }
            }
            return values
        }

        func vec3(_ index: Int, decoded: Data? = nil) throws -> [SIMD3<Float>] {
            let (values, _) = try floats(index, components: [3], decoded: decoded)
            return stride(from: 0, to: values.count, by: 3).map { SIMD3(
                values[$0],
                values[$0 + 1],
                values[$0 + 2]
            ) }
        }

        func vec4(
            _ index: Int,
            allowing components: Set<Int> = [4],
            decoded: Data? = nil
        ) throws -> [SIMD4<Float>] {
            let (values, count) = try floats(index, components: components, decoded: decoded)
            return stride(from: 0, to: values.count, by: count).map {
                count == 3 ? SIMD4(values[$0], values[$0 + 1], values[$0 + 2], 1)
                    : SIMD4(values[$0], values[$0 + 1], values[$0 + 2], values[$0 + 3])
            }
        }

        var remainingMorphBytes = 256 * 1024 * 1024
        func morphDeltas(_ index: Int?, count: Int) throws -> [SIMD3<Float>]? {
            guard let index else { return nil }
            let stride = MemoryLayout<SIMD3<Float>>.stride
            guard accessors.indices.contains(index), accessors[index].count == count,
                  count <= remainingMorphBytes / stride
            else { throw ReadError(detail: "invalid or oversized morph target accessor \(index)") }
            let deltas = try vec3(index)
            guard deltas.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
            else {
                throw ReadError(detail: "morph target accessor \(index) contains non-finite deltas")
            }
            remainingMorphBytes -= count * stride
            return deltas
        }

        func readMeshes() throws -> [[Primitive]] {
            return try (root.meshes ?? []).enumerated().map { meshIndex, mesh in
                try mesh.primitives.compactMap { primitive -> Primitive? in
                    // Points and lines have no surface to shade.
                    let compression = primitive.extensions?.draco
                    let mode = primitive.mode ?? 4
                    guard mode == 4 || (mode == 5 && compression != nil) else { return nil }
                    guard let positionAccessor = primitive.attributes["POSITION"] else {
                        throw ReadError(
                            detail: "mesh \(meshIndex) has a primitive without positions"
                        )
                    }
                    let draco = try compression.map {
                        try GLTFDracoMesh(
                            data: reader.viewBytes($0.bufferView),
                            vertexLimit: SceneModelImporter.maximumVertices,
                            indexLimit: maximumElements
                        )
                    }
                    func decodedAttribute(
                        _ semantic: String,
                        _ accessorIndex: Int
                    ) throws -> Data? {
                        guard let draco,
                              let id = compression?.attributes[semantic] else { return nil }
                        guard accessors.indices.contains(accessorIndex) else {
                            throw ReadError(detail: "unknown accessor \(accessorIndex)")
                        }
                        let accessor = accessors[accessorIndex]
                        let components = try componentCount(accessor.type)
                        guard (1 ... 4).contains(components),
                              accessor.count == draco.pointCount
                        else {
                            throw ReadError(detail: "Draco \(semantic) does not match its accessor")
                        }
                        return try draco.attribute(
                            id: id, type: accessor.componentType, components: components,
                            componentSize: componentSize(accessor.componentType)
                        )
                    }
                    let positions = try vec3(
                        positionAccessor,
                        decoded: decodedAttribute("POSITION", positionAccessor)
                    )
                    let indices: [UInt32]
                    if let draco {
                        if let index = primitive.indices {
                            guard accessors.indices.contains(index),
                                  accessors[index].type == "SCALAR",
                                  accessors[index].count == draco.indexCount,
                                  [5121, 5123, 5125].contains(accessors[index].componentType)
                            else {
                                throw ReadError(detail: "Draco indices do not match their accessor")
                            }
                        }
                        indices = draco.indices()
                    } else if let index = primitive.indices {
                        indices = try integers(index, components: 1)
                    } else {
                        indices = Array(0 ..< UInt32(positions.count))
                    }
                    guard indices.count % 3 == 0,
                          indices.allSatisfy({ Int($0) < positions.count })
                    else {
                        throw ReadError(
                            detail: "mesh \(meshIndex) has indices outside its vertices"
                        )
                    }
                    func matching<T>(_ values: [T]?, _ name: String) throws -> [T]? {
                        guard let values else { return nil }
                        guard values.count == positions.count
                        else {
                            throw ReadError(
                                detail: "mesh \(meshIndex) \(name) count differs from positions"
                            )
                        }
                        return values
                    }
                    let uvs = try primitive.attributes["TEXCOORD_0"]
                        .map { index -> [SIMD2<Float>] in
                            let (values, _) = try floats(
                                index,
                                components: [2],
                                decoded: decodedAttribute("TEXCOORD_0", index)
                            )
                            return stride(from: 0, to: values.count, by: 2).map { SIMD2(
                                values[$0],
                                values[$0 + 1]
                            ) }
                        }
                    let joints = try primitive.attributes["JOINTS_0"]
                        .map { index -> [SIMD4<UInt32>] in
                            let values = try integers(
                                index,
                                components: 4,
                                decoded: decodedAttribute("JOINTS_0", index)
                            )
                            return stride(from: 0, to: values.count, by: 4).map { SIMD4(
                                values[$0],
                                values[$0 + 1],
                                values[$0 + 2],
                                values[$0 + 3]
                            ) }
                        }
                    return try Primitive(
                        positions: positions,
                        normals: matching(
                            primitive.attributes["NORMAL"].map { try vec3(
                                $0,
                                decoded: decodedAttribute("NORMAL", $0)
                            ) },
                            "normal"
                        ),
                        tangents: matching(
                            primitive.attributes["TANGENT"].map { try vec4(
                                $0,
                                decoded: decodedAttribute("TANGENT", $0)
                            ) },
                            "tangent"
                        ),
                        uvs: matching(uvs, "uv"),
                        colors: matching(
                            primitive.attributes["COLOR_0"].map { try vec4(
                                $0,
                                allowing: [3, 4],
                                decoded: decodedAttribute("COLOR_0", $0)
                            ) },
                            "colour"
                        ),
                        joints: matching(joints, "joint"),
                        weights: matching(
                            primitive.attributes["WEIGHTS_0"].map { try vec4(
                                $0,
                                decoded: decodedAttribute("WEIGHTS_0", $0)
                            ) },
                            "weight"
                        ),
                        indices: indices,
                        material: primitive.material,
                        targets: (primitive.targets ?? []).map { target in
                            try MorphTarget(
                                position: morphDeltas(target["POSITION"], count: positions.count),
                                normal: morphDeltas(target["NORMAL"], count: positions.count),
                                tangent: morphDeltas(target["TANGENT"], count: positions.count)
                            )
                        }
                    )
                }
            }
        }
        let meshes = try readMeshes()

        let cameras = root.cameras ?? []
        let lights = root.extensions?.punctual?.lights ?? []
        func readNodes() throws -> [Node] {
            let nodes = try (root.nodes ?? []).enumerated().map { index, node -> Node in
                var translation = SIMD3<Float>(repeating: 0), rotation = simd_quatf(
                    ix: 0,
                    iy: 0,
                    iz: 0,
                    r: 1
                ), scale = SIMD3<Float>(repeating: 1)
                if let m = node.matrix {
                    guard m.count == 16,
                          m.allSatisfy(\.isFinite)
                    else { throw ReadError(detail: "node \(index) has an invalid matrix") }
                    (translation, rotation, scale) = decompose(simd_float4x4(columns: (
                        SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                        SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])
                    )))
                }
                if let t = node.translation, t.count == 3 { translation = SIMD3(t[0], t[1], t[2]) }
                if let r = node.rotation, r.count == 4 { rotation = simd_normalize(simd_quatf(
                    ix: r[0],
                    iy: r[1],
                    iz: r[2],
                    r: r[3]
                )) }
                if let s = node.scale, s.count == 3 { scale = SIMD3(s[0], s[1], s[2]) }
                if let mesh = node.mesh,
                   !meshes.indices
                   .contains(mesh)
                { throw ReadError(detail: "node \(index) names an unknown mesh")
                }
                if let skin = node.skin,
                   !(root.skins ?? []).indices
                   .contains(skin)
                { throw ReadError(detail: "node \(index) names an unknown skin")
                }
                let targetCount = node.mesh.flatMap { meshes[$0].first?.targets.count } ?? 0
                let morphWeights = node.weights ?? node.mesh.flatMap { root.meshes?[$0].weights }
                    ?? Array(repeating: 0, count: targetCount)
                guard morphWeights.count == targetCount, morphWeights.allSatisfy(\.isFinite),
                      node.mesh
                      .map({ meshes[$0].allSatisfy { $0.targets.count == targetCount } }) ?? true
                else { throw ReadError(detail: "node \(index) has invalid morph weights") }
                let light = node.extensions?.punctual?.light
                guard node.camera.map(cameras.indices.contains) ?? true,
                      light.map(lights.indices.contains) ?? true
                else { throw ReadError(detail: "node \(index) names an unknown camera or light") }
                return Node(
                    name: node.name ?? "node \(index)", children: node.children ?? [],
                    mesh: node.mesh,
                    skin: node.skin, camera: node.camera, light: light, morphWeights: morphWeights,
                    translation: translation, rotation: rotation, scale: scale
                )
            }
            guard nodes.allSatisfy({ $0.children.allSatisfy(nodes.indices.contains) }) else {
                throw ReadError(detail: "a node names an unknown child")
            }
            return nodes
        }
        let nodes = try readNodes()

        let skins = try (root.skins ?? []).map { skin -> Skin in
            guard skin.joints.allSatisfy(nodes.indices.contains)
            else { throw ReadError(detail: "a skin names an unknown joint") }
            let inverseBind: [simd_float4x4]
            if let accessor = skin.inverseBindMatrices {
                let (values, _) = try floats(accessor, components: [16])
                guard values.count == skin.joints.count * 16
                else {
                    throw ReadError(detail: "a skin's bind matrices do not match its joints")
                }
                inverseBind = stride(from: 0, to: values.count, by: 16).map { o in
                    simd_float4x4(columns: (
                        SIMD4(values[o], values[o + 1], values[o + 2], values[o + 3]),
                        SIMD4(values[o + 4], values[o + 5], values[o + 6], values[o + 7]),
                        SIMD4(values[o + 8], values[o + 9], values[o + 10], values[o + 11]),
                        SIMD4(values[o + 12], values[o + 13], values[o + 14], values[o + 15])
                    ))
                }
            } else {
                inverseBind = Array(repeating: matrix_identity_float4x4, count: skin.joints.count)
            }
            return Skin(joints: skin.joints, inverseBind: inverseBind)
        }

        let samplers = root.samplers ?? []
        let textures = root.textures ?? []
        let imageCount = (root.images ?? []).count
        func texture(_ info: JSONRoot.TextureInfo?) throws -> TextureRef? {
            guard let info else { return nil }
            // Only the first set of texture coordinates is carried; a texture on another set is
            // left out.
            guard (info.texCoord ?? 0) == 0 else { return nil }
            guard textures.indices.contains(info.index), let image = textures[info.index].source,
                  (0 ..< imageCount).contains(image)
            else {
                throw ReadError(detail: "a material names an unknown texture")
            }
            let sampler = textures[info.index].sampler
                .flatMap { samplers.indices.contains($0) ? samplers[$0] : nil }
            // Mirrored repeat is drawn as plain repeat.
            let repeats = (sampler?.wrapS ?? 10497) != 33071 || (sampler?.wrapT ?? 10497) != 33071
            return TextureRef(
                image: image,
                repeats: repeats,
                scale: info.scale ?? info.strength ?? 1
            )
        }
        let materials = try (root.materials ?? []).map { material -> Material in
            let pbr = material.pbrMetallicRoughness
            let base = pbr?.baseColorFactor ?? [1, 1, 1, 1]
            let emissive = material.emissiveFactor ?? [0, 0, 0]
            guard base.count == 4,
                  emissive.count == 3
            else { throw ReadError(detail: "a material has malformed factors") }
            return try Material(
                name: material.name ?? "",
                baseColor: SIMD4(base[0], base[1], base[2], base[3]),
                baseColorTexture: texture(pbr?.baseColorTexture),
                metallic: pbr?.metallicFactor ?? 1,
                roughness: pbr?.roughnessFactor ?? 1,
                metallicRoughnessTexture: texture(pbr?.metallicRoughnessTexture),
                normalTexture: texture(material.normalTexture),
                occlusionTexture: texture(material.occlusionTexture),
                emissive: SIMD3(emissive[0], emissive[1], emissive[2]),
                emissiveTexture: texture(material.emissiveTexture),
                alphaMode: material.alphaMode ?? "OPAQUE",
                alphaCutoff: material.alphaCutoff ?? 0.5,
                doubleSided: material.doubleSided ?? false,
                unlit: material.extensions?["KHR_materials_unlit"] != nil
            )
        }
        guard meshes
            .allSatisfy({ $0.allSatisfy { $0.material.map(materials.indices.contains) ?? true } })
        else {
            throw ReadError(detail: "a mesh names an unknown material")
        }

        func readImages() throws -> [Image] {
            return try (root.images ?? []).enumerated().map { index, image -> Image in
                let data: Data
                if let view = image.bufferView {
                    data = try reader.viewBytes(view)
                } else if let uri = image.uri {
                    data = try load(uri: uri, folder: folder)
                } else {
                    throw ReadError(detail: "image \(index) has no data")
                }
                if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return Image(
                    data: data,
                    fileExtension: "png"
                ) }
                if data
                    .starts(with: [0xFF, 0xD8, 0xFF])
                { return Image(
                    data: data,
                    fileExtension: "jpg"
                ) }
                throw ReadError(detail: "image \(index) is neither PNG nor JPEG")
            }
        }
        let images = try readImages()

        func readAnimations() throws -> [Animation] {
            return try (root.animations ?? []).enumerated()
                .map { index, animation -> Animation in
                    let channels = try animation.channels.compactMap { channel -> Channel? in
                        guard let node = channel.target.node,
                              let path = Channel.Path(rawValue: channel.target.path)
                        else { return nil }
                        guard nodes.indices.contains(node),
                              animation.samplers.indices.contains(channel.sampler)
                        else {
                            throw ReadError(
                                detail: "animation \(index) names an unknown node or sampler"
                            )
                        }
                        let sampler = animation.samplers[channel.sampler]
                        let (times, _) = try floats(sampler.input, components: [1])
                        let interpolation = sampler.interpolation ?? "LINEAR"
                        if path == .weights {
                            let (values, _) = try floats(sampler.output, components: [1])
                            let curve = SceneMorphCurve(
                                times: times, values: values, interpolation: interpolation,
                                width: nodes[node].morphWeights.count
                            )
                            guard curve.isValid else {
                                throw ReadError(detail: "animation \(index) has malformed weights")
                            }
                            return Channel(
                                node: node,
                                path: path,
                                times: times,
                                values: values,
                                interpolation: interpolation
                            )
                        }
                        let (values, components) = try floats(sampler.output, components: [3, 4])
                        let perKey = (path == .rotation ? 4 : 3) *
                            (interpolation == "CUBICSPLINE" ? 3 : 1)
                        guard components == (path == .rotation ? 4 : 3),
                              values.count == times.count * perKey, !times.isEmpty,
                              times.allSatisfy(\.isFinite),
                              zip(times, times.dropFirst()).allSatisfy({ $0 <= $1 })
                        else { throw ReadError(detail: "animation \(index) has malformed keys") }
                        return Channel(
                            node: node,
                            path: path,
                            times: times,
                            values: values,
                            interpolation: interpolation
                        )
                    }
                    return Animation(
                        name: animation.name ?? "animation \(index + 1)",
                        channels: channels
                    )
                }.filter { !$0.channels.isEmpty }
        }
        let animations = try readAnimations()

        let scenes = root.scenes ?? []
        let roots: [Int]
        if let sceneIndex = root.scene ?? (scenes.isEmpty ? nil : 0) {
            guard scenes.indices.contains(sceneIndex)
            else { throw ReadError(detail: "unknown scene \(sceneIndex)") }
            roots = scenes[sceneIndex].nodes ?? []
        } else {
            // Without scenes, every node that is no other's child is shown.
            let children = Set(nodes.flatMap(\.children))
            roots = nodes.indices.filter { !children.contains($0) }
        }
        guard roots.allSatisfy(nodes.indices.contains)
        else { throw ReadError(detail: "the scene names an unknown node") }

        return GLTFAsset(
            nodes: nodes,
            cameras: cameras, lights: lights,
            meshes: meshes,
            skins: skins,
            materials: materials,
            images: images,
            animations: animations,
            roots: roots
        )
    }

    private static func splitGLB(_ file: Data) throws -> (json: Data, binary: Data?) {
        func word(_ at: Int) -> UInt32 {
            file
                .withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian
                }
        }
        guard word(4) == 2 else { throw ReadError(detail: "GLB version \(word(4)) is not 2") }
        let total = min(Int(word(8)), file.count)
        var offset = 12
        var json: Data?
        var binary: Data?
        while offset + 8 <= total {
            let length = Int(word(offset)), type = word(offset + 4)
            let start = offset + 8
            guard start + length <= total
            else { throw ReadError(detail: "a GLB chunk runs past the file") }
            let chunk = file
                .subdata(in: file.startIndex + start ..< file.startIndex + start + length)
            if type == 0x4E4F_534A, json == nil { json = chunk }
            if type == 0x004E_4942, binary == nil { binary = chunk }
            offset = start + (length + 3) / 4 * 4
        }
        guard let json else { throw ReadError(detail: "the GLB has no JSON chunk") }
        return (json, binary)
    }

    private static func load(uri: String, folder: URL) throws -> Data {
        if uri.hasPrefix("data:") {
            guard let comma = uri.firstIndex(of: ","), uri[..<comma].hasSuffix(";base64"),
                  let data = Data(base64Encoded: String(uri[uri.index(after: comma)...]))
            else { throw ReadError(detail: "an embedded buffer is not base64") }
            return data
        }
        guard let relative = uri.removingPercentEncoding, !relative.contains("://") else {
            throw ReadError(detail: "\(uri) is not a file next to the model")
        }
        let url = folder.appendingPathComponent(relative).standardizedFileURL
        // A file may only name files in its own folder or below.
        guard url.path.hasPrefix(folder.standardizedFileURL.path + "/") else {
            throw ReadError(detail: "\(uri) is outside the model's folder")
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ReadError(detail: "\(relative) could not be read (\(error.localizedDescription))")
        }
    }

    private static func componentCount(_ type: String) throws -> Int {
        switch type {
        case "SCALAR": 1
        case "VEC2": 2
        case "VEC3": 3
        case "VEC4", "MAT2": 4
        case "MAT3": 9
        case "MAT4": 16
        default: throw ReadError(detail: "unknown accessor type \(type)")
        }
    }

    private static func componentSize(_ type: Int) throws -> Int {
        switch type {
        case 5120, 5121: 1
        case 5122, 5123: 2
        case 5125, 5126: 4
        default: throw ReadError(detail: "unknown component type \(type)")
        }
    }

    static func decompose(_ m: simd_float4x4) -> (SIMD3<Float>, simd_quatf, SIMD3<Float>) {
        let x = SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let y = SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let z = SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        var scale = SIMD3(simd_length(x), simd_length(y), simd_length(z))
        if simd_dot(simd_cross(x, y), z) < 0 { scale.x = -scale.x }
        let safe = SIMD3(
            scale.x == 0 ? 1 : scale.x,
            scale.y == 0 ? 1 : scale.y,
            scale.z == 0 ? 1 : scale.z
        )
        let rotation = simd_quatf(simd_float3x3(columns: (x / safe.x, y / safe.y, z / safe.z)))
        return (SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z), simd_normalize(rotation), scale)
    }
}

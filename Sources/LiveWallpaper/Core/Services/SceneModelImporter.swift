import Foundation
import simd

/// Turns a glTF file into a model layer: its meshes as the layer's shapes (one per
/// material), its images as files for the scene folder and, when anything moves, its
/// node tree as a rig whose clips are the file's animations.
enum SceneModelImporter {
    struct Result {
        var layer: SceneLayer
        var rig: (id: UUID, skeleton: SceneSkeleton)?
        /// File names in the scene folder and their contents.
        var files: [(name: String, data: Data)]
    }

    struct ImportError: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    static let maximumVertices = 2_000_000
    /// Clips are sampled at this rate.
    static let framesPerSecond = 30.0
    /// Every frame of a clip is stored, so its length bounds the scene file.
    static let maximumClipSeconds: Float = 600

    private struct Vertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
        var tangent: SIMD4<Float>
        var uv: SIMD2<Float>
        var color: SIMD4<Float>
        var joints: SIMD4<UInt32>
        var weights: SIMD4<Float>
    }

    private struct Group {
        var vertices: [Vertex] = []
        var indices: [UInt32] = []
        var hasTangents = false
        var hasUVs = false
        var hasColors = false
    }

    static func importModel(at url: URL, canvasWidth: Int, canvasHeight: Int) throws -> Result {
        let asset = try GLTFAsset.read(url: url)

        var order: [Int] = []
        var parents: [Int: Int] = [:]
        var visited = Set<Int>()
        func visit(_ node: Int, parent: Int?) throws {
            guard visited.insert(node).inserted else { throw ImportError(detail: "glTF: node \(node) appears twice in the tree") }
            order.append(node)
            parents[node] = parent
            for child in asset.nodes[node].children { try visit(child, parent: node) }
        }
        for root in asset.roots { try visit(root, parent: nil) }
        var global: [Int: simd_float4x4] = [:]
        for node in order {
            global[node] = parents[node].map { global[$0]! * asset.nodes[node].local } ?? asset.nodes[node].local
        }

        let meshNodes = order.filter { asset.nodes[$0].mesh != nil }
        guard !meshNodes.isEmpty else { throw ImportError(detail: "glTF: the file has no meshes to show") }
        let animated = asset.animations.contains { $0.channels.contains { visited.contains($0.node) } }
        let skinned = meshNodes.contains { asset.nodes[$0].skin != nil }
        let rigged = animated || skinned

        var boneIndex: [Int: Int] = [:]
        var inverseBind: [simd_float4x4] = []
        if rigged {
            for (index, node) in order.enumerated() { boneIndex[node] = index }
            inverseBind = Array(repeating: matrix_identity_float4x4, count: order.count)
            var bound = Set<Int>()
            for skin in asset.skins {
                for (joint, node) in skin.joints.enumerated() {
                    guard let bone = boneIndex[node] else { continue }
                    let matrix = skin.inverseBind[joint]
                    if bound.contains(bone) {
                        let difference = (0 ..< 4).map { simd_length(inverseBind[bone][$0] - matrix[$0]) }.max()!
                        guard difference < 1e-3 else {
                            throw ImportError(detail: "glTF: two skins bind the joint \(asset.nodes[node].name) differently")
                        }
                    }
                    inverseBind[bone] = matrix
                    bound.insert(bone)
                }
            }
        }

        var groups: [Int?: Group] = [:]
        var vertexTotal = 0
        for node in meshNodes {
            let info = asset.nodes[node]
            let skin = info.skin.map { asset.skins[$0] }
            let transform: simd_float4x4
            var rigidBone: Int?
            if rigged {
                if skin == nil {
                    // Moved by its own node as a bone of weight 1; the bone's matrix is its
                    // world times its inverse bind, so the vertices take the bind back out.
                    let bone = boneIndex[node]!
                    rigidBone = bone
                    transform = simd_inverse(inverseBind[bone])
                } else {
                    transform = matrix_identity_float4x4
                }
            } else {
                transform = global[node]!
            }
            let normalMatrix = simd_transpose(simd_inverse(simd_float3x3(
                SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            )))
            let mirrored = simd_determinant(transform) < 0
            for primitive in asset.meshes[info.mesh!] {
                let material = primitive.material.map { asset.materials[$0] }
                var vertices: [Vertex] = []
                vertices.reserveCapacity(primitive.positions.count)
                for i in primitive.positions.indices {
                    var joints = SIMD4<UInt32>(repeating: 0)
                    var weights = SIMD4<Float>(1, 0, 0, 0)
                    if let rigidBone {
                        joints = SIMD4(UInt32(rigidBone), 0, 0, 0)
                    } else if let skin, let primitiveJoints = primitive.joints, let primitiveWeights = primitive.weights {
                        let local = primitiveJoints[i]
                        for slot in 0 ..< 4 {
                            guard Int(local[slot]) < skin.joints.count, let bone = boneIndex[skin.joints[Int(local[slot])]] else {
                                throw ImportError(detail: "glTF: a vertex names a joint outside its skin")
                            }
                            joints[slot] = UInt32(bone)
                        }
                        weights = primitiveWeights[i]
                        let sum = weights.sum()
                        weights = sum > 0 ? weights / sum : SIMD4(1, 0, 0, 0)
                    }
                    let p = transform * SIMD4(primitive.positions[i], 1)
                    let n = primitive.normals.map { normalMatrix * $0[i] } ?? .zero
                    let t = primitive.tangents.map { tangent -> SIMD4<Float> in
                        let turned = transform * SIMD4(tangent[i].x, tangent[i].y, tangent[i].z, 0)
                        return SIMD4(turned.x, turned.y, turned.z, tangent[i].w)
                    } ?? SIMD4(1, 0, 0, 1)
                    vertices.append(Vertex(
                        position: SIMD3(p.x, p.y, p.z), normal: simd_length(n) > 0 ? simd_normalize(n) : n, tangent: t,
                        uv: primitive.uvs?[i] ?? .zero, color: primitive.colors?[i] ?? SIMD4(repeating: 1),
                        joints: joints, weights: weights
                    ))
                }
                var indices = primitive.indices
                if mirrored {
                    for start in stride(from: 0, to: indices.count, by: 3) { indices.swapAt(start + 1, start + 2) }
                }
                if primitive.normals == nil {
                    // glTF asks for flat normals when a mesh has none: every triangle gets its own corners.
                    let corners = indices.map { vertices[Int($0)] }
                    vertices = corners
                    indices = (0 ..< UInt32(corners.count)).map { $0 }
                    for start in stride(from: 0, to: vertices.count, by: 3) {
                        let a = vertices[start].position, b = vertices[start + 1].position, c = vertices[start + 2].position
                        let cross = simd_cross(b - a, c - a)
                        let normal = simd_length(cross) > 0 ? simd_normalize(cross) : SIMD3(0, 0, 1)
                        for corner in start ..< start + 3 { vertices[corner].normal = normal }
                    }
                }
                let wantsTangents = material?.normalTexture != nil && primitive.uvs != nil
                if wantsTangents, primitive.tangents == nil {
                    generateTangents(&vertices, indices: indices)
                }
                vertexTotal += vertices.count
                guard vertexTotal <= maximumVertices else {
                    throw ImportError(detail: "glTF: the model has more than \(maximumVertices) vertices")
                }
                var group = groups[primitive.material] ?? Group()
                let offset = UInt32(group.vertices.count)
                group.vertices += vertices
                group.indices += indices.map { $0 + offset }
                group.hasTangents = group.hasTangents || wantsTangents
                group.hasUVs = group.hasUVs || primitive.uvs != nil
                group.hasColors = group.hasColors || primitive.colors != nil
                groups[primitive.material] = group
            }
        }

        var files: [(name: String, data: Data)] = []
        var imageFiles: [Int: String] = [:]
        func file(_ texture: GLTFAsset.TextureRef?) -> String? {
            guard let texture else { return nil }
            if let name = imageFiles[texture.image] { return name }
            let image = asset.images[texture.image]
            let name = "model-\(UUID().uuidString).\(image.fileExtension)"
            files.append((name, image.data))
            imageFiles[texture.image] = name
            return name
        }

        let rigID = rigged ? UUID() : nil
        var parts: [(blend: Bool, model: SceneStaticModel)] = []
        for key in groups.keys.sorted(by: { ($0 ?? -1) < ($1 ?? -1) }) {
            let group = groups[key]!
            guard !group.indices.isEmpty else { continue }
            var surface = SceneModelSurface()
            if let material = key.map({ asset.materials[$0] }) {
                surface.baseColor = [material.baseColor.x, material.baseColor.y, material.baseColor.z, material.baseColor.w].map(Double.init)
                surface.metallic = Double(material.metallic)
                surface.roughness = Double(material.roughness)
                surface.emissive = [material.emissive.x, material.emissive.y, material.emissive.z].map(Double.init)
                surface.alphaMode = switch material.alphaMode {
                case "MASK": .mask
                case "BLEND": .blend
                default: .opaque
                }
                surface.alphaCutoff = Double(material.alphaCutoff)
                surface.doubleSided = material.doubleSided
                surface.unlit = material.unlit
                if group.hasUVs {
                    surface.baseColorImage = file(material.baseColorTexture)
                    surface.metallicRoughnessImage = file(material.metallicRoughnessTexture)
                    surface.normalImage = group.hasTangents ? file(material.normalTexture) : nil
                    surface.occlusionImage = file(material.occlusionTexture)
                    surface.emissiveImage = file(material.emissiveTexture)
                }
                surface.normalScale = Double(material.normalTexture?.scale ?? 1)
                surface.occlusionStrength = Double(material.occlusionTexture?.scale ?? 1)
                surface.repeats = (material.baseColorTexture ?? material.normalTexture ?? material.metallicRoughnessTexture)?.repeats ?? true
            }
            let model = pack(group, rigged: rigged, skeleton: rigID, surface: surface)
            parts.append((surface.alphaMode == .blend, model))
        }
        // Opaque parts first, so that see-through ones are drawn over them.
        let ordered = parts.filter { !$0.blend }.map(\.model) + parts.filter(\.blend).map(\.model)
        guard let first = ordered.first else { throw ImportError(detail: "glTF: the file has no triangles to show") }

        var rig: (UUID, SceneSkeleton)?
        var restMatrices: [simd_float4x4]?
        if let rigID {
            let skeleton = try skeleton(asset, order: order, parents: parents, boneIndex: boneIndex, inverseBind: inverseBind)
            rig = (rigID, skeleton)
            restMatrices = order.indices.map { global[order[$0]]! * inverseBind[$0] }
        }

        var low = SIMD3<Float>(repeating: .infinity), high = SIMD3<Float>(repeating: -.infinity)
        for group in groups.values {
            for vertex in group.vertices {
                var p = SIMD4(vertex.position, 1)
                if let restMatrices {
                    var skinned = SIMD4<Float>(repeating: 0)
                    for slot in 0 ..< 4 where vertex.weights[slot] > 0 {
                        skinned += restMatrices[Int(vertex.joints[slot])] * p * vertex.weights[slot]
                    }
                    p = skinned
                }
                low = simd_min(low, SIMD3(p.x, p.y, p.z))
                high = simd_max(high, SIMD3(p.x, p.y, p.z))
            }
        }
        let extent = simd_max(high - low, SIMD3(repeating: 1e-6))
        let width = Double(canvasWidth), height = Double(canvasHeight)
        let unit = min(0.6 * height / Double(extent.y), 0.6 * width / Double(extent.x))
        let center = (low + high) / 2
        let placement = SceneModelPlacement(
            center: [center.x, center.y, center.z].map(Double.init), unitScale: unit,
            size: [Double(extent.x) * unit, Double(extent.y) * unit]
        )

        var layer = SceneLayer(name: url.deletingPathExtension().lastPathComponent, imageFile: "")
        layer.kind = .model
        layer.model = first
        layer.modelParts = ordered.count > 1 ? Array(ordered.dropFirst()) : nil
        layer.modelPlacement = placement
        return Result(layer: layer, rig: rig, files: files)
    }

    private static func pack(_ group: Group, rigged: Bool, skeleton: UUID?, surface: SceneModelSurface) -> SceneStaticModel {
        let semantics = SceneRenderGraph.Attribute.Semantic.allCases
        var included: Set<SceneRenderGraph.Attribute.Semantic> = [.position, .normal]
        if group.hasTangents { included.insert(.tangentSigned) }
        if group.hasUVs { included.insert(.uv) }
        if group.hasColors { included.insert(.color) }
        if rigged { included.formUnion([.joints, .weights]) }
        let components = semantics.enumerated().reduce(UInt32(0)) { bits, entry in
            included.contains(entry.element) ? bits | (1 << UInt32(entry.offset)) : bits
        }
        var floats: [Float] = []
        floats.reserveCapacity(group.vertices.count * 23)
        for vertex in group.vertices {
            for semantic in semantics where included.contains(semantic) {
                switch semantic {
                case .position: floats += [vertex.position.x, vertex.position.y, vertex.position.z]
                case .normal: floats += [vertex.normal.x, vertex.normal.y, vertex.normal.z]
                case .tangentSigned: floats += [vertex.tangent.x, vertex.tangent.y, vertex.tangent.z, vertex.tangent.w]
                case .uv: floats += [vertex.uv.x, vertex.uv.y]
                case .color: floats += [vertex.color.x, vertex.color.y, vertex.color.z, vertex.color.w]
                case .joints: floats += (0 ..< 4).map { Float(bitPattern: vertex.joints[$0]) }
                case .weights: floats += [vertex.weights.x, vertex.weights.y, vertex.weights.z, vertex.weights.w]
                }
            }
        }
        var vertices = Data(capacity: floats.count * 4)
        for value in floats { withUnsafeBytes(of: value.bitPattern.littleEndian) { vertices.append(contentsOf: $0) } }
        var indices = Data(capacity: group.indices.count * 4)
        for index in group.indices { withUnsafeBytes(of: index.littleEndian) { indices.append(contentsOf: $0) } }
        return SceneStaticModel(material: -1, components: components, vertices: vertices, indices: indices,
                                skeleton: skeleton, surface: surface)
    }

    /// Per-vertex tangents from each triangle's texture direction, w the handedness.
    private static func generateTangents(_ vertices: inout [Vertex], indices: [UInt32]) {
        var tangents = Array(repeating: SIMD3<Float>(repeating: 0), count: vertices.count)
        var bitangents = tangents
        for start in stride(from: 0, to: indices.count, by: 3) {
            let i = (Int(indices[start]), Int(indices[start + 1]), Int(indices[start + 2]))
            let (a, b, c) = (vertices[i.0], vertices[i.1], vertices[i.2])
            let e1 = b.position - a.position, e2 = c.position - a.position
            let d1 = b.uv - a.uv, d2 = c.uv - a.uv
            let det = d1.x * d2.y - d2.x * d1.y
            guard abs(det) > 1e-12 else { continue }
            let r = 1 / det
            let t = (e1 * d2.y - e2 * d1.y) * r
            let bt = (e2 * d1.x - e1 * d2.x) * r
            for index in [i.0, i.1, i.2] {
                tangents[index] += t
                bitangents[index] += bt
            }
        }
        for index in vertices.indices {
            let n = vertices[index].normal
            var t = tangents[index] - n * simd_dot(n, tangents[index])
            if simd_length(t) < 1e-8 {
                t = abs(n.x) < 0.9 ? simd_cross(n, SIMD3(1, 0, 0)) : simd_cross(n, SIMD3(0, 1, 0))
            }
            t = simd_normalize(t)
            // glTF's bitangent is cross(normal, tangent) × w, with v running down the image.
            let w: Float = simd_dot(simd_cross(n, t), bitangents[index]) < 0 ? -1 : 1
            vertices[index].tangent = SIMD4(t, w)
        }
    }

    private static func skeleton(
        _ asset: GLTFAsset, order: [Int], parents: [Int: Int], boneIndex: [Int: Int], inverseBind: [simd_float4x4]
    ) throws -> SceneSkeleton {
        func transform(_ t: SIMD3<Float>, _ r: simd_quatf, _ s: SIMD3<Float>) -> SceneSkeleton.Transform {
            let q = simd_normalize(r)
            // A zero scale cannot be undone, which the rig needs at rest.
            let scale = s.indices.map { abs(s[$0]) < 1e-6 ? (s[$0] < 0 ? -1e-6 : 1e-6) : s[$0] }
            return .init(translation: [t.x, t.y, t.z], rotation: [q.imag.x, q.imag.y, q.imag.z, q.real], scale: scale)
        }
        let bones = order.enumerated().map { index, node -> SceneSkeleton.Bone in
            let info = asset.nodes[node]
            let m = inverseBind[index]
            return SceneSkeleton.Bone(
                name: info.name, parent: parents[node].flatMap { boneIndex[$0] },
                rest: transform(info.translation, info.rotation, info.scale),
                inverseBind: [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
            )
        }
        var clips: [SceneSkeleton.Clip] = []
        for animation in asset.animations {
            let channels = animation.channels.filter { boneIndex[$0.node] != nil }
            guard !channels.isEmpty else { continue }
            let duration = channels.map { $0.times.last! }.max()!
            guard duration <= maximumClipSeconds else {
                throw ImportError(detail: "glTF: the animation \(animation.name) is longer than \(Int(maximumClipSeconds)) seconds")
            }
            let frameCount = max(1, Int((Double(duration) * framesPerSecond).rounded(.up)))
            var byNode: [Int: [GLTFAsset.Channel.Path: GLTFAsset.Channel]] = [:]
            for channel in channels { byNode[channel.node, default: [:]][channel.path] = channel }
            let tracks = byNode.keys.sorted().map { node -> SceneSkeleton.Track in
                let info = asset.nodes[node]
                let paths = byNode[node]!
                let samples = (0 ... frameCount).map { frame -> SceneSkeleton.Transform in
                    let time = Float(min(Double(frame) / framesPerSecond, Double(duration)))
                    let t = paths[.translation].map { SIMD3(sample($0, at: time, width: 3)) } ?? info.translation
                    let r = paths[.rotation].map { channel -> simd_quatf in
                        let v = sample(channel, at: time, width: 4)
                        return simd_quatf(ix: v[0], iy: v[1], iz: v[2], r: v[3])
                    } ?? info.rotation
                    let s = paths[.scale].map { SIMD3(sample($0, at: time, width: 3)) } ?? info.scale
                    return transform(t, r, s)
                }
                return SceneSkeleton.Track(bone: boneIndex[node]!, transforms: samples)
            }
            clips.append(SceneSkeleton.Clip(name: animation.name, framesPerSecond: framesPerSecond, frameCount: frameCount, tracks: tracks))
        }
        let skeleton = SceneSkeleton(
            bones: bones, clips: clips, playback: clips.isEmpty ? [] : [SceneSkeleton.Playback(clip: 0)]
        )
        do {
            _ = try SceneSkeletonEvaluator(skeleton)
        } catch {
            throw ImportError(detail: "glTF: the rig could not be built (\(error.localizedDescription))")
        }
        return skeleton
    }

    private static func sample(_ channel: GLTFAsset.Channel, at time: Float, width: Int) -> [Float] {
        let times = channel.times
        let cubic = channel.interpolation == "CUBICSPLINE"
        let stride = cubic ? width * 3 : width
        func value(_ key: Int, _ part: Int = 1) -> [Float] {
            let start = key * stride + (cubic ? part * width : 0)
            return Array(channel.values[start ..< start + width])
        }
        if time <= times[0] { return value(0) }
        if time >= times[times.count - 1] { return value(times.count - 1) }
        var low = 0, high = times.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if times[middle] <= time { low = middle } else { high = middle }
        }
        let span = times[high] - times[low]
        let u = span > 0 ? (time - times[low]) / span : 0
        switch channel.interpolation {
        case "STEP":
            return value(low)
        case "CUBICSPLINE":
            let p0 = value(low), m0 = value(low, 2).map { $0 * span }
            let p1 = value(high), m1 = value(high, 0).map { $0 * span }
            let u2 = u * u, u3 = u2 * u
            let result = (0 ..< width).map {
                (2 * u3 - 3 * u2 + 1) * p0[$0] + (u3 - 2 * u2 + u) * m0[$0] + (-2 * u3 + 3 * u2) * p1[$0] + (u3 - u2) * m1[$0]
            }
            return width == 4 ? normalized(result) : result
        default:
            let a = value(low), b = value(high)
            if width == 4 {
                let q = simd_slerp(simd_quatf(ix: a[0], iy: a[1], iz: a[2], r: a[3]), simd_quatf(ix: b[0], iy: b[1], iz: b[2], r: b[3]), u)
                return [q.imag.x, q.imag.y, q.imag.z, q.real]
            }
            return (0 ..< width).map { a[$0] + (b[$0] - a[$0]) * u }
        }
    }

    private static func normalized(_ q: [Float]) -> [Float] {
        let length = (q.map { $0 * $0 }.reduce(0, +)).squareRoot()
        return length > 0 ? q.map { $0 / length } : [0, 0, 0, 1]
    }
}

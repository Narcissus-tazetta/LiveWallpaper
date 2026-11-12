import Foundation
import Metal
import simd

/// Draws the shadow maps of a scene's lights: what each texel holds is how far the nearest
/// solid model stands from the light (along its axis for a directional light), and what a
/// material's lighting does with it is written by the converter, which knows the layout.
extension SceneModelRenderer {
    /// Texels on a side of one shadow map, or of one face of a point light's atlas. The
    /// converter writes the same number into the materials.
    static let shadowSize = 1024
    private static let shadowDepthFar: Float = 50000
    /// A directional map spans at least this share of the light's shadow reach, which sets
    /// how soft its edges are (fitted to LT-104...110 and LT-120/125, not derived).
    private static let cascadeScale: Float = 0.75

    private static let shadowSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct ShadowUniforms { float4x4 transform; float4x4 model; float4 light; float4 axis; };
    struct ShadowIn { float3 position [[attribute(0)]]; };
    struct ShadowOut { float4 position [[position]]; float3 world; };
    vertex ShadowOut shadowVertex(ShadowIn in [[stage_in]], constant ShadowUniforms& u [[buffer(0)]]) {
        ShadowOut out;
        float4 world = u.model * float4(in.position, 1);
        out.world = world.xyz;
        out.position = u.transform * world;
        return out;
    }
    struct SkinnedIn { float3 position [[attribute(0)]]; uint4 joints [[attribute(1)]]; float4 weights [[attribute(2)]]; };
    vertex ShadowOut skinnedShadowVertex(SkinnedIn in [[stage_in]], constant ShadowUniforms& u [[buffer(0)]],
                                         constant float4x4* bones [[buffer(3)]]) {
        float4x4 skin = bones[in.joints.x] * in.weights.x + bones[in.joints.y] * in.weights.y
            + bones[in.joints.z] * in.weights.z + bones[in.joints.w] * in.weights.w;
        ShadowOut out;
        float4 world = u.model * (skin * float4(in.position, 1));
        out.world = world.xyz;
        out.position = u.transform * world;
        return out;
    }
    fragment float4 shadowFragment(ShadowOut in [[stage_in]], constant ShadowUniforms& u [[buffer(0)]]) {
        // axis.w is 1 for a directional light: the distance is then along the axis.
        float d = u.axis.w > 0.5 ? dot(in.world, u.axis.xyz) : length(in.world - u.light.xyz);
        return float4(d, 0, 0, 0);
    }
    """

    /// What `shadowTexture` holds before anything is drawn into it: farther than any caster.
    private static let shadowFarthest: Float = 1e30

    /// A map in which nothing casts a shadow.
    func openShadow() throws -> MTLTexture {
        if let texture = shadowState.open { return texture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor)
        else { throw ModelError(detail: "shadow texture allocation failed") }
        var far = Self.shadowFarthest
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &far,
            bytesPerRow: 4
        )
        shadowState.open = texture
        return texture
    }

    /// `skin` is the byte offsets of the joints and weights for a caster a rig poses.
    private func shadowPipeline(
        stride: Int,
        skin: (joints: Int, weights: Int)? = nil
    ) throws -> MTLRenderPipelineState {
        let key = ShadowPipelineKey(stride: stride, joints: skin?.joints, weights: skin?.weights)
        if let pipeline = shadowState.pipelines[key] { return pipeline }
        if shadowState.functions == nil {
            let library = try device.makeLibrary(source: Self.shadowSource, options: nil)
            shadowState.functions = (
                library.makeFunction(name: "shadowVertex")!,
                library.makeFunction(name: "shadowFragment")!,
                library.makeFunction(name: "skinnedShadowVertex")!
            )
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = skin == nil ? shadowState.functions!.0 : shadowState.functions!
            .2
        descriptor.fragmentFunction = shadowState.functions!.1
        let vertices = MTLVertexDescriptor()
        vertices.attributes[0].format = .float3
        vertices.attributes[0].offset = 0
        vertices.attributes[0].bufferIndex = 1
        if let skin {
            vertices.attributes[1].format = .uint4
            vertices.attributes[1].offset = skin.joints
            vertices.attributes[1].bufferIndex = 1
            vertices.attributes[2].format = .float4
            vertices.attributes[2].offset = skin.weights
            vertices.attributes[2].bufferIndex = 1
        }
        vertices.layouts[1].stride = stride
        descriptor.vertexDescriptor = vertices
        descriptor.colorAttachments[0].pixelFormat = .r32Float
        descriptor.depthAttachmentPixelFormat = Self.depthFormat
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        shadowState.pipelines[key] = pipeline
        return pipeline
    }

    /// Byte offsets of the joints and weights in a shape's vertices; nil without both.
    private static func skinOffsets(_ shape: SceneModelLayerFrame
        .Shape) -> (joints: Int, weights: Int)?
    {
        var offset = 0
        var joints: Int?, weights: Int?
        for (bit, semantic) in SceneRenderGraph.Attribute.Semantic.allCases.enumerated()
            where shape.components & (1 << UInt32(bit)) != 0
        {
            if semantic == .joints { joints = offset }
            if semantic == .weights { weights = offset }
            offset += semantic.floats * 4
        }
        guard let joints, let weights else { return nil }
        return (joints, weights)
    }

    /// The box around every caster's vertices in scene pixels, posed by their rigs.
    /// Converted models run to millions of vertices, so each caster's box is kept while
    /// it does not move. Splitting the rest over cores kept the frame rate but cost about
    /// half again as much CPU in all (measured), so it runs on this thread.
    private func casterBounds(
        _ casters: [SceneModelLayerFrame], poses: [Int: [simd_float4x4]]
    ) -> (low: SIMD3<Float>, high: SIMD3<Float>) {
        let previous = shadowState.bounds
        var kept: [ShadowBounds] = []
        var low = SIMD3<Float>(repeating: .infinity), high = SIMD3<Float>(repeating: -.infinity)
        for index in casters.indices {
            let key = ShadowBoundsKey(
                world: casters[index].world, pose: poses[index],
                shapes: casters[index].shapes
                    .filter { !$0.vertices.isEmpty && $0.components & 1 != 0 }
            )
            var box = previous.first { $0.key.isSame(as: key) }
            if box == nil {
                var casterLow = SIMD3<Float>(repeating: .infinity),
                    casterHigh = SIMD3<Float>(repeating: -.infinity)
                for shape in key.shapes {
                    let (shapeLow, shapeHigh) = Self.bounds(
                        of: shape,
                        pose: key.pose,
                        world: key.world
                    )
                    casterLow = simd_min(casterLow, shapeLow)
                    casterHigh = simd_max(casterHigh, shapeHigh)
                }
                box = ShadowBounds(key: key, low: casterLow, high: casterHigh)
            }
            kept.append(box!)
            low = simd_min(low, box!.low)
            high = simd_max(high, box!.high)
        }
        shadowState.bounds = kept
        return (low, high)
    }

    private static func bounds(
        of shape: SceneModelLayerFrame.Shape, pose: [simd_float4x4]?, world: simd_float4x4
    ) -> (SIMD3<Float>, SIMD3<Float>) {
        let stride = shape.stride
        let skin = pose == nil ? nil : skinOffsets(shape)
        let count = shape.vertices
            .count >= stride ? (shape.vertices.count - stride) / stride + 1 : 0
        var low = SIMD3<Float>(repeating: .infinity), high = SIMD3<Float>(repeating: -.infinity)
        shape.vertices.withUnsafeBufferPointer { vertices in
            for vertex in 0 ..< count {
                let start = vertex * stride
                let p = SIMD4(vertices[start], vertices[start + 1], vertices[start + 2], 1)
                var position = p
                if let pose, let skin {
                    position = SIMD4<Float>(repeating: 0)
                    for slot in 0 ..< 4 {
                        let weight = vertices[start + skin.weights / 4 + slot]
                        let joint = Int(vertices[start + skin.joints / 4 + slot].bitPattern)
                        if weight > 0,
                           pose.indices.contains(joint) { position += pose[joint] * p * weight }
                    }
                }
                let placed = world * position
                low = simd_min(low, SIMD3(placed.x, placed.y, placed.z))
                high = simd_max(high, SIMD3(placed.x, placed.y, placed.z))
            }
        }
        return (low, high)
    }

    private func shadowTarget(
        width: Int,
        height: Int,
        slot: Int
    ) throws -> (color: MTLTexture, depth: MTLTexture) {
        if let existing = shadowState.targets[slot], existing.color.width == width,
           existing.color.height == height
        {
            return existing
        }
        let color = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        color.usage = [.renderTarget, .shaderRead]
        color.storageMode = .private
        let depth = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.depthFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        depth.usage = .renderTarget
        depth.storageMode = .private
        guard let colorTexture = device.makeTexture(descriptor: color),
              let depthTexture = device.makeTexture(descriptor: depth)
        else {
            throw ModelError(detail: "shadow texture allocation failed")
        }
        shadowState.targets[slot] = (colorTexture, depthTexture)
        return (colorTexture, depthTexture)
    }

    /// A camera at `eye` looking along `forward` with a square 90° view widened to
    /// `fov` degrees, taking scene pixels to clip space.
    private static func shadowPerspective(
        eye: SIMD3<Float>,
        forward: SIMD3<Float>,
        fov: Float
    ) -> simd_float4x4 {
        let up: SIMD3<Float> = abs(forward.y) > 0.99 ? SIMD3(0, 0, 1) : SIMD3(0, 1, 0)
        return shadowPerspective(eye: eye, forward: forward, up: up, fov: fov)
    }

    private static func shadowPerspective(
        eye: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>, fov: Float
    ) -> simd_float4x4 {
        let near: Float = 1, far = shadowDepthFar
        let f = 1 / tan(fov * .pi / 360)
        let projection = simd_float4x4(columns: (
            SIMD4(f, 0, 0, 0), SIMD4(0, f, 0, 0), SIMD4(0, 0, far / (near - far), -1), SIMD4(
                0,
                0,
                near * far / (near - far),
                0
            )
        ))
        let right = simd_normalize(simd_cross(forward, up))
        let y = simd_cross(right, forward)
        let z = -forward
        let view = simd_float4x4(columns: (
            SIMD4(right.x, y.x, z.x, 0), SIMD4(right.y, y.y, z.y, 0), SIMD4(right.z, y.z, z.z, 0),
            SIMD4(-simd_dot(right, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)
        ))
        return projection * view
    }

    /// One face of a point light's atlas: clip x and y are the point's offset along `right`
    /// and `up` over its depth along `forward`, which is how the converter's lookup reads
    /// them (these axes need not form a right-handed frame, and nothing is culled).
    private static func atlasFace(
        eye: SIMD3<Float>, forward: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>
    ) -> simd_float4x4 {
        let near: Float = 1, far = shadowDepthFar
        let a = far / (far - near), b = -near * far / (far - near)
        return simd_float4x4(columns: (
            SIMD4(right.x, up.x, a * forward.x, forward.x), SIMD4(
                right.y,
                up.y,
                a * forward.y,
                forward.y
            ),
            SIMD4(right.z, up.z, a * forward.z, forward.z),
            SIMD4(
                -simd_dot(right, eye),
                -simd_dot(up, eye),
                a * -simd_dot(forward, eye) + b,
                -simd_dot(forward, eye)
            )
        ))
    }

    /// Faces of a point light's atlas: forward, right and up of each, as the converter's
    /// lookup reads them.
    private static let atlasFaces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
        (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0)), (
            SIMD3(-1, 0, 0),
            SIMD3(0, 0, 1),
            SIMD3(0, 1, 0)
        ),
        (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1)), (
            SIMD3(0, -1, 0),
            SIMD3(1, 0, 0),
            SIMD3(0, 0, 1)
        ),
        (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)), (
            SIMD3(0, 0, -1),
            SIMD3(-1, 0, 0),
            SIMD3(0, 1, 0)
        )
    ]

    /// Draws one shadow map per light of `lights` from the solid models in `casters`.
    /// A caster with a rig is posed by it at `time` when `rigs` holds it.
    func renderShadows(
        lights: [SceneShadowLight], casters: [SceneModelLayerFrame],
        commandBuffer: MTLCommandBuffer,
        rigs: SceneSkeletonRegistry? = nil, time: Double = 0
    ) throws -> Shadows {
        let casters = casters.filter(\.castsShadow)
        let poses: [Int: [simd_float4x4]] = try Dictionary(uniqueKeysWithValues: casters.indices
            .compactMap { index in
                guard let rig = casters[index].rig, let rigs,
                      rigs.skeletons[rig] != nil else { return nil }
                return try (index, rigs.evaluator(rig).evaluate(time: time).matrices)
            })
        shadowState.targets = shadowState.targets.filter { $0.key < lights.count }
        let size = Self.shadowSize
        var bounds: (center: SIMD3<Float>, radius: Float)?
        if lights.contains(where: { $0.kind == .directional }) {
            let (low, high) = casterBounds(casters, poses: poses)
            if low.x <= high.x {
                bounds = ((low + high) / 2, max(simd_length(high - low) / 2 * 1.02, 1))
            }
        }
        var textures: [MTLTexture] = []
        var matrices: [simd_float4x4] = []
        for (slot, light) in lights.enumerated() {
            let origin = SIMD3(light.origin.map(Float.init))
            let axis = simd_normalize(SIMD3(light.axis.map(Float.init)))
            let atlas = light.kind == .point
            let target = try shadowTarget(
                width: atlas ? size * 3 : size,
                height: atlas ? size * 2 : size,
                slot: slot
            )
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target.color
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(
                red: Double(Self.shadowFarthest),
                green: 0,
                blue: 0,
                alpha: 0
            )
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = target.depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 1
            pass.depthAttachment.storeAction = .dontCare
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw ModelError(detail: "shadow pass allocation failed")
            }
            defer { encoder.endEncoding() }
            let depthDescriptor = MTLDepthStencilDescriptor()
            depthDescriptor.depthCompareFunction = .less
            depthDescriptor.isDepthWriteEnabled = true
            let depthState = device.makeDepthStencilState(descriptor: depthDescriptor)!
            encoder.setDepthStencilState(depthState)
            encoder.setCullMode(.none)
            encoder.setFrontFacing(.counterClockwise)

            var views: [(simd_float4x4, MTLViewport?)] = []
            switch light.kind {
            case .point:
                for (face, basis) in Self.atlasFaces.enumerated() {
                    let transform = Self.atlasFace(
                        eye: origin,
                        forward: basis.0,
                        right: basis.1,
                        up: basis.2
                    )
                    let viewport = MTLViewport(
                        originX: Double(face % 3 * size), originY: Double(face / 3 * size),
                        width: Double(size), height: Double(size),
                        znear: 0, zfar: 1
                    )
                    views.append((transform, viewport))
                }
                matrices.append(matrix_identity_float4x4)
            case .spot:
                // Wide enough for the whole cone, with a margin for its soft edge.
                let transform = Self.shadowPerspective(
                    eye: origin,
                    forward: axis,
                    fov: min(Float(light.outerCone) * 2 + 4, 170)
                )
                views.append((transform, nil))
                matrices.append(transform)
            case .directional:
                let (center, fitted) = bounds ?? (.zero, 1)
                let radius = max(fitted, Float(light.cascadeDistance) * Self.cascadeScale)
                let up: SIMD3<Float> = abs(axis.y) > 0.99 ? SIMD3(0, 0, 1) : SIMD3(0, 1, 0)
                let right = simd_normalize(simd_cross(axis, up))
                let y = simd_cross(right, axis)
                let transform = simd_float4x4(columns: (
                    SIMD4(right.x / radius, y.x / radius, axis.x / (2 * radius), 0),
                    SIMD4(right.y / radius, y.y / radius, axis.y / (2 * radius), 0),
                    SIMD4(right.z / radius, y.z / radius, axis.z / (2 * radius), 0),
                    SIMD4(
                        -simd_dot(right, center) / radius,
                        -simd_dot(y, center) / radius,
                        (-simd_dot(axis, center) + radius) / (2 * radius),
                        1
                    )
                ))
                views.append((transform, nil))
                matrices.append(transform)
            }
            for (transform, viewport) in views {
                if let viewport {
                    encoder.setViewport(viewport)
                    encoder.setScissorRect(MTLScissorRect(
                        x: Int(viewport.originX),
                        y: Int(viewport.originY),
                        width: size,
                        height: size
                    ))
                }
                for (index, layer) in casters.enumerated() {
                    for shape in layer.shapes
                        where !shape.vertices.isEmpty && shape.components & 1 != 0
                    {
                        if let indices = shape.indices {
                            if indices.count < 3 { continue }
                        } else if shape.vertices.count / shape.stride < 3 {
                            continue
                        }
                        let skin = poses[index] == nil ? nil : Self.skinOffsets(shape)
                        try encoder.setRenderPipelineState(shadowPipeline(
                            stride: shape.stride * 4,
                            skin: skin
                        ))
                        if skin != nil, let pose = poses[index], !pose.isEmpty {
                            try pose.withUnsafeBytes { bytes in
                                let baseAddress = bytes.baseAddress!
                                if bytes.count <= 4096 {
                                    encoder.setVertexBytes(
                                        baseAddress,
                                        length: bytes.count,
                                        index: 3
                                    )
                                } else {
                                    guard let buffer = device.makeBuffer(
                                        bytes: baseAddress,
                                        length: bytes.count,
                                        options: .storageModeShared
                                    )
                                    else { throw ModelError(detail: "bone allocation failed") }
                                    encoder.setVertexBuffer(buffer, offset: 0, index: 3)
                                }
                            }
                        }
                        var uniforms = ShadowUniforms(
                            transform: transform, model: layer.world, light: SIMD4(origin, 0),
                            axis: SIMD4(axis, light.kind == .directional ? 1 : 0)
                        )
                        encoder.setVertexBytes(
                            &uniforms,
                            length: MemoryLayout<ShadowUniforms>.stride,
                            index: 0
                        )
                        encoder.setFragmentBytes(
                            &uniforms,
                            length: MemoryLayout<ShadowUniforms>.stride,
                            index: 0
                        )
                        let vertexBuffer: any MTLBuffer
                        if let cached = shape.vertexBuffer {
                            vertexBuffer = cached
                        } else {
                            guard !shape.vertices.isEmpty, let buffer = shape.vertices.withUnsafeBytes({ bytes -> MTLBuffer? in
                                let baseAddress = bytes.baseAddress!
                                return device.makeBuffer(
                                    bytes: baseAddress,
                                    length: bytes.count,
                                    options: .storageModeShared
                                )
                            }) else { throw ModelError(detail: "vertex allocation failed") }
                            vertexBuffer = buffer
                        }
                        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 1)
                        if let indices = shape.indices, !indices.isEmpty {
                            let indexBuffer: any MTLBuffer
                            if let cached = shape.indexBuffer {
                                indexBuffer = cached
                            } else {
                                guard let buffer = indices.withUnsafeBytes({ bytes -> MTLBuffer? in
                                    let baseAddress = bytes.baseAddress!
                                    return device.makeBuffer(
                                        bytes: baseAddress,
                                        length: bytes.count,
                                        options: .storageModeShared
                                    )
                                }) else { throw ModelError(detail: "index allocation failed") }
                                indexBuffer = buffer
                            }
                            encoder.drawIndexedPrimitives(
                                type: .triangle,
                                indexCount: indices.count,
                                indexType: .uint32,
                                indexBuffer: indexBuffer,
                                indexBufferOffset: 0
                            )
                        } else {
                            let count = shape.vertices.count / shape.stride / 3 * 3
                            if count > 0 { encoder.drawPrimitives(
                                type: .triangle,
                                vertexStart: 0,
                                vertexCount: count
                            ) }
                        }
                    }
                }
            }
            textures.append(target.color)
        }
        return Shadows(textures: textures, matrices: matrices)
    }

    private struct ShadowUniforms {
        var transform: simd_float4x4
        var model: simd_float4x4
        var light: SIMD4<Float>
        var axis: SIMD4<Float>
    }

    /// Buffers and pipelines the shadow passes keep between frames.
    struct ShadowPipelineKey: Hashable {
        var stride: Int
        var joints: Int?
        var weights: Int?
    }

    /// What a caster's box depends on. The shapes are held, so their vertex storage stays
    /// the same only while nothing has written to it.
    struct ShadowBoundsKey {
        var world: simd_float4x4
        var pose: [simd_float4x4]?
        var shapes: [SceneModelLayerFrame.Shape]

        func isSame(as other: ShadowBoundsKey) -> Bool {
            world == other.world && pose == other.pose && shapes.count == other.shapes.count
                && zip(shapes, other.shapes).allSatisfy { a, b in
                    a.components == b.components && a.vertices.count == b.vertices.count
                        && a.vertices
                        .withUnsafeBufferPointer { x in b.vertices.withUnsafeBufferPointer { y in
                            x.baseAddress == y.baseAddress
                        } }
                }
        }
    }

    struct ShadowBounds {
        var key: ShadowBoundsKey
        var low: SIMD3<Float>
        var high: SIMD3<Float>
    }

    final class ShadowState {
        var functions: (MTLFunction, MTLFunction, MTLFunction)?
        var pipelines: [ShadowPipelineKey: MTLRenderPipelineState] = [:]
        var targets: [Int: (color: MTLTexture, depth: MTLTexture)] = [:]
        var open: MTLTexture?
        var bounds: [ShadowBounds] = []
    }
}

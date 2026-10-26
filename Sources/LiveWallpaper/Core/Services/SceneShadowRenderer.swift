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
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw ModelError(detail: "shadow texture allocation failed") }
        var far = Self.shadowFarthest
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &far, bytesPerRow: 4)
        shadowState.open = texture
        return texture
    }

    private func shadowPipeline(stride: Int) throws -> MTLRenderPipelineState {
        if let pipeline = shadowState.pipelines[stride] { return pipeline }
        if shadowState.functions == nil {
            let library = try device.makeLibrary(source: Self.shadowSource, options: nil)
            shadowState.functions = (library.makeFunction(name: "shadowVertex")!, library.makeFunction(name: "shadowFragment")!)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = shadowState.functions!.0
        descriptor.fragmentFunction = shadowState.functions!.1
        let vertices = MTLVertexDescriptor()
        vertices.attributes[0].format = .float3
        vertices.attributes[0].offset = 0
        vertices.attributes[0].bufferIndex = 1
        vertices.layouts[1].stride = stride
        descriptor.vertexDescriptor = vertices
        descriptor.colorAttachments[0].pixelFormat = .r32Float
        descriptor.depthAttachmentPixelFormat = Self.depthFormat
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        shadowState.pipelines[stride] = pipeline
        return pipeline
    }

    private func shadowTarget(width: Int, height: Int, slot: Int) throws -> (color: MTLTexture, depth: MTLTexture) {
        if let existing = shadowState.targets[slot], existing.color.width == width, existing.color.height == height {
            return existing
        }
        let color = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        color.usage = [.renderTarget, .shaderRead]
        color.storageMode = .private
        let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.depthFormat, width: width, height: height, mipmapped: false)
        depth.usage = .renderTarget
        depth.storageMode = .private
        guard let colorTexture = device.makeTexture(descriptor: color), let depthTexture = device.makeTexture(descriptor: depth) else {
            throw ModelError(detail: "shadow texture allocation failed")
        }
        shadowState.targets[slot] = (colorTexture, depthTexture)
        return (colorTexture, depthTexture)
    }

    /// A camera at `eye` looking along `forward` with a square 90° view widened to
    /// `fov` degrees, taking scene pixels to clip space.
    private static func shadowPerspective(eye: SIMD3<Float>, forward: SIMD3<Float>, fov: Float) -> simd_float4x4 {
        let up: SIMD3<Float> = abs(forward.y) > 0.99 ? SIMD3(0, 0, 1) : SIMD3(0, 1, 0)
        return shadowPerspective(eye: eye, forward: forward, up: up, fov: fov)
    }

    private static func shadowPerspective(
        eye: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>, fov: Float
    ) -> simd_float4x4 {
        let near: Float = 1, far = shadowDepthFar
        let f = 1 / tan(fov * .pi / 360)
        let projection = simd_float4x4(columns: (
            SIMD4(f, 0, 0, 0), SIMD4(0, f, 0, 0), SIMD4(0, 0, far / (near - far), -1), SIMD4(0, 0, near * far / (near - far), 0)
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
            SIMD4(right.x, up.x, a * forward.x, forward.x), SIMD4(right.y, up.y, a * forward.y, forward.y),
            SIMD4(right.z, up.z, a * forward.z, forward.z),
            SIMD4(-simd_dot(right, eye), -simd_dot(up, eye), a * -simd_dot(forward, eye) + b, -simd_dot(forward, eye))
        ))
    }

    /// Faces of a point light's atlas: forward, right and up of each, as the converter's
    /// lookup reads them.
    private static let atlasFaces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
        (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0)), (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
        (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1)), (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
        (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)), (SIMD3(0, 0, -1), SIMD3(-1, 0, 0), SIMD3(0, 1, 0))
    ]

    /// Draws one shadow map per light of `lights` from the solid models in `casters`.
    func renderShadows(
        lights: [SceneShadowLight], casters: [SceneModelLayerFrame], commandBuffer: MTLCommandBuffer
    ) throws -> Shadows {
        let size = Self.shadowSize
        // Every solid model casts, as measured with models that carry no flag of their own.
        var bounds: (center: SIMD3<Float>, radius: Float)?
        if lights.contains(where: { $0.kind == .directional }) {
            var low = SIMD3<Float>(repeating: .infinity), high = SIMD3<Float>(repeating: -.infinity)
            for layer in casters {
                for shape in layer.shapes where !shape.vertices.isEmpty && shape.components & 1 != 0 {
                    let stride = shape.stride
                    for start in Swift.stride(from: 0, to: shape.vertices.count - stride + 1, by: stride) {
                        let world = layer.world * SIMD4(shape.vertices[start], shape.vertices[start + 1], shape.vertices[start + 2], 1)
                        low = simd_min(low, SIMD3(world.x, world.y, world.z))
                        high = simd_max(high, SIMD3(world.x, world.y, world.z))
                    }
                }
            }
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
            let target = try shadowTarget(width: atlas ? size * 3 : size, height: atlas ? size * 2 : size, slot: slot)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target.color
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(Self.shadowFarthest), green: 0, blue: 0, alpha: 0)
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
                    let transform = Self.atlasFace(eye: origin, forward: basis.0, right: basis.1, up: basis.2)
                    let viewport = MTLViewport(
                        originX: Double(face % 3 * size), originY: Double(face / 3 * size), width: Double(size), height: Double(size),
                        znear: 0, zfar: 1
                    )
                    views.append((transform, viewport))
                }
                matrices.append(matrix_identity_float4x4)
            case .spot:
                // Wide enough for the whole cone, with a margin for its soft edge.
                let transform = Self.shadowPerspective(eye: origin, forward: axis, fov: min(Float(light.outerCone) * 2 + 4, 170))
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
                    SIMD4(-simd_dot(right, center) / radius, -simd_dot(y, center) / radius,
                          (-simd_dot(axis, center) + radius) / (2 * radius), 1)
                ))
                views.append((transform, nil))
                matrices.append(transform)
            }
            for (transform, viewport) in views {
                if let viewport {
                    encoder.setViewport(viewport)
                    encoder.setScissorRect(MTLScissorRect(x: Int(viewport.originX), y: Int(viewport.originY), width: size, height: size))
                }
                for layer in casters {
                    for shape in layer.shapes where !shape.vertices.isEmpty && shape.components & 1 != 0 {
                        if let indices = shape.indices, indices.isEmpty { continue }
                        encoder.setRenderPipelineState(try shadowPipeline(stride: shape.stride * 4))
                        var uniforms = ShadowUniforms(
                            transform: transform, model: layer.world, light: SIMD4(origin, 0),
                            axis: SIMD4(axis, light.kind == .directional ? 1 : 0)
                        )
                        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ShadowUniforms>.stride, index: 0)
                        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShadowUniforms>.stride, index: 0)
                        guard let vertices = shape.vertices.withUnsafeBytes({
                            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
                        }) else { throw ModelError(detail: "vertex allocation failed") }
                        encoder.setVertexBuffer(vertices, offset: 0, index: 1)
                        if let indices = shape.indices {
                            guard let buffer = indices.withUnsafeBytes({
                                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
                            }) else { throw ModelError(detail: "index allocation failed") }
                            encoder.drawIndexedPrimitives(type: .triangle, indexCount: indices.count, indexType: .uint32,
                                                          indexBuffer: buffer, indexBufferOffset: 0)
                        } else {
                            let count = shape.vertices.count / shape.stride / 3 * 3
                            if count > 0 { encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count) }
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
    final class ShadowState {
        var functions: (MTLFunction, MTLFunction)?
        var pipelines: [Int: MTLRenderPipelineState] = [:]
        var targets: [Int: (color: MTLTexture, depth: MTLTexture)] = [:]
        var open: MTLTexture?
    }
}

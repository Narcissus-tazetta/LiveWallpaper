import Foundation
import Metal
import simd

/// Draws the layers scripts make from their own geometry straight onto the canvas, each
/// with its material's own shaders.
final class SceneModelRenderer {
    struct ModelError: LocalizedError {
        let detail: String
        var errorDescription: String? { "Scene model layer: \(detail)" }
    }

    private struct Material {
        var source: SceneMeshMaterial
        var vertex: MTLFunction
        var fragment: MTLFunction
        var samplers: [MTLSamplerState]
    }

    private struct PipelineKey: Hashable {
        var material: Int
        var components: UInt32
        var format: MTLPixelFormat
        var blend: SceneRenderGraph.Draw.Blend?
    }

    let materials: [SceneMeshMaterial?]
    private let device: MTLDevice
    private var compiled: [Int: Material] = [:]
    private var pipelines: [PipelineKey: MTLRenderPipelineState] = [:]
    private var depthStates: [Int: MTLDepthStencilState] = [:]
    /// Model layers draw in passes with a depth buffer of this format.
    static let depthFormat = MTLPixelFormat.depth32Float
    /// Components a shape lacks but a shader reads, from a buffer that every vertex shares.
    private let defaults: MTLBuffer

    init(materials: [SceneMeshMaterial?], device: MTLDevice) throws {
        self.materials = materials
        self.device = device
        for (index, material) in materials.enumerated() {
            guard let material else { continue }
            try Self.validate(material)
            let vertex = try device.makeLibrary(source: material.draw.vertex.source, options: nil)
            let fragment = try device.makeLibrary(source: material.draw.fragment.source, options: nil)
            guard let vertexFunction = vertex.makeFunction(name: material.draw.vertex.entryPoint),
                  let fragmentFunction = fragment.makeFunction(name: material.draw.fragment.entryPoint)
            else { throw ModelError(detail: "material \(material.path) has no entry point") }
            let samplers = try material.draw.textures.map { texture -> MTLSamplerState in
                let descriptor = MTLSamplerDescriptor()
                descriptor.minFilter = texture.linear ? .linear : .nearest
                descriptor.magFilter = texture.linear ? .linear : .nearest
                let mode: MTLSamplerAddressMode = texture.repeats ? .repeat : .clampToEdge
                descriptor.sAddressMode = mode
                descriptor.tAddressMode = mode
                guard let sampler = device.makeSamplerState(descriptor: descriptor) else {
                    throw ModelError(detail: "sampler allocation failed")
                }
                return sampler
            }
            compiled[index] = Material(source: material, vertex: vertexFunction, fragment: fragmentFunction, samplers: samplers)
        }
        // Inferred, not traced: white opaque colour, a normal facing the viewer, the tangent
        // along x and zero texture coordinates.
        let values: [Float] = [0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0, 0, 1, 1, 1, 1]
        guard let buffer = device.makeBuffer(bytes: values, length: values.count * 4, options: .storageModeShared) else {
            throw ModelError(detail: "buffer allocation failed")
        }
        defaults = buffer
    }

    /// Image files the materials sample, by resource name.
    var imageFiles: Set<String> {
        Set(materials.compactMap { $0 }.flatMap(\.images.values))
    }

    private static func validate(_ material: SceneMeshMaterial) throws {
        let draw = material.draw
        guard draw.dynamic == nil, draw.skeleton == nil, draw.skeletonID == nil, draw.commands == nil,
              !draw.attributes.isEmpty, draw.attributes.allSatisfy({ $0.semantic != nil }),
              Set(draw.attributes.map(\.location)).count == draw.attributes.count,
              draw.textures.allSatisfy({ (0 ..< 16).contains($0.index) && material.images[$0.source] != nil })
        else { throw ModelError(detail: "material \(material.path) is invalid") }
        for stage in [draw.vertex, draw.fragment] {
            for update in stage.updates {
                let bytes: Int = switch update.value {
                case .modelViewProjection, .model, .viewProjection: 64
                case .layerAlpha, .time, .frameTime: 4
                case .normalModel: 48
                case .layerColor, .eyePosition, .ambientColor, .skylightColor: 12
                case .textureSize: 16
                default: throw ModelError(detail: "material \(material.path) reads \(update.value.rawValue)")
                }
                guard update.offset >= 0, update.offset + bytes <= stage.uniforms.count else {
                    throw ModelError(detail: "material \(material.path) has a uniform outside its block")
                }
                if update.value == .textureSize, !(update.texture.map { material.images[$0] != nil } ?? false) {
                    throw ModelError(detail: "material \(material.path) sizes an unknown texture")
                }
            }
        }
    }

    private func pipeline(
        material index: Int, components: UInt32, format: MTLPixelFormat, blend: SceneRenderGraph.Draw.Blend?
    ) throws -> MTLRenderPipelineState {
        let key = PipelineKey(material: index, components: components, format: format, blend: blend)
        if let pipeline = pipelines[key] { return pipeline }
        let material = compiled[index]!
        let draw = material.source.draw
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = material.vertex
        descriptor.fragmentFunction = material.fragment
        let vertices = MTLVertexDescriptor()
        var offsets: [SceneRenderGraph.Attribute.Semantic: Int] = [:]
        var stride = 0
        for (bit, semantic) in SceneRenderGraph.Attribute.Semantic.allCases.enumerated() where components & (1 << UInt32(bit)) != 0 {
            offsets[semantic] = stride
            stride += semantic.floats * 4
        }
        // Offsets of the shared defaults, in the order of `init`.
        let defaultOffsets: [SceneRenderGraph.Attribute.Semantic: Int] = [
            .position: 0, .normal: 12, .tangentSigned: 24, .uv: 40, .color: 48
        ]
        for attribute in draw.attributes {
            let semantic = attribute.semantic!
            let element = vertices.attributes[attribute.location]!
            element.format = switch semantic.floats {
            case 2: .float2
            case 3: .float3
            default: .float4
            }
            if let offset = offsets[semantic] {
                element.offset = offset
                element.bufferIndex = 1
            } else {
                element.offset = defaultOffsets[semantic]!
                element.bufferIndex = 2
            }
        }
        vertices.layouts[1].stride = stride
        if draw.attributes.contains(where: { offsets[$0.semantic!] == nil }) {
            vertices.layouts[2].stride = 64
            vertices.layouts[2].stepFunction = .constant
            vertices.layouts[2].stepRate = 0
        }
        descriptor.vertexDescriptor = vertices
        descriptor.depthAttachmentPixelFormat = Self.depthFormat
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = format
        if draw.writesAlpha == false { attachment.writeMask = [.red, .green, .blue] }
        if let blend {
            attachment.isBlendingEnabled = true
            let weighted = blend == .alphaAdditive || blend == .alphaOver
            let source: MTLBlendFactor = weighted ? .sourceAlpha : .one
            attachment.sourceRGBBlendFactor = source
            attachment.sourceAlphaBlendFactor = source
            let destination: MTLBlendFactor = blend == .sourceOver || blend == .alphaOver ? .oneMinusSourceAlpha : .one
            attachment.destinationRGBBlendFactor = destination
            attachment.destinationAlphaBlendFactor = destination
            if blend == .maximum {
                attachment.rgbBlendOperation = .max
                attachment.alphaBlendOperation = .max
            }
        }
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        pipelines[key] = pipeline
        return pipeline
    }

    /// How a frame's model layers are seen: `viewProjection` takes scene units to the
    /// target's clip space.
    struct View {
        var viewProjection: simd_float4x4
        var eye: SIMD3<Float>
        var ambient: SIMD3<Float>
        var skylight: SIMD3<Float>
    }

    private func depthState(test: Bool, write: Bool) -> MTLDepthStencilState {
        let key = (test ? 1 : 0) | (write ? 2 : 0)
        if let state = depthStates[key] { return state }
        let descriptor = MTLDepthStencilDescriptor()
        // Equal depths pass so that flat layers at one depth keep their drawing order (inferred).
        descriptor.depthCompareFunction = test ? .lessEqual : .always
        descriptor.isDepthWriteEnabled = write
        let state = device.makeDepthStencilState(descriptor: descriptor)!
        depthStates[key] = state
        return state
    }

    /// Draws `layer` into the encoder's target, which has a depth attachment of `depthFormat`.
    func draw(
        _ layer: SceneModelLayerFrame, view: View, images: [String: MTLTexture],
        frame: SceneRenderGraphRenderer.FrameValues, time: Double, cursor: SIMD2<Float>?,
        audio: SceneAudioSpectrum?, format: MTLPixelFormat, encoder: MTLRenderCommandEncoder
    ) throws {
        let values = SceneRenderGraphRenderer.ModelValues(
            modelViewProjection: view.viewProjection * layer.world, model: layer.world, viewProjection: view.viewProjection,
            alpha: layer.alpha, color: layer.color, eye: view.eye, ambient: view.ambient, skylight: view.skylight
        )
        for shape in layer.shapes {
            guard let index = shape.material, let material = compiled[index], !shape.vertices.isEmpty else { continue }
            if let indices = shape.indices, indices.isEmpty { continue }
            let draw = material.source.draw
            var resources: [String: MTLTexture] = [:]
            for (name, file) in material.source.images {
                guard let texture = images[file] else { throw ModelError(detail: "image \(file) is missing") }
                resources[name] = texture
            }
            // Measured: an opaque material stays opaque whatever the alpha of its vertices or
            // of the layer.
            encoder.setRenderPipelineState(try pipeline(material: index, components: shape.components, format: format, blend: draw.blend))
            encoder.setDepthStencilState(depthState(test: draw.depthTest == true, write: draw.depthWrite == true))
            encoder.setFrontFacing(.counterClockwise)
            let cull: MTLCullMode = switch draw.cull {
            case .back: .back
            case .front: .front
            case nil: .none
            }
            encoder.setCullMode(cull)
            for (stage, isVertex) in [(draw.vertex, true), (draw.fragment, false)] {
                let data = SceneRenderGraphRenderer.updatedUniforms(
                    stage, frame: frame, model: values, resources: resources, time: time, cursor: cursor, pose: nil,
                    effectValues: [:], audio: audio
                ) ?? stage.uniforms
                guard !data.isEmpty else { continue }
                try data.withUnsafeBytes { bytes in
                    if bytes.count <= 4096 {
                        if isVertex {
                            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
                        } else {
                            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
                        }
                    } else {
                        guard let buffer = device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
                        else { throw ModelError(detail: "uniform allocation failed") }
                        if isVertex { encoder.setVertexBuffer(buffer, offset: 0, index: 0) } else {
                            encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
                        }
                    }
                }
            }
            for (binding, sampler) in zip(draw.textures, material.samplers) {
                let texture = resources[binding.source]!
                encoder.setVertexTexture(texture, index: binding.index)
                encoder.setFragmentTexture(texture, index: binding.index)
                encoder.setVertexSamplerState(sampler, index: binding.index)
                encoder.setFragmentSamplerState(sampler, index: binding.index)
            }
            guard let vertices = shape.vertices.withUnsafeBytes({
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            }) else { throw ModelError(detail: "vertex allocation failed") }
            encoder.setVertexBuffer(vertices, offset: 0, index: 1)
            encoder.setVertexBuffer(defaults, offset: 0, index: 2)
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

    private static let planeSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct PlaneUniforms { float4x4 transform; float4 color; };
    struct PlaneOut { float4 position [[position]]; float2 uv; };
    vertex PlaneOut planeVertex(uint id [[vertex_id]], constant PlaneUniforms& u [[buffer(0)]]) {
        float2 corner = float2(id == 1 || id == 2 || id == 4 ? 0.5 : -0.5, id == 2 || id == 4 || id == 5 ? 0.5 : -0.5);
        PlaneOut out;
        out.position = u.transform * float4(corner, 0, 1);
        out.uv = float2(corner.x + 0.5, 0.5 - corner.y);
        return out;
    }
    fragment float4 planeFragment(PlaneOut in [[stage_in]], texture2d<float> picture [[texture(0)]],
                                  sampler linear [[sampler(0)]], constant PlaneUniforms& u [[buffer(0)]]) {
        // The picture is premultiplied; the tint scales its colour, the alpha its coverage.
        float4 c = picture.sample(linear, in.uv);
        return float4(c.rgb * u.color.rgb, c.a) * u.color.a;
    }
    """
    private var planeFunctions: (MTLFunction, MTLFunction)?
    private var planePipelines: [String: MTLRenderPipelineState] = [:]
    private var planeSampler: MTLSamplerState?

    /// Draws a layer's picture as the plane it is in the scene: `transform` takes the unit
    /// square centred at the origin (y up) to clip space; `color` is the tint and opacity.
    func drawPlane(
        _ picture: MTLTexture, transform: simd_float4x4, color: SIMD4<Float>, space: SceneSpace,
        format: MTLPixelFormat, encoder: MTLRenderCommandEncoder
    ) throws {
        if planeFunctions == nil {
            let library = try device.makeLibrary(source: Self.planeSource, options: nil)
            planeFunctions = (library.makeFunction(name: "planeVertex")!, library.makeFunction(name: "planeFragment")!)
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = .linear
            descriptor.magFilter = .linear
            planeSampler = device.makeSamplerState(descriptor: descriptor)
        }
        let key = "\(space.blending.rawValue)-\(format.rawValue)"
        if planePipelines[key] == nil {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = planeFunctions!.0
            descriptor.fragmentFunction = planeFunctions!.1
            descriptor.depthAttachmentPixelFormat = Self.depthFormat
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = format
            if space.blending != .normal {
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                let destination: MTLBlendFactor = space.blending == .additive ? .one : .oneMinusSourceAlpha
                attachment.destinationRGBBlendFactor = destination
                attachment.destinationAlphaBlendFactor = destination
            }
            planePipelines[key] = try device.makeRenderPipelineState(descriptor: descriptor)
        }
        encoder.setRenderPipelineState(planePipelines[key]!)
        encoder.setDepthStencilState(depthState(test: space.depthTest, write: space.depthWrite))
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(space.cull == .back ? .back : space.cull == .front ? .front : .none)
        var uniforms = (transform, color)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<(simd_float4x4, SIMD4<Float>)>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<(simd_float4x4, SIMD4<Float>)>.stride, index: 0)
        encoder.setFragmentTexture(picture, index: 0)
        encoder.setFragmentSamplerState(planeSampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    /// A camera looking from `eye` to `center` with a vertical field of view, for a target
    /// of `aspect` (width over height); depth 0 at `near` to 1 at `far`.
    static func perspective(_ camera: SceneCameraState, aspect: Float) -> simd_float4x4 {
        let f = 1 / tan(camera.fov * .pi / 360), near = camera.nearZ, far = camera.farZ
        let projection = simd_float4x4(columns: (
            SIMD4(f / aspect, 0, 0, 0), SIMD4(0, f, 0, 0),
            SIMD4(0, 0, far / (near - far), -1), SIMD4(0, 0, near * far / (near - far), 0)
        ))
        let z = simd_normalize(camera.eye - camera.center)
        let x = simd_normalize(simd_cross(camera.up, z))
        let y = simd_cross(z, x)
        let view = simd_float4x4(columns: (
            SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0), SIMD4(x.z, y.z, z.z, 0),
            SIMD4(-simd_dot(x, camera.eye), -simd_dot(y, camera.eye), -simd_dot(z, camera.eye), 1)
        ))
        return projection * view
    }

    /// Measured for a layer marked perspective in a scene seen through its camera: the
    /// camera's place and the depth of the vertices change nothing, and a unit spans
    /// half the height over tan(fov / 2). Only this case was measured.
    static func unitPerspective(_ camera: SceneCameraState, aspect: Float) -> simd_float4x4 {
        let f = 1 / tan(camera.fov * .pi / 360)
        return simd_float4x4(columns: (SIMD4(f / aspect, 0, 0, 0), SIMD4(0, f, 0, 0), SIMD4(0, 0, 0, 0), SIMD4(0, 0, 0.5, 1)))
    }

    /// Scene pixels (origin bottom left, y up) to the clip space of a target that shows
    /// `viewport` (origin and size in canvas UV, y down) of the canvas.
    static func canvasProjection(width: Double, height: Double, viewport: SIMD4<Float>) -> simd_float4x4 {
        let w = Float(width), h = Float(height)
        let vx = viewport.x, vy = viewport.y, vw = viewport.z, vh = viewport.w
        return simd_float4x4(columns: (
            SIMD4(2 / (w * vw), 0, 0, 0),
            SIMD4(0, 2 / (h * vh), 0, 0),
            SIMD4(0, 0, 0, 0),
            SIMD4(-2 * vx / vw - 1, 1 - 2 * (1 - vy) / vh, 0.5, 1)
        ))
    }
}

import Foundation
import Metal

final class SceneRenderGraphRenderer {
    struct GraphError: LocalizedError {
        let detail: String
        var errorDescription: String? {
            "Scene render graph: \(detail)"
        }
    }

    private struct CompiledDraw {
        var pipeline: MTLRenderPipelineState
        var vertices: MTLBuffer
        var samplers: [MTLSamplerState]
        var vertexUniforms: MTLBuffer?
        var fragmentUniforms: MTLBuffer?
        var indices: MTLBuffer?
        var skeleton: SceneSkeletonEvaluator?
        var commands: [CompiledCommand]
    }

    private struct CompiledCommand {
        var firstIndex: Int
        var indexCount: Int
        var textures: [SceneRenderGraph.Texture]
        var samplers: [MTLSamplerState]
        var fragmentUniforms: MTLBuffer?
    }

    private enum UniformBinding {
        case inline(Data)
        case buffer(MTLBuffer?)
    }

    let graph: SceneRenderGraph
    private let device: MTLDevice
    private let rigs: SceneSkeletonRegistry
    private var draws: [Int: CompiledDraw] = [:]
    private var targets: [String: MTLTexture] = [:]
    private var size: SIMD2<Int>?

    init(graph: SceneRenderGraph, device: MTLDevice, rigs: SceneSkeletonRegistry? = nil) throws {
        self.graph = graph
        self.device = device
        self.rigs = try rigs ?? SceneSkeletonRegistry()
        try validate()
        for (index, pass) in graph.passes.enumerated() {
            guard let draw = pass.draw else { continue }
            let descriptor = MTLRenderPipelineDescriptor()
            let vertex = try device.makeLibrary(source: draw.vertex.source, options: nil)
            let fragment = try device.makeLibrary(source: draw.fragment.source, options: nil)
            guard let vertexFunction = vertex.makeFunction(name: draw.vertex.entryPoint),
                  let fragmentFunction = fragment.makeFunction(name: draw.fragment.entryPoint)
            else { throw GraphError(detail: "pass \(index) entry point is missing") }
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0]
                .pixelFormat = pixelFormat(graph.targets.first { $0.name == pass.target }!.format)
            if let blend = draw.blend {
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment
                    .destinationRGBBlendFactor = blend == .sourceOver ? .oneMinusSourceAlpha : .one
                attachment
                    .destinationAlphaBlendFactor = blend == .sourceOver ?
                    .oneMinusSourceAlpha : .one
                if blend == .maximum {
                    attachment.rgbBlendOperation = .max
                    attachment.alphaBlendOperation = .max
                }
            }
            let layout = MTLVertexDescriptor()
            for attribute in draw.attributes {
                layout.attributes[attribute.location].format = vertexFormat(attribute.format)
                layout.attributes[attribute.location].offset = attribute.offset
                layout.attributes[attribute.location].bufferIndex = 1
            }
            layout.layouts[1].stride = draw.vertexStride
            descriptor.vertexDescriptor = layout
            guard let vertices = draw.vertices.withUnsafeBytes({ bytes in
                device.makeBuffer(
                    bytes: bytes.baseAddress!,
                    length: bytes.count,
                    options: .storageModeShared
                )
            }) else { throw GraphError(detail: "pass \(index) vertex allocation failed") }
            func samplers(_ textures: [SceneRenderGraph.Texture]) throws -> [MTLSamplerState] {
                try textures.map { texture in
                    let sampler = MTLSamplerDescriptor()
                    sampler.minFilter = texture.linear ? .linear : .nearest
                    sampler.magFilter = texture.linear ? .linear : .nearest
                    sampler.sAddressMode = texture.repeats ? .repeat : .clampToEdge
                    sampler.tAddressMode = sampler.sAddressMode
                    guard let state = device.makeSamplerState(descriptor: sampler) else {
                        throw GraphError(detail: "pass \(index) sampler allocation failed")
                    }
                    return state
                }
            }
            let commands = try (draw.commands ?? []).map { command in
                let textures = command.textures ?? draw.textures
                return try CompiledCommand(
                    firstIndex: command.firstIndex,
                    indexCount: command.indexCount,
                    textures: textures,
                    samplers: samplers(textures),
                    fragmentUniforms: command.fragmentUniforms.map(makeBuffer)
                )
            }
            draws[index] = try CompiledDraw(
                pipeline: device.makeRenderPipelineState(descriptor: descriptor),
                vertices: vertices,
                samplers: samplers(draw.textures),
                vertexUniforms: staticUniforms(draw.vertex),
                fragmentUniforms: staticUniforms(draw.fragment),
                indices: draw.indices.map { try makeBuffer($0) },
                skeleton: skeletonEvaluator(draw),
                commands: commands
            )
        }
    }

    private func skeletonEvaluator(_ draw: SceneRenderGraph
        .Draw) throws -> SceneSkeletonEvaluator?
    {
        if draw.skeleton != nil, draw.skeletonID != nil {
            throw GraphError(detail: "draw cannot have both an inline skeleton and a rig reference")
        }
        if let id = draw.skeletonID { return try rigs.evaluator(id) }
        return try draw.skeleton.map(SceneSkeletonEvaluator.init)
    }

    func encode(
        input: MTLTexture,
        images: [String: MTLTexture],
        time: Double,
        cursor: SIMD2<Float>?,
        values: [String: Double] = [:],
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        let newSize = SIMD2(input.width, input.height)
        if newSize != size {
            targets.removeAll()
            for target in graph.targets {
                let width = Double(input.width) * target.scale
                let height = Double(input.height) * target.scale
                guard width >= 1, height >= 1, width < Double(Int.max),
                      height < Double(Int.max)
                else {
                    throw GraphError(detail: "invalid size for target \(target.name)")
                }
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: pixelFormat(target.format), width: Int(width), height: Int(height),
                    mipmapped: false
                )
                descriptor.storageMode = .private
                descriptor.usage = [.renderTarget, .shaderRead]
                guard let texture = device.makeTexture(descriptor: descriptor) else {
                    throw GraphError(detail: "target \(target.name) allocation failed")
                }
                texture.label = target.name
                targets[target.name] = texture
                let clear = MTLRenderPassDescriptor()
                clear.colorAttachments[0].texture = texture
                clear.colorAttachments[0].loadAction = .clear
                clear.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                clear.colorAttachments[0].storeAction = .store
                guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: clear) else {
                    throw GraphError(detail: "target \(target.name) clear failed")
                }
                encoder.endEncoding()
            }
            size = newSize
        }
        var resources = targets
        resources["input"] = input
        for (name, file) in graph.images {
            guard let image = images[file]
            else { throw GraphError(detail: "image \(file) is missing") }
            resources[name] = image
        }
        for (index, pass) in graph.passes.enumerated() {
            let target = resources[pass.target]!
            switch pass.operation {
            case .copy:
                let source = resources[pass.source!]!
                guard source.width == target.width, source.height == target.height,
                      source.pixelFormat == target.pixelFormat
                else {
                    throw GraphError(detail: "copy pass \(index) requires matching size and format")
                }
                guard let encoder = commandBuffer.makeBlitCommandEncoder()
                else { throw GraphError(detail: "copy encoder failed") }
                encoder.copy(
                    from: source,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(),
                    sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                    to: target,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin()
                )
                encoder.endEncoding()
            case .draw:
                let draw = pass.draw!, compiled = draws[index]!
                let pose = compiled.skeleton?.evaluate(time: time)
                let vertex = try uniformBinding(
                    draw.vertex,
                    cached: compiled.vertexUniforms,
                    resources: resources,
                    time: time,
                    cursor: cursor,
                    pose: pose,
                    effectValues: values
                )
                let fragment = try uniformBinding(
                    draw.fragment,
                    cached: compiled.fragmentUniforms,
                    resources: resources,
                    time: time,
                    cursor: cursor,
                    pose: pose,
                    effectValues: values
                )
                let descriptor = MTLRenderPassDescriptor()
                descriptor.colorAttachments[0].texture = target
                descriptor.colorAttachments[0].loadAction = .clear
                descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                descriptor.colorAttachments[0].storeAction = .store
                guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
                else {
                    throw GraphError(detail: "draw encoder failed")
                }
                encoder.setRenderPipelineState(compiled.pipeline)
                encoder.setVertexBuffer(compiled.vertices, offset: 0, index: 1)
                bindUniforms(vertex, encoder: encoder, vertex: true)
                bindUniforms(fragment, encoder: encoder, vertex: false)
                for (binding, sampler) in zip(draw.textures, compiled.samplers) {
                    let texture = resources[binding.source]!
                    encoder.setVertexTexture(texture, index: binding.index)
                    encoder.setFragmentTexture(texture, index: binding.index)
                    encoder.setVertexSamplerState(sampler, index: binding.index)
                    encoder.setFragmentSamplerState(sampler, index: binding.index)
                }
                drawGeometry(
                    draw,
                    compiled: compiled,
                    fragment: fragment,
                    resources: resources,
                    encoder: encoder
                )
                encoder.endEncoding()
            }
        }
        return resources[graph.output]!
    }

    private func drawGeometry(
        _ draw: SceneRenderGraph.Draw, compiled: CompiledDraw, fragment: UniformBinding,
        resources: [String: MTLTexture], encoder: MTLRenderCommandEncoder
    ) {
        if let indices = compiled.indices {
            if draw.commands != nil {
                for command in compiled.commands {
                    for (binding, sampler) in zip(command.textures, command.samplers) {
                        encoder.setVertexTexture(resources[binding.source]!, index: binding.index)
                        encoder.setFragmentTexture(resources[binding.source]!, index: binding.index)
                        encoder.setVertexSamplerState(sampler, index: binding.index)
                        encoder.setFragmentSamplerState(sampler, index: binding.index)
                    }
                    bindUniforms(
                        command.fragmentUniforms.map(UniformBinding.buffer) ?? fragment,
                        encoder: encoder,
                        vertex: false
                    )
                    encoder.drawIndexedPrimitives(
                        type: .triangle,
                        indexCount: command.indexCount,
                        indexType: .uint16,
                        indexBuffer: indices,
                        indexBufferOffset: command.firstIndex * 2
                    )
                }
            } else {
                encoder.drawIndexedPrimitives(
                    type: .triangle, indexCount: draw.indices!.count / 2,
                    indexType: .uint16, indexBuffer: indices, indexBufferOffset: 0
                )
            }
        } else {
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: draw.vertexCount
            )
        }
    }

    private func staticUniforms(_ stage: SceneRenderGraph.Stage) throws -> MTLBuffer? {
        guard !stage.uniforms.isEmpty, stage.updates.isEmpty else { return nil }
        return try makeBuffer(stage.uniforms)
    }

    private func makeBuffer(_ data: Data) throws -> MTLBuffer {
        guard let buffer = data.withUnsafeBytes({ device.makeBuffer(
            bytes: $0.baseAddress!,
            length: $0.count,
            options: .storageModeShared
        ) }) else {
            throw GraphError(detail: "uniform allocation failed")
        }
        return buffer
    }

    private func uniformBinding(
        _ stage: SceneRenderGraph.Stage,
        cached: MTLBuffer?,
        resources: [String: MTLTexture],
        time: Double,
        cursor: SIMD2<Float>?,
        pose: SceneSkeletonEvaluator.Pose?,
        effectValues: [String: Double]
    ) throws -> UniformBinding {
        guard let data = updatedUniforms(
            stage,
            resources: resources,
            time: time,
            cursor: cursor,
            pose: pose,
            effectValues: effectValues
        )
        else { return .buffer(cached) }
        // Metal's inline argument storage is limited to 4 KiB; larger animated blocks
        // need their own buffer, retained by the command buffer until the GPU is done.
        return data.count <= 4096 ? .inline(data) : try .buffer(makeBuffer(data))
    }

    private func bindUniforms(
        _ binding: UniformBinding,
        encoder: MTLRenderCommandEncoder,
        vertex: Bool
    ) {
        switch binding {
        case let .inline(data):
            data.withUnsafeBytes { bytes in
                if vertex {
                    encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
                } else {
                    encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
                }
            }
        case let .buffer(buffer):
            if vertex {
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            } else {
                encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
            }
        }
    }

    private func updatedUniforms(
        _ stage: SceneRenderGraph.Stage,
        resources: [String: MTLTexture],
        time: Double,
        cursor: SIMD2<Float>?,
        pose: SceneSkeletonEvaluator.Pose?,
        effectValues: [String: Double]
    ) -> Data? {
        guard !stage.updates.isEmpty else { return nil }
        var data = stage.uniforms
        for update in stage.updates {
            let values: [Float]
            switch update.value {
            case .time: values = [Float(time)]
            case .cursor: values = [cursor?.x ?? 0, cursor?.y ?? 0]
            case .textureSize:
                let texture = resources[update.texture!]!
                values = [
                    Float(texture.width),
                    Float(texture.height),
                    Float(texture.width),
                    Float(texture.height)
                ]
            case .boneMatrices:
                for (index, matrix) in pose!.matrices.enumerated() {
                    var matrix = matrix
                    withUnsafeBytes(of: &matrix) { bytes in
                        let offset = update.offset + index * (update.stride ?? 64)
                        data.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
                    }
                }
                continue
            case .boneOpacity:
                for (index, value) in pose!.opacity.enumerated() {
                    var value = value
                    withUnsafeBytes(of: &value) { bytes in
                        let offset = update.offset + index * (update.stride ?? 16)
                        data.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
                    }
                }
                continue
            case .effectValue:
                let count = update.components ?? 1
                let key = update.key!
                if count == 1 {
                    values = [Float(effectValues[key] ?? 0)]
                } else {
                    values = (0 ..< count).map { Float(effectValues["\(key).\($0)"] ?? 0) }
                }
            }
            values.withUnsafeBytes { data.replaceSubrange(
                update.offset ..< update.offset + $0.count,
                with: $0
            ) }
        }
        return data
    }

    private func validate() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw GraphError(detail: message) }
        }
        let names = graph.targets.map(\.name) + Array(graph.images.keys) + ["input"]
        try require(Set(names).count == names.count, "resource names must be unique")
        let resources = Set(names), targets = Set(graph.targets.map(\.name))
        try require(resources.contains(graph.output), "unknown output \(graph.output)")
        for file in graph.images.values {
            try require(
                !file.isEmpty && file != "." && file != ".." && !file.contains("/") && !file
                    .contains("\\") && !file.contains("\0"),
                "image resources require plain file names"
            )
        }
        for target in graph.targets {
            try require(target.scale.isFinite && target.scale > 0, "invalid target scale")
        }
        for (index, pass) in graph.passes.enumerated() {
            try require(targets.contains(pass.target), "pass \(index) has an unknown target")
            switch pass.operation {
            case .copy:
                try require(
                    pass.draw == nil && pass.source != nil,
                    "copy pass \(index) is incomplete"
                )
                try require(
                    resources.contains(pass.source!),
                    "copy pass \(index) has an unknown source"
                )
                try require(pass.source != pass.target, "copy pass \(index) aliases its target")
            case .draw:
                try require(
                    pass.draw != nil && pass.source == nil,
                    "draw pass \(index) is incomplete"
                )
                let draw = pass.draw!
                _ = try skeletonEvaluator(draw)
                try require(
                    draw.vertexCount > 0 && draw.vertexStride > 0 && draw.vertexCount <= draw
                        .vertices.count / draw.vertexStride,
                    "pass \(index) has invalid vertex data"
                )
                if let indices = draw.indices {
                    try require(
                        !indices.isEmpty && indices.count % 6 == 0,
                        "invalid triangle indices"
                    )
                    try indices.withUnsafeBytes { bytes in
                        for offset in stride(from: 0, to: bytes.count, by: 2) {
                            try require(
                                Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) <
                                    draw.vertexCount,
                                "triangle references a missing vertex"
                            )
                        }
                    }
                }
                let commandBindings =
                    Set((draw.textures + (draw.commands ?? []).flatMap { $0.textures ?? [] })
                            .map(\.index))
                try require(draw.commands == nil || draw.indices != nil, "indexed commands require an index buffer")
                for command in draw.commands ?? [] {
                    let count = draw.indices?.count ?? 0
                    try require(
                        count > 0 && command.firstIndex >= 0 && command.firstIndex <= count / 2 &&
                            command.indexCount >= 0 && command.indexCount <= count / 2 - command
                            .firstIndex &&
                            command.indexCount % 3 == 0,
                        "invalid indexed command range"
                    )
                    if command.fragmentUniforms != nil {
                        try require(
                            draw.fragment.updates.isEmpty && !command.fragmentUniforms!.isEmpty &&
                                command.fragmentUniforms!.count == draw.fragment.uniforms.count,
                            "command uniforms must match a static fragment block"
                        )
                    }
                    let textures = command.textures ?? draw.textures
                    try require(
                        Set(textures.map(\.index)).count == textures.count,
                        "duplicate command texture binding"
                    )
                    try require(
                        Set(textures.map(\.index)) == commandBindings,
                        "commands must bind the same texture slots"
                    )
                }
                try require(
                    Set(draw.attributes.map(\.location)).count == draw.attributes.count,
                    "duplicate vertex attributes"
                )
                for attribute in draw.attributes {
                    try require(
                        attribute.location >= 0 && attribute.location < 31 && attribute
                            .offset >= 0 &&
                            attribute.offset <= draw
                            .vertexStride - attributeBytes(attribute.format),
                        "invalid vertex attribute"
                    )
                }
                try require(
                    Set(draw.textures.map(\.index)).count == draw.textures.count,
                    "duplicate texture binding"
                )
                for texture in draw.textures + (draw.commands ?? [])
                    .flatMap({ $0.textures ?? [] })
                {
                    try require(
                        texture.index >= 0 && texture.index < 16 && resources
                            .contains(texture.source),
                        "invalid texture binding"
                    )
                    try require(
                        texture.source != pass.target,
                        "draw pass \(index) samples its target"
                    )
                }
                try validateUniforms(draw, resources: resources)
            }
        }
    }

    private func validateUniforms(_ draw: SceneRenderGraph.Draw, resources: Set<String>) throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw GraphError(detail: message) }
        }
        for stage in [draw.vertex, draw.fragment] {
            for update in stage.updates {
                let bytes: Int
                switch update.value {
                case .time: bytes = 4
                case .cursor: bytes = 8
                case .textureSize: bytes = 16
                case .boneMatrices, .boneOpacity:
                    let count = (draw.skeleton ?? draw.skeletonID.flatMap { rigs.skeletons[$0] })?
                        .bones.count ?? 0
                    let element = update.value == .boneMatrices ? 64 : 4
                    let stride = update.stride ?? (update.value == .boneMatrices ? 64 : 16)
                    try require(
                        count > 0 && stride >= element && stride <= stage.uniforms
                            .count / count,
                        "invalid skeleton uniform layout"
                    )
                    bytes = (count - 1) * stride + element
                case .effectValue:
                    let count = update.components ?? 1
                    try require(
                        (1 ... 16).contains(count) && update.key?.isEmpty == false,
                        "invalid effect uniform update"
                    )
                    bytes = count * 4
                }
                try require(
                    update.offset >= 0 && update.offset <= stage.uniforms.count - bytes,
                    "uniform update is outside its buffer"
                )
                if update.value == .textureSize {
                    try require(
                        update.texture.map { resources.contains($0) } == true,
                        "uniform references an unknown texture"
                    )
                }
            }
        }
    }

    private func pixelFormat(_ format: SceneRenderGraph.Target.Format) -> MTLPixelFormat {
        switch format {
        case .rgba8: .rgba8Unorm
        case .rgba16Float: .rgba16Float
        case .r8: .r8Unorm
        case .rg16Float: .rg16Float
        }
    }

    private func attributeBytes(_ format: SceneRenderGraph.Attribute.Format) -> Int {
        switch format {
        case .float: 4
        case .float2: 8
        case .float3: 12
        case .float4, .uint4: 16
        }
    }

    private func vertexFormat(_ format: SceneRenderGraph.Attribute.Format) -> MTLVertexFormat {
        switch format {
        case .float: .float
        case .float2: .float2
        case .float3: .float3
        case .float4: .float4
        case .uint4: .uint4
        }
    }
}

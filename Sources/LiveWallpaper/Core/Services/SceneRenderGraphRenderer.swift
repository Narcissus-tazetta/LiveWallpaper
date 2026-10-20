import Foundation
import Metal

final class SceneRenderGraphRenderer {
    struct GraphError: LocalizedError {
        let detail: String
        var errorDescription: String? {
            "Scene render graph: \(detail)"
        }
    }

    private final class CompiledDraw {
        var pipeline: MTLRenderPipelineState
        var vertices: MTLBuffer
        var samplers: [MTLSamplerState]
        var vertexUniforms: MTLBuffer?
        var fragmentUniforms: MTLBuffer?
        var indices: MTLBuffer?
        var skeleton: SceneSkeletonEvaluator?
        var commands: [CompiledCommand]
        var materialSamplers: [String: [MTLSamplerState]]
        var dynamicVertexBuffers: [MTLBuffer]
        var dynamicBufferIndex: Int = 0

        init(
            pipeline: MTLRenderPipelineState,
            vertices: MTLBuffer,
            samplers: [MTLSamplerState],
            vertexUniforms: MTLBuffer?,
            fragmentUniforms: MTLBuffer?,
            indices: MTLBuffer?,
            skeleton: SceneSkeletonEvaluator?,
            commands: [CompiledCommand],
            materialSamplers: [String: [MTLSamplerState]],
            dynamicVertexBuffers: [MTLBuffer] = []
        ) {
            self.pipeline = pipeline
            self.vertices = vertices
            self.samplers = samplers
            self.vertexUniforms = vertexUniforms
            self.fragmentUniforms = fragmentUniforms
            self.indices = indices
            self.skeleton = skeleton
            self.commands = commands
            self.materialSamplers = materialSamplers
            self.dynamicVertexBuffers = dynamicVertexBuffers
        }
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
            let layout = MTLVertexDescriptor()
            for attribute in draw.attributes {
                layout.attributes[attribute.location].format = vertexFormat(attribute.format)
                layout.attributes[attribute.location].offset = attribute.offset
                layout.attributes[attribute.location].bufferIndex = 1
            }
            layout.layouts[1].stride = draw.vertexStride
            descriptor.vertexDescriptor = layout
            guard let vertices = draw.dynamic != nil
                ? device.makeBuffer(length: 16, options: .storageModeShared)
                : draw.vertices.withUnsafeBytes({ bytes in
                    device.makeBuffer(
                        bytes: bytes.baseAddress!,
                        length: bytes.count,
                        options: .storageModeShared
                    )
                })
            else { throw GraphError(detail: "pass \(index) vertex allocation failed") }
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
            var dynamicBuffers: [MTLBuffer] = []
            if let dynamic = draw.dynamic {
                let bytesPerQuad = SceneMeshFrame.floatsPerQuad * MemoryLayout<Float>.stride
                let capacityInBytes = dynamic.capacity * bytesPerQuad
                for _ in 0 ..< 3 {
                    guard let buf = device.makeBuffer(length: capacityInBytes, options: .storageModeShared) else {
                        throw GraphError(detail: "pass \(index) dynamic vertex buffer allocation failed")
                    }
                    dynamicBuffers.append(buf)
                }
            }
            draws[index] = try CompiledDraw(
                pipeline: device.makeRenderPipelineState(descriptor: descriptor),
                vertices: vertices,
                samplers: samplers(draw.textures),
                vertexUniforms: staticUniforms(draw.vertex),
                fragmentUniforms: staticUniforms(draw.fragment),
                indices: draw.dynamic.map { try makeBuffer(Self.quadIndices($0.capacity)) }
                    ?? draw.indices.map { try makeBuffer($0) },
                skeleton: skeletonEvaluator(draw),
                commands: commands,
                materialSamplers: (draw.dynamic?.materials ?? [:]).mapValues(samplers),
                dynamicVertexBuffers: dynamicBuffers
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
        audio: SceneAudioSpectrum? = nil,
        meshes: [SceneMeshFrame] = [],
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
        var activeEncoder: MTLRenderCommandEncoder?
        var activeTargetName: String?
        func endActiveEncoder() {
            activeEncoder?.endEncoding()
            activeEncoder = nil
            activeTargetName = nil
        }

        do {
            for (index, pass) in graph.passes.enumerated() {
                let target = resources[pass.target]!
                switch pass.operation {
                case .copy:
                    endActiveEncoder()
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
                    // A pass that adds to its target and has nothing to add costs a full
                    // load and store of the target for no change.
                    if let dynamic = draw.dynamic, draw.clears == false,
                       !meshes.contains(where: { $0.parent == dynamic.parent && dynamic.materials[$0.material] != nil }) {
                        continue
                    }
                    let pose = compiled.skeleton?.evaluate(time: time)
                    let vertex = try uniformBinding(
                        draw.vertex,
                        cached: compiled.vertexUniforms,
                        resources: resources,
                        time: time,
                        cursor: cursor,
                        pose: pose,
                        effectValues: values,
                        audio: audio
                    )
                    // A mesh pass fills its own fragment block per material.
                    let fragment = try draw.dynamic != nil ? UniformBinding.buffer(nil) : uniformBinding(
                        draw.fragment,
                        cached: compiled.fragmentUniforms,
                        resources: resources,
                        time: time,
                        cursor: cursor,
                        pose: pose,
                        effectValues: values,
                        audio: audio
                    )
                    let requiresNewEncoder = activeEncoder == nil
                        || activeTargetName != pass.target
                        || draw.clears != false
                    if requiresNewEncoder {
                        endActiveEncoder()
                        let descriptor = MTLRenderPassDescriptor()
                        descriptor.colorAttachments[0].texture = target
                        descriptor.colorAttachments[0].loadAction = draw.clears == false ? .load : .clear
                        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                        descriptor.colorAttachments[0].storeAction = .store
                        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
                        else {
                            throw GraphError(detail: "draw encoder failed")
                        }
                        activeEncoder = encoder
                        activeTargetName = pass.target
                    }
                    guard let encoder = activeEncoder else {
                        throw GraphError(detail: "draw encoder missing")
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
                    if let dynamic = draw.dynamic {
                        try drawMeshes(
                            draw, dynamic: dynamic, compiled: compiled, meshes: meshes, resources: resources,
                            time: time, cursor: cursor, effectValues: values, audio: audio, encoder: encoder
                        )
                    } else {
                        drawGeometry(
                            draw,
                            compiled: compiled,
                            fragment: fragment,
                            resources: resources,
                            encoder: encoder
                        )
                    }
                }
            }
            endActiveEncoder()
        } catch {
            endActiveEncoder()
            throw error
        }
        return resources[graph.output]!
    }

    private static func quadIndices(_ capacity: Int) -> Data {
        var indices: [UInt16] = []
        indices.reserveCapacity(capacity * 6)
        for quad in 0 ..< capacity {
            let first = UInt16(quad * 4)
            indices += [first, first + 1, first + 2, first, first + 2, first + 3]
        }
        return indices.withUnsafeBytes { Data($0) }
    }

    /// Writes the meshes made for this pass's parent into one buffer, in the order
    /// they arrive, and draws each run of quads with its own material's textures.
    private func drawMeshes(
        _ draw: SceneRenderGraph.Draw, dynamic: SceneRenderGraph.DynamicMesh, compiled: CompiledDraw,
        meshes: [SceneMeshFrame], resources: [String: MTLTexture], time: Double, cursor: SIMD2<Float>?,
        effectValues: [String: Double], audio: SceneAudioSpectrum?, encoder: MTLRenderCommandEncoder
    ) throws {
        struct Run { var material: String; var firstQuad: Int; var quads: Int }
        var runs: [Run] = []
        var totalQuads = 0
        for mesh in meshes where mesh.parent == dynamic.parent && dynamic.materials[mesh.material] != nil {
            let count = mesh.vertices.count / SceneMeshFrame.floatsPerQuad
            guard count > 0 else { continue }
            guard totalQuads + count <= dynamic.capacity else {
                throw GraphError(detail: "mesh quads exceed the pass capacity of \(dynamic.capacity)")
            }
            totalQuads += count
        }
        guard totalQuads > 0 else { return }

        let buffer: MTLBuffer
        if !compiled.dynamicVertexBuffers.isEmpty {
            buffer = compiled.dynamicVertexBuffers[compiled.dynamicBufferIndex]
            compiled.dynamicBufferIndex = (compiled.dynamicBufferIndex + 1) % compiled.dynamicVertexBuffers.count
        } else {
            let byteCount = totalQuads * SceneMeshFrame.floatsPerQuad * MemoryLayout<Float>.stride
            guard let buf = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
                throw GraphError(detail: "mesh vertex allocation failed")
            }
            buffer = buf
        }

        let rawPointer = buffer.contents()
        var currentFloatOffset = 0
        var quads = 0
        for mesh in meshes where mesh.parent == dynamic.parent && dynamic.materials[mesh.material] != nil {
            let count = mesh.vertices.count / SceneMeshFrame.floatsPerQuad
            guard count > 0 else { continue }
            let floatCount = count * SceneMeshFrame.floatsPerQuad
            mesh.vertices.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                rawPointer.advanced(by: currentFloatOffset * MemoryLayout<Float>.stride)
                    .copyMemory(from: base, byteCount: floatCount * MemoryLayout<Float>.stride)
            }
            runs.append(Run(material: mesh.material, firstQuad: quads, quads: count))
            currentFloatOffset += floatCount
            quads += count
        }

        encoder.setVertexBuffer(buffer, offset: 0, index: 1)
        for run in runs {
            var slots = resources
            let textures = dynamic.materials[run.material]!
            for (binding, sampler) in zip(textures, compiled.materialSamplers[run.material]!) {
                let texture = resources[binding.source]!
                slots["slot:\(binding.index)"] = texture
                encoder.setVertexTexture(texture, index: binding.index)
                encoder.setFragmentTexture(texture, index: binding.index)
                encoder.setVertexSamplerState(sampler, index: binding.index)
                encoder.setFragmentSamplerState(sampler, index: binding.index)
            }
            bindUniforms(
                try uniformBinding(
                    draw.fragment, cached: compiled.fragmentUniforms, resources: slots, time: time,
                    cursor: cursor, pose: nil, effectValues: effectValues, audio: audio
                ),
                encoder: encoder, vertex: false
            )
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: run.quads * 6, indexType: .uint16,
                indexBuffer: compiled.indices!, indexBufferOffset: run.firstQuad * 12
            )
        }
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
        effectValues: [String: Double],
        audio: SceneAudioSpectrum?
    ) throws -> UniformBinding {
        guard let data = updatedUniforms(
            stage,
            resources: resources,
            time: time,
            cursor: cursor,
            pose: pose,
            effectValues: effectValues,
            audio: audio
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
        effectValues: [String: Double],
        audio: SceneAudioSpectrum?
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
            case .audioSpectrum:
                let count = update.components!
                // Silence when nothing listens (a bake, sound reaction off).
                let bands = audio?.bands(count, right: update.key == "right") ?? Array(repeating: 0, count: count)
                for (index, value) in bands.enumerated() {
                    var value = value
                    withUnsafeBytes(of: &value) { bytes in
                        let offset = update.offset + index * update.stride!
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
                if let dynamic = draw.dynamic {
                    try require(
                        draw.vertexStride == SceneMeshFrame.vertexStride &&
                            (1 ... 16383).contains(dynamic.capacity) && !dynamic.parent.isEmpty &&
                            draw.indices == nil && draw.commands == nil && draw.textures.isEmpty &&
                            draw.skeleton == nil && draw.skeletonID == nil,
                        "pass \(index) has an invalid dynamic mesh"
                    )
                    for textures in dynamic.materials.values {
                        try require(
                            Set(textures.map(\.index)).count == textures.count && textures.allSatisfy {
                                (0 ..< 16).contains($0.index) && resources.contains($0.source) &&
                                    $0.source != pass.target
                            },
                            "pass \(index) has an invalid material texture"
                        )
                    }
                } else {
                    try require(
                        draw.vertexCount > 0 && draw.vertexStride > 0 && draw.vertexCount <= draw
                            .vertices.count / draw.vertexStride,
                        "pass \(index) has invalid vertex data"
                    )
                }
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
                case .audioSpectrum:
                    let count = update.components ?? 0
                    let stride = update.stride ?? 0
                    try require(
                        [16, 32, 64].contains(count) && ["left", "right"].contains(update.key ?? "")
                            && stride >= 4 && stride <= 64,
                        "invalid audio spectrum uniform update"
                    )
                    bytes = (count - 1) * stride + 4
                }
                try require(
                    update.offset >= 0 && update.offset <= stage.uniforms.count - bytes,
                    "uniform update is outside its buffer"
                )
                if update.value == .textureSize {
                    try require(
                        update.texture.map { resources.contains($0) || ($0.hasPrefix("slot:") && draw.dynamic != nil) } == true,
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

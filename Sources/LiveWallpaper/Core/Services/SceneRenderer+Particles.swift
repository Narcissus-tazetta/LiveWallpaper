import Foundation
import Metal
import simd

extension SceneRenderer {
    // MARK: - Particles

    private struct ParticleUniforms {
        var direction: SIMD2<Float>
        var cursor: SIMD2<Float>
        var color: SIMD4<Float>
        var phase: Float
        var aspect: Float
        var size: Float
        var sway: Float
        var opacity: Float
        var pixelHeight: Float
        var count: Int32
        var cycles: Int32
        var preset: Int32
        var hasCursor: Int32
        var cursorMode: Int32
        var hasMask: Int32
        var seed: Int32
        var travels: Int32
    }

    /// Draws the particles into a transparent texture the size of the canvas on the
    /// target, which then goes through the layer's effects and composite like an image.
    func renderParticles(
        _ particles: SceneParticles,
        layerID: UUID,
        commandBuffer: MTLCommandBuffer,
        input: SceneFrameInput,
        targetSize: SIMD2<Float>
    ) throws -> MTLTexture {
        // The whole canvas at the zoomed-in density, within texture limits.
        var canvasSize = targetSize / SIMD2(input.viewport.z, input.viewport.w)
        canvasSize *= min(1, Float(Self.maxTextureEdge) / max(canvasSize.x, canvasSize.y))
        // Glows are soft, so half the resolution looks the same at a quarter of the cost.
        let size = particles.preset.isAdditive ? canvasSize * 0.5 : canvasSize
        let width = max(Int(size.x.rounded()), 16)
        let height = max(Int(size.y.rounded()), 16)
        let target: MTLTexture
        if let existing = particleTargets[layerID], existing.width == width,
           existing.height == height
        {
            target = existing
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw RendererError.textureAllocationFailed
            }
            particleTargets[layerID] = texture
            target = texture
        }

        let radians = Float(particles.direction * .pi / 180)
        let color = particles.color
        let override = paintOverride?.effectID == layerID ? paintOverride : nil
        let mask = override?.target == .mask ? paintOverrideTexture : particles.maskFile
            .flatMap { maskTextures[$0] }
        var uniforms = ParticleUniforms(
            direction: SIMD2(cos(radians), -sin(radians)),
            cursor: input.cursor ?? .zero,
            color: SIMD4(
                Float(color.red),
                Float(color.green),
                Float(color.blue),
                Float(color.alpha)
            ),
            phase: loopPhase(input.time),
            aspect: Float(document.aspectRatio),
            size: Float(min(max(particles.size, 0), 1)),
            sway: Float(min(max(particles.sway, 0), 1)),
            opacity: Float(min(max(particles.opacity, 0), 1)),
            pixelHeight: Float(height),
            count: Int32(min(
                max(particles.count, SceneParticles.countRange.lowerBound),
                SceneParticles.countRange.upperBound
            )),
            cycles: Int32(min(
                max(particles.cycles, SceneEffect.cyclesRange.lowerBound),
                SceneEffect.cyclesRange.upperBound
            )),
            preset: Int32(SceneParticlePreset.allCases.firstIndex(of: particles.preset) ?? 0),
            hasCursor: input.cursor == nil || particles.cursorMode == .none ? 0 : 1,
            cursorMode: particles.cursorMode == .attract ? 1 : 0,
            hasMask: mask == nil ? 0 : 1,
            seed: Int32(truncatingIfNeeded: particles.seed),
            travels: particles.preset.travels ? 1 : 0
        )
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw RendererError.textureAllocationFailed
        }
        encoder
            .setRenderPipelineState(particles.preset.isAdditive ? pipeline.particlesAdd : pipeline
                .particlesOver)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ParticleUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ParticleUniforms>.stride, index: 0)
        encoder.setVertexTexture(mask ?? whiteMask, index: 0)
        encoder.drawPrimitives(
            type: .triangleStrip,
            vertexStart: 0,
            vertexCount: 4,
            instanceCount: Int(uniforms.count)
        )
        encoder.endEncoding()
        return target
    }

    // MARK: - Simulated particles

    /// A longer gap (a pause, a hidden window) continues as if one short frame passed.
    private static let longestParticleStep = 0.1

    private struct ParticleSystemUniforms {
        var column0: SIMD2<Float>
        var column1: SIMD2<Float>
        var origin: SIMD2<Float>
        /// Canvas UV → the background texture's UV (the editor's zoom).
        var viewOrigin: SIMD2<Float>
        var viewSize: SIMD2<Float>
        var canvasSize: SIMD2<Float>
        var brightness: Float
        var refractAmount: Float
        var blend: Int32
        var refracts: Int32
        var hasNormal: Int32
        var cuts: Int32
        var cutoutStart: Float
        var cutoutEnd: Float
        var cutoutOpacity: Float
        var padding: Float = 0
    }

    /// Keeps what a script asked of the particles in a frame that will not be drawn
    /// (the previous one is still on the GPU), so the next frame carries it out.
    func holdParticleControls(from frame: SceneEvaluatedFrame) {
        for (id, control) in frame.particleControls {
            pendingParticleControls[id, default: .init()].append(control)
        }
    }

    /// Runs the particles `seconds` ahead in frames of `fps`, so a bake starts with
    /// them already spread out instead of just born.
    func warmUpParticles(seconds: Double, fps: Int) {
        let step = 1 / Double(max(fps, 1))
        for layer in document.layers {
            guard layer.kind == .particles, let system = layer.particleSystem else { continue }
            let simulator = particleSimulator(for: layer, system: system)
            var remaining = seconds
            while remaining > 1e-9 {
                simulator.advance(by: min(step, remaining), surroundings: .init())
                remaining -= step
            }
        }
    }

    /// Seconds a bake should run its particles before its first frame: until the
    /// longest-lived ones have come and gone once.
    var particleWarmUpSeconds: Double {
        min(document.layers.compactMap(\.particleSystem).map(\.longestLifetime).max() ?? 0, 60)
    }

    private func particleSimulator(
        for layer: SceneLayer,
        system: SceneParticleSystem
    ) -> SceneParticleSimulator {
        if let existing = particleSimulators[layer.id],
           existing.system == system { return existing }
        let bytes = layer.id.uuid
        let seed = [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7]
            .reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let simulator = SceneParticleSimulator(system: system, seed: seed)
        particleSimulators[layer.id] = simulator
        return simulator
    }

    func advanceParticles(_ evaluated: SceneEvaluatedFrame, input: SceneFrameInput) {
        var dt = 0.0
        if let previous = particleTime {
            dt = input.time - previous
            // A loop (the editor's preview) starts over; its particles carry on.
            if !input.isRealTime, dt < 0 { dt += Double(max(document.loopSeconds, 1)) }
        }
        particleTime = input.time
        dt = min(max(dt, 0), Self.longestParticleStep)
        for layer in document.layers {
            guard layer.kind == .particles, let system = layer.particleSystem else { continue }
            let simulator = particleSimulator(for: layer, system: system)
            var control = pendingParticleControls.removeValue(forKey: layer.id) ?? .init()
            if let requested = evaluated.particleControls[layer.id] { control.append(requested) }
            let toCanvas = particleLocalToCanvas(evaluated.layers[layer.id]?.transform ?? layer
                .transform)
            var surroundings = SceneParticleSimulator.Surroundings()
            surroundings.audio = input.audio
            let determinant = simd_determinant(toCanvas)
            if abs(determinant) > 1e-12 {
                let toLayer = simd_inverse(toCanvas)
                func local(_ uv: SIMD2<Float>) -> SIMD3<Double> {
                    let point = toLayer * SIMD3(uv.x, uv.y, 1)
                    return SIMD3(Double(point.x), Double(point.y), 0)
                }
                surroundings.pointer = input.cursor.map(local)
                surroundings.canvasCorner = local(SIMD2(0, 1))
            }
            simulator.advance(by: dt, surroundings: surroundings)
            simulator.apply(control)
        }
    }

    /// The layer's pixels (y up, origin at the layer's position) → canvas UV.
    func particleLocalToCanvas(_ transform: SceneTransform) -> simd_float3x3 {
        let width = Float(document.canvasWidth)
        let height = Float(document.canvasHeight)
        let radians = Float(transform.rotation * .pi / 180)
        let c = cos(radians)
        let s = sin(radians)
        let scaleX = Float(transform.scale)
        let scaleY = Float(transform.scaleY ?? transform.scale)
        // The rotation turns clockwise on the canvas.
        return simd_float3x3(columns: (
            SIMD3(scaleX * c / width, scaleX * s / height, 0),
            SIMD3(scaleY * s / width, -scaleY * c / height, 0),
            SIMD3(0.5 + Float(transform.offsetX), 0.5 + Float(transform.offsetY), 1)
        ))
    }

    /// Draws the particles already placed on a transparent texture the size of the
    /// canvas on the target, which then goes through the layer's effects and composite.
    func renderParticleSystem(
        _ layer: SceneLayer,
        commandBuffer: MTLCommandBuffer,
        input: SceneFrameInput,
        targetSize: SIMD2<Float>,
        background: MTLTexture
    ) throws -> MTLTexture {
        var canvasSize = targetSize / SIMD2(input.viewport.z, input.viewport.w)
        canvasSize *= min(1, Float(Self.maxTextureEdge) / max(canvasSize.x, canvasSize.y))
        let width = max(Int(canvasSize.x.rounded()), 16)
        let height = max(Int(canvasSize.y.rounded()), 16)
        // A wide canvas keeps sprites brightened past white.
        let format: MTLPixelFormat = document.highDynamicRange ? .rgba16Float : .rgba8Unorm
        let target: MTLTexture
        if let existing = particleTargets[layer.id], existing.width == width,
           existing.height == height,
           existing.pixelFormat == format
        {
            target = existing
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw RendererError.textureAllocationFailed
            }
            particleTargets[layer.id] = texture
            target = texture
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw RendererError.textureAllocationFailed
        }
        defer { encoder.endEncoding() }
        guard let simulator = particleSimulators[layer.id] else { return target }
        let toCanvas = particleLocalToCanvas(currentTransform(layerID: layer.id) ?? layer.transform)
        let wide = format == .rgba16Float
        try simulator.forEach { node in
            let system = node.system
            let texture = system.textureFile.flatMap { particleTextures[$0] } ?? whiteTexture
            var aspect = Double(texture.height) / Double(max(texture.width, 1))
            if let sheet = system.sheet, sheet.columns > 0, sheet.rows > 0 {
                aspect *= Double(sheet.columns) / Double(sheet.rows)
            }
            let instances = node.instances(aspect: aspect)
            guard !instances.isEmpty else { return }
            let buffer = try particleInstanceBuffers.upload(instances, device: device)
            let normal = system.refraction?.normalFile.flatMap { particleTextures[$0] }
            var uniforms = ParticleSystemUniforms(
                column0: SIMD2(toCanvas.columns.0.x, toCanvas.columns.0.y),
                column1: SIMD2(toCanvas.columns.1.x, toCanvas.columns.1.y),
                origin: SIMD2(toCanvas.columns.2.x, toCanvas.columns.2.y),
                viewOrigin: SIMD2(input.viewport.x, input.viewport.y),
                viewSize: SIMD2(input.viewport.z, input.viewport.w),
                canvasSize: SIMD2(Float(document.canvasWidth), Float(document.canvasHeight)),
                brightness: Float(system.brightness),
                refractAmount: Float(system.refraction?.amount ?? 0),
                blend: Int32(SceneParticleSystem.Blend.allCases.firstIndex(of: system.blend)!),
                refracts: system.refraction == nil ? 0 : 1,
                hasNormal: normal == nil ? 0 : 1,
                cuts: system.cutout == nil ? 0 : 1,
                cutoutStart: Float(system.cutout?.start ?? 0),
                cutoutEnd: Float(system.cutout?.end ?? 0),
                cutoutOpacity: Float(system.cutout?.opacity ?? 1)
            )
            let additive = system.blend == .add
            encoder.setRenderPipelineState(wide
                ? (additive ? pipeline.particleSystemAddWide : pipeline.particleSystemOverWide)
                : (additive ? pipeline.particleSystemAdd : pipeline.particleSystemOver))
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<ParticleSystemUniforms>.stride,
                index: 1
            )
            encoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<ParticleSystemUniforms>.stride,
                index: 1
            )
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentTexture(background, index: 1)
            encoder.setFragmentTexture(normal ?? whiteTexture, index: 2)
            encoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: instances.count
            )
        }
        return target
    }

    func mipmapped(_ texture: MTLTexture) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height,
            mipmapped: true
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        guard let copy = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder()
        else {
            throw RendererError.textureAllocationFailed
        }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: copy, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin()
        )
        blit.generateMipmaps(for: copy)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return copy
    }

    func loopPhase(_ time: Double) -> Float {
        let loop = Double(max(document.loopSeconds, 1))
        return Float((time.truncatingRemainder(dividingBy: loop) + loop)
            .truncatingRemainder(dividingBy: loop) / loop)
    }
}

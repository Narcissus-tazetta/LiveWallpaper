import CoreGraphics
import Foundation
import ImageIO
import Metal

/// What changes from frame to frame. Positions are in canvas UV space (origin top-left).
struct SceneFrameInput: Equatable {
    /// -1...1 per axis, already eased; positive x/y move the sampled area right/down.
    var parallax: SIMD2<Float> = .zero
    /// nil when no cursor masks should react (cursor elsewhere, or not allowed).
    var cursor: SIMD2<Float>?
    /// Seconds into the scene loop.
    var time: Double = 0

    static let rest = SceneFrameInput()
}

/// A mask or flow map being painted, shown before it is saved to a file.
struct ScenePaintOverride {
    enum Target: Equatable {
        case mask
        case flow
    }

    let effectID: UUID
    let target: Target
    let width: Int
    let height: Int
    /// 1 byte per pixel for a mask, RGBA for a flow map.
    let bytes: [UInt8]
}

/// Draws a SceneDocument with Metal. Each layer first runs through its effects (one
/// pass each, in the layer's own UV space so masks and centres stay attached to the
/// picture), then is composited in its own pass onto a ping-pong pair of textures,
/// so every blend mode can read what is below it on any GPU (no framebuffer fetch).
/// The same code renders the live wallpaper, the editor preview and the baked video.
///
/// Not tied to the main thread: baking creates its own instance on a background task.
/// An instance must stay on the thread that uses it.
final class SceneRenderer {
    enum RendererError: LocalizedError {
        case metalUnavailable
        case shaderCompilationFailed(String)
        case imageDecodeFailed(String)
        case textureAllocationFailed

        var errorDescription: String? {
            switch self {
            case .metalUnavailable:
                return "Metal is unavailable"
            case let .shaderCompilationFailed(message):
                return "Scene shader failed to compile: \(message)"
            case let .imageDecodeFailed(name):
                return "Could not decode scene image \(name)"
            case .textureAllocationFailed:
                return "Could not allocate a scene texture"
            }
        }
    }

    /// Longest edge a layer is decoded at; larger images only cost memory.
    static let maxTextureEdge = 4096
    /// Fraction of the canvas a depth-1 layer can travel each way.
    static let maxParallaxTravel: Float = 0.05

    private struct Pipeline {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let composite: MTLRenderPipelineState
        let effect: MTLRenderPipelineState
        let particlesOver: MTLRenderPipelineState
        let particlesAdd: MTLRenderPipelineState
        /// Single-pass compositing; nil where the GPU cannot read its framebuffer.
        let compositeFetch: MTLRenderPipelineState?
    }

    private static let pipelineLock = NSLock()
    private nonisolated(unsafe) static var sharedPipeline: Pipeline?

    /// Decoded layer images shared by every renderer alive (the editor preview, each
    /// desktop, the baker): decoding a large photo takes seconds and renderers are
    /// recreated on the main thread. Weak, so an image is freed with its last user.
    private final class TextureCacheEntry {
        weak var texture: MTLTexture?

        init(_ texture: MTLTexture) {
            self.texture = texture
        }
    }

    private static let textureCacheLock = NSLock()
    private nonisolated(unsafe) static var textureCache: [String: TextureCacheEntry] = [:]

    private let pipeline: Pipeline
    private(set) var document: SceneDocument
    private let videoPath: String
    private var textures: [String: MTLTexture] = [:]
    private var maskTextures: [String: MTLTexture] = [:]
    private var flowTextures: [String: MTLTexture] = [:]
    private var effectTargets: [UUID: [MTLTexture]] = [:]
    private var particleTargets: [UUID: MTLTexture] = [:]
    private var accumulation: [MTLTexture] = []
    private let blackTexture: MTLTexture
    private let whiteMask: MTLTexture
    private let stillFlow: MTLTexture
    /// Fraction of the displayed size that effects are computed at. The baked video
    /// uses full resolution.
    var effectResolutionScale: Float = 1
    /// Off forces the ping-pong composite that other GPUs use.
    var allowsSinglePassComposite = true
    /// Loop phase of the last encoded frame, for mapping preview clicks.
    private var lastPhase: Double = 0
    private var paintOverride: ScenePaintOverride?
    private var paintOverrideTexture: MTLTexture?

    var device: MTLDevice {
        pipeline.device
    }

    var commandQueue: MTLCommandQueue {
        pipeline.queue
    }

    init(document: SceneDocument, videoPath: String) throws {
        pipeline = try Self.makePipeline()
        self.document = document
        self.videoPath = videoPath
        blackTexture = try Self.makeSolidTexture(device: pipeline.device, pixelFormat: .rgba8Unorm, bytes: [0, 0, 0, 255])
        whiteMask = try Self.makeSolidTexture(device: pipeline.device, pixelFormat: .r8Unorm, bytes: [255])
        stillFlow = try Self.makeSolidTexture(device: pipeline.device, pixelFormat: .rgba8Unorm, bytes: [128, 128, 0, 255])
        try loadTextures()
    }

    func update(document: SceneDocument) throws {
        self.document = document
        try loadTextures()
    }

    var usesCursor: Bool {
        document.usesCursor
    }

    /// Shows `override` in place of that effect's saved mask or flow map, with a tint
    /// marking where it is painted. nil goes back to the saved files.
    func setPaintOverride(_ override: ScenePaintOverride?) throws {
        paintOverride = override
        guard let override else {
            paintOverrideTexture = nil
            return
        }
        let format: MTLPixelFormat = override.target == .mask ? .r8Unorm : .rgba8Unorm
        if let texture = paintOverrideTexture, texture.width == override.width, texture.height == override.height,
           texture.pixelFormat == format
        {
            texture.replace(
                region: MTLRegionMake2D(0, 0, override.width, override.height), mipmapLevel: 0,
                withBytes: override.bytes, bytesPerRow: override.width * (format == .r8Unorm ? 1 : 4)
            )
            return
        }
        paintOverrideTexture = try Self.makeTexture(
            device: device, pixelFormat: format, width: override.width, height: override.height, bytes: override.bytes
        )
    }

    /// Canvas UV → the layer's UV with the layer at rest (no parallax travel).
    func layerUV(canvasUV: SIMD2<Float>, layerID: UUID) -> SIMD2<Float>? {
        guard let layer = document.layers.first(where: { $0.id == layerID }) else {
            return nil
        }
        let placement = placement(for: layer.pose(at: lastPhase).transform)
        let relative = canvasUV - 0.5 - placement.offset
        let placed = placement.column0 * relative.x + placement.column1 * relative.y + 0.5
        return (placed - 0.5) * layerUVScale(for: layer) + 0.5
    }

    /// Layer UV → canvas UV, the inverse of layerUV(canvasUV:layerID:); for markers
    /// drawn over the preview.
    func canvasUV(layerUV: SIMD2<Float>, layerID: UUID) -> SIMD2<Float>? {
        guard let layer = document.layers.first(where: { $0.id == layerID }) else {
            return nil
        }
        let transform = layer.pose(at: lastPhase).transform
        let placed = (layerUV - 0.5) / layerUVScale(for: layer)
        let aspect = Float(document.aspectRatio)
        let radians = Float(transform.rotation * .pi / 180)
        let c = cos(radians)
        let s = sin(radians)
        let scale = Float(transform.scale)
        let column0 = SIMD2(c, s * aspect) * scale
        let column1 = SIMD2(-s / aspect, c) * scale
        return column0 * placed.x + column1 * placed.y + 0.5 + SIMD2(Float(transform.offsetX), Float(transform.offsetY))
    }

    /// Encodes the scene into `target` (bgra8Unorm, renderTarget usage).
    func encode(into target: MTLTexture, commandBuffer: MTLCommandBuffer, input: SceneFrameInput) throws {
        lastPhase = Double(loopPhase(input.time))
        let targetSize = SIMD2(Float(target.width), Float(target.height))
        let visible = document.layers.filter { layer in
            layer.isVisible && (layer.kind == .particles ? layer.particles != nil : textures[layer.imageFile] != nil)
        }
        // Effects and particles render into their own textures first, so the
        // composite can then run as a single pass.
        var prepared: [PreparedLayer] = []
        for layer in visible {
            let layerTexture = try applyEffects(
                to: layer, commandBuffer: commandBuffer, input: input, targetSize: targetSize
            )
            prepared.append(PreparedLayer(
                layerTexture: layerTexture,
                uniforms: compositeUniforms(for: layer, input: input, targetSize: targetSize),
                depth: layer.depthFile.flatMap { maskTextures[$0] }
            ))
        }

        if allowsSinglePassComposite, let fetch = pipeline.compositeFetch {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw RendererError.textureAllocationFailed
            }
            encoder.setRenderPipelineState(fetch)
            for item in prepared {
                var uniforms = item.uniforms
                encoder.setFragmentTexture(item.layerTexture, index: 1)
                encoder.setFragmentTexture(item.depth ?? whiteMask, index: 2)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            encoder.endEncoding()
            return
        }

        try ensureAccumulation(width: target.width, height: target.height)
        var source = blackTexture
        var nextIndex = 0
        for item in prepared {
            let destination = accumulation[nextIndex]
            try compositePass(
                commandBuffer: commandBuffer, destination: destination, base: source,
                layerTexture: item.layerTexture, uniforms: item.uniforms, depth: item.depth
            )
            source = destination
            nextIndex = 1 - nextIndex
        }
        try compositePass(
            commandBuffer: commandBuffer, destination: target, base: source,
            layerTexture: blackTexture, uniforms: Self.passThroughUniforms
        )
    }

    private struct PreparedLayer {
        let layerTexture: MTLTexture
        let uniforms: LayerUniforms
        let depth: MTLTexture?
    }

    /// The scene at rest (no cursor, loop start), at canvas resolution capped like the layers.
    func renderStill() throws -> CGImage {
        let (width, height) = Self.outputSize(for: document, maxEdge: Self.maxTextureEdge)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let target = device.makeTexture(descriptor: descriptor),
              let commandBuffer = pipeline.queue.makeCommandBuffer()
        else {
            throw RendererError.textureAllocationFailed
        }
        try encode(into: target, commandBuffer: commandBuffer, input: .rest)
        if target.storageMode == .managed, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw error
        }

        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        target.getBytes(&bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              )
        else {
            throw RendererError.textureAllocationFailed
        }
        return image
    }

    /// Even dimensions (video encoders need them), longest edge at most `maxEdge`.
    static func outputSize(for document: SceneDocument, maxEdge: Int) -> (Int, Int) {
        let scale = min(1, Double(maxEdge) / Double(max(document.canvasWidth, document.canvasHeight, 1)))
        func even(_ value: Double) -> Int {
            max(Int((value / 2).rounded()) * 2, 2)
        }
        return (even(Double(document.canvasWidth) * scale), even(Double(document.canvasHeight) * scale))
    }

    // MARK: - Effects

    private struct EffectUniforms {
        var center: SIMD2<Float>
        var direction: SIMD2<Float>
        var scrollStep: SIMD2<Float>
        var phase: Float
        var strength: Float
        var scale: Float
        var aspect: Float
        var kind: Int32
        var cycles: Int32
        var reversed: Int32
        var overlay: Int32
        var hasMask: Int32
    }

    /// Runs the layer's effects and returns the texture to composite.
    private func applyEffects(
        to layer: SceneLayer,
        commandBuffer: MTLCommandBuffer,
        input: SceneFrameInput,
        targetSize: SIMD2<Float>
    ) throws -> MTLTexture {
        let source: MTLTexture
        if layer.kind == .particles, let particles = layer.particles {
            source = try renderParticles(
                particles, layerID: layer.id, commandBuffer: commandBuffer, input: input, targetSize: targetSize
            )
        } else if let image = textures[layer.imageFile] {
            source = image
        } else {
            return blackTexture
        }
        var effects = layer.activeEffects
        // While a particle area is painted, an effect pass that changes nothing
        // tints the painted part like an effect mask.
        if layer.kind == .particles, paintOverride?.effectID == layer.id {
            var marker = SceneEffect(kind: .pulse)
            marker.id = layer.id
            marker.strength = 0
            effects.append(marker)
        }
        guard !effects.isEmpty else {
            return source
        }
        // Half the layer's size on the target (never above its own resolution): the
        // distortions are smooth, and this pass is most of the GPU time.
        let shown = targetSize / layerUVScale(for: layer) * effectResolutionScale
        let width = max(min(Int(shown.x.rounded()), source.width), 16)
        let height = max(min(Int(shown.y.rounded()), source.height), 16)
        let targets = try effectTextures(for: layer.id, width: width, height: height)

        let phase = loopPhase(input.time)
        let aspect = Float(source.width) / Float(max(source.height, 1))
        var current = source
        for (index, effect) in effects.enumerated() {
            let destination = targets[index % 2]
            let override = paintOverride?.effectID == effect.id ? paintOverride : nil
            let mask = override?.target == .mask ? paintOverrideTexture : effect.maskFile.flatMap { maskTextures[$0] }
            let flow = override?.target == .flow ? paintOverrideTexture : effect.flowFile.flatMap { flowTextures[$0] }
            let radians = Float(effect.direction * .pi / 180)
            // UV y points down, the direction angle counts counter-clockwise with y up.
            let direction = SIMD2<Float>(cos(radians), -sin(radians))
            var uniforms = EffectUniforms(
                center: SIMD2(Float(effect.centerX), Float(effect.centerY)),
                direction: direction,
                // Scrolling must land on whole wraps each cycle to loop, so it moves
                // in one of eight directions.
                scrollStep: SIMD2(direction.x.rounded(), direction.y.rounded()),
                phase: phase,
                strength: Float(min(max(effect.strength, 0), 1)),
                scale: Float(min(max(effect.scale, 0), 1)),
                aspect: aspect,
                kind: Int32(SceneEffectKind.allCases.firstIndex(of: effect.kind) ?? 0),
                cycles: Int32(min(max(effect.cycles, SceneEffect.cyclesRange.lowerBound), SceneEffect.cyclesRange.upperBound)),
                reversed: effect.reversed ? 1 : 0,
                overlay: override == nil ? 0 : (override?.target == .mask ? 1 : 2),
                hasMask: mask == nil ? 0 : 1
            )
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = destination
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw RendererError.textureAllocationFailed
            }
            encoder.setRenderPipelineState(pipeline.effect)
            encoder.setFragmentTexture(current, index: 0)
            encoder.setFragmentTexture(mask ?? whiteMask, index: 1)
            encoder.setFragmentTexture(flow ?? stillFlow, index: 2)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<EffectUniforms>.stride, index: 0)
            var pins = puppetPins(effect, phase: phase, aspect: aspect)
            encoder.setFragmentBytes(&pins, length: MemoryLayout<SIMD4<Float>>.stride * pins.count, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            current = destination
        }
        return current
    }

    /// What the puppet pass reads: element 0 holds the pin count in x, then one
    /// (position, displacement) per pin in the effect's height-1 space. Swinging pins
    /// swing a whole number of times per loop.
    private func puppetPins(_ effect: SceneEffect, phase: Float, aspect: Float) -> [SIMD4<Float>] {
        var result = [SIMD4<Float>](repeating: .zero, count: ScenePin.maximumCount + 1)
        guard effect.kind == .puppet else {
            return result
        }
        let pins = effect.pins.prefix(ScenePin.maximumCount)
        for (index, pin) in pins.enumerated() {
            var displacement = SIMD2<Float>.zero
            if !pin.isAnchor {
                let radians = Float(pin.direction * .pi / 180)
                let swing = sin(2 * Float.pi * (Float(effect.cycles) * phase + Float(pin.phase)))
                displacement = SIMD2(cos(radians), -sin(radians)) * Float(min(max(pin.amount, 0), 1)) * 0.06 * swing
            }
            result[index + 1] = SIMD4(Float(pin.x) * aspect, Float(pin.y), displacement.x, displacement.y)
        }
        result[0] = SIMD4(Float(pins.count), 0, 0, 0)
        return result
    }

    private func effectTextures(for layerID: UUID, width: Int, height: Int) throws -> [MTLTexture] {
        if let existing = effectTargets[layerID], existing[0].width == width, existing[0].height == height {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let first = device.makeTexture(descriptor: descriptor),
              let second = device.makeTexture(descriptor: descriptor)
        else {
            throw RendererError.textureAllocationFailed
        }
        effectTargets[layerID] = [first, second]
        return [first, second]
    }

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
    private func renderParticles(
        _ particles: SceneParticles,
        layerID: UUID,
        commandBuffer: MTLCommandBuffer,
        input: SceneFrameInput,
        targetSize: SIMD2<Float>
    ) throws -> MTLTexture {
        // Glows are soft, so half the resolution looks the same at a quarter of the cost.
        let size = particles.preset.isAdditive ? targetSize * 0.5 : targetSize
        let width = max(Int(size.x.rounded()), 16)
        let height = max(Int(size.y.rounded()), 16)
        let target: MTLTexture
        if let existing = particleTargets[layerID], existing.width == width, existing.height == height {
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
        let mask = override?.target == .mask ? paintOverrideTexture : particles.maskFile.flatMap { maskTextures[$0] }
        var uniforms = ParticleUniforms(
            direction: SIMD2(cos(radians), -sin(radians)),
            cursor: input.cursor ?? .zero,
            color: SIMD4(Float(color.red), Float(color.green), Float(color.blue), Float(color.alpha)),
            phase: loopPhase(input.time),
            aspect: Float(document.aspectRatio),
            size: Float(min(max(particles.size, 0), 1)),
            sway: Float(min(max(particles.sway, 0), 1)),
            opacity: Float(min(max(particles.opacity, 0), 1)),
            pixelHeight: Float(height),
            count: Int32(min(max(particles.count, SceneParticles.countRange.lowerBound), SceneParticles.countRange.upperBound)),
            cycles: Int32(min(max(particles.cycles, SceneEffect.cyclesRange.lowerBound), SceneEffect.cyclesRange.upperBound)),
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
        encoder.setRenderPipelineState(particles.preset.isAdditive ? pipeline.particlesAdd : pipeline.particlesOver)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ParticleUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ParticleUniforms>.stride, index: 0)
        encoder.setVertexTexture(mask ?? whiteMask, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: Int(uniforms.count))
        encoder.endEncoding()
        return target
    }

    private func loopPhase(_ time: Double) -> Float {
        let loop = Double(max(document.loopSeconds, 1))
        return Float((time.truncatingRemainder(dividingBy: loop) + loop).truncatingRemainder(dividingBy: loop) / loop)
    }

    // MARK: - Composite

    private struct LayerUniforms {
        var uvScale: SIMD2<Float>
        var uvOffset: SIMD2<Float>
        var cursor: SIMD2<Float>
        var maskScale: SIMD2<Float>
        /// Layer UV shift of the nearest pixels; the farthest move the opposite way.
        var depthShift: SIMD2<Float>
        /// Canvas UV → the layer's untransformed canvas UV (inverse of its placement).
        var placementColumn0: SIMD2<Float>
        var placementColumn1: SIMD2<Float>
        var placementOffset: SIMD2<Float>
        var hasDepth: Int32
        var depthSteps: Int32
        var opacity: Float
        var maskRadius: Float
        var maskSoftness: Float
        var blendMode: Int32
        var maskMode: Int32
        var hasCursor: Int32
        var hasLayer: Int32
    }

    private func compositePass(
        commandBuffer: MTLCommandBuffer,
        destination: MTLTexture,
        base: MTLTexture,
        layerTexture: MTLTexture,
        uniforms: LayerUniforms,
        depth: MTLTexture? = nil
    ) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw RendererError.textureAllocationFailed
        }
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline.composite)
        encoder.setFragmentTexture(base, index: 0)
        encoder.setFragmentTexture(layerTexture, index: 1)
        encoder.setFragmentTexture(depth ?? whiteMask, index: 2)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private static let passThroughUniforms = LayerUniforms(
        uvScale: .one, uvOffset: .zero, cursor: .zero, maskScale: .one, depthShift: .zero,
        placementColumn0: SIMD2(1, 0), placementColumn1: SIMD2(0, 1), placementOffset: .zero, hasDepth: 0,
        depthSteps: 0,
        opacity: 0, maskRadius: 0,
        maskSoftness: 0, blendMode: 0, maskMode: -1, hasCursor: 0, hasLayer: 0
    )

    /// Canvas UV → layer UV scale: aspect-fit, zoomed in just enough that the full
    /// parallax travel never samples past the edge. A cut-out of another shape keeps
    /// its size and proportions (the area outside it stays transparent).
    private func layerUVScale(for layer: SceneLayer) -> SIMD2<Float> {
        let canvasAspect = Float(document.aspectRatio)
        let layerAspect: Float
        if layer.kind == .particles {
            layerAspect = canvasAspect
        } else {
            let texture = textures[layer.imageFile]
            layerAspect = Float(texture?.width ?? 1) / Float(max(texture?.height ?? 1, 1))
        }
        let scale = layerAspect > canvasAspect
            ? SIMD2<Float>(1, layerAspect / canvasAspect)
            : SIMD2<Float>(canvasAspect / layerAspect, 1)
        return scale / (1 + 2 * parallaxTravel(for: layer))
    }

    /// How far the layer can move each way, as a fraction of the canvas: the cursor
    /// parallax, and the depth shift (nearest and farthest pixels move half of it).
    private func parallaxTravel(for layer: SceneLayer) -> Float {
        let cursorTravel = Float(min(max(layer.parallaxDepth, 0), 1)) * Self.maxParallaxTravel
        return max(cursorTravel, depthTravel(for: layer))
    }

    private func depthTravel(for layer: SceneLayer) -> Float {
        layer.hasDepth ? Float(min(max(layer.depthStrength, 0), 1)) * Self.maxParallaxTravel : 0
    }

    private struct Placement {
        let column0: SIMD2<Float>
        let column1: SIMD2<Float>
        let offset: SIMD2<Float>
    }

    /// The inverse of the layer's placement in canvas UV. Rotation happens in a space
    /// with the canvas's proportions, so a turned layer is not skewed.
    private func placement(for transform: SceneTransform) -> Placement {
        let aspect = Float(document.aspectRatio)
        let radians = Float(transform.rotation * .pi / 180)
        let c = cos(radians)
        let s = sin(radians)
        let inverseScale = 1 / Float(max(transform.scale, 0.01))
        return Placement(
            column0: SIMD2(c, -s * aspect) * inverseScale,
            column1: SIMD2(s / aspect, c) * inverseScale,
            offset: SIMD2(Float(transform.offsetX), Float(transform.offsetY))
        )
    }

    /// About one step per 10 pixels the march covers on screen; the linear
    /// refinement between steps keeps edges in place, and small shifts need few.
    private func depthSteps(shift: SIMD2<Float>, scale: SIMD2<Float>, targetSize: SIMD2<Float>) -> Int32 {
        let pixels = shift / scale * targetSize
        let sweep = 2 * max(abs(pixels.x), abs(pixels.y))
        return Int32(min(max((sweep / 10).rounded(.up), 4), 12))
    }

    private func compositeUniforms(
        for layer: SceneLayer,
        input: SceneFrameInput,
        targetSize: SIMD2<Float>
    ) -> LayerUniforms {
        let canvasAspect = Float(document.aspectRatio)
        let pose = layer.pose(at: Double(loopPhase(input.time)))
        let placement = placement(for: pose.transform)
        let scale = layerUVScale(for: layer)
        // The travel is a fraction of the canvas, converted into layer UV units.
        let cursorTravel = Float(min(max(layer.parallaxDepth, 0), 1)) * Self.maxParallaxTravel
        let offset = cursorTravel > 0 ? input.parallax * cursorTravel * scale : .zero
        var depthView = layer.depthFollowsCursor ? input.parallax : .zero
        if layer.depthAutoMotion > 0 {
            // A circle repeats every turn, so the drift loops.
            let angle = 2 * Float.pi * Float(max(layer.depthAutoCycles, 1)) * loopPhase(input.time)
            depthView += SIMD2(cos(angle), sin(angle) * 0.6) * Float(min(layer.depthAutoMotion, 1))
        }
        let depthShift = depthView.clamped(lowerBound: SIMD2(repeating: -1), upperBound: SIMD2(repeating: 1))
            * depthTravel(for: layer) * scale

        // Mask distances are measured in units of the canvas's shorter side.
        let maskScale = canvasAspect >= 1 ? SIMD2<Float>(canvasAspect, 1) : SIMD2<Float>(1, 1 / canvasAspect)
        let mask = layer.cursorMask
        return LayerUniforms(
            uvScale: scale,
            uvOffset: offset,
            cursor: input.cursor ?? .zero,
            maskScale: maskScale,
            depthShift: depthShift,
            placementColumn0: placement.column0,
            placementColumn1: placement.column1,
            placementOffset: placement.offset,
            hasDepth: layer.hasDepth && layer.depthFile.flatMap({ maskTextures[$0] }) != nil ? 1 : 0,
            depthSteps: depthSteps(shift: depthShift, scale: scale, targetSize: targetSize),
            opacity: Float(min(max(layer.opacity * pose.opacity, 0), 1)),
            maskRadius: Float(max(mask?.radius ?? 0, 0.001)),
            maskSoftness: Float(min(max(mask?.softness ?? 0, 0), 1)),
            blendMode: Int32(SceneBlendMode.allCases.firstIndex(of: layer.blendMode) ?? 0),
            maskMode: mask.map { $0.mode == .hide ? 0 : 1 } ?? -1,
            hasCursor: input.cursor == nil ? 0 : 1,
            hasLayer: 1
        )
    }

    // MARK: - Resources

    private func ensureAccumulation(width: Int, height: Int) throws {
        if let first = accumulation.first, first.width == width, first.height == height {
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let first = device.makeTexture(descriptor: descriptor),
              let second = device.makeTexture(descriptor: descriptor)
        else {
            throw RendererError.textureAllocationFailed
        }
        accumulation = [first, second]
    }

    private func loadTextures() throws {
        let layerIDs = Set(document.layers.map(\.id))
        effectTargets = effectTargets.filter { layerIDs.contains($0.key) }
        particleTargets = particleTargets.filter { layerIDs.contains($0.key) }

        let images = Set(document.layers.filter { $0.kind == .image }.map(\.imageFile))
        textures = textures.filter { images.contains($0.key) }
        for file in images where textures[file] == nil {
            textures[file] = try Self.cachedTexture(url: fileURL(file), variant: "rgba") { url in
                try Self.decodeRGBA(url: url, device: device)
            }
        }

        let effects = document.layers.flatMap(\.effects)
        let masks = Set(
            effects.compactMap(\.maskFile) + document.layers.compactMap { $0.particles?.maskFile }
                + document.layers.compactMap(\.depthFile)
        )
        maskTextures = maskTextures.filter { masks.contains($0.key) }
        for file in masks where maskTextures[file] == nil {
            maskTextures[file] = try Self.cachedTexture(url: fileURL(file), variant: "mask") { url in
                try Self.decodeMask(url: url, device: device)
            }
        }
        let flows = Set(effects.compactMap(\.flowFile))
        flowTextures = flowTextures.filter { flows.contains($0.key) }
        for file in flows where flowTextures[file] == nil {
            flowTextures[file] = try Self.cachedTexture(url: fileURL(file), variant: "flow") { url in
                try Self.decodeRGBA(url: url, device: device, premultiplied: false)
            }
        }
    }

    /// Keyed by the file's identity too: an imported package can replace a scene
    /// folder with files of the same names.
    private static func cachedTexture(
        url: URL,
        variant: String,
        decode: (URL) throws -> MTLTexture
    ) throws -> MTLTexture {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = [
            variant,
            url.standardizedFileURL.path,
            String(values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0),
            String(values.fileSize ?? 0)
        ].joined(separator: "|")
        textureCacheLock.lock()
        let cached = textureCache[key]?.texture
        textureCacheLock.unlock()
        if let cached {
            return cached
        }
        let texture = try decode(url)
        textureCacheLock.lock()
        textureCache = textureCache.filter { $0.value.texture != nil }
        textureCache[key] = TextureCacheEntry(texture)
        textureCacheLock.unlock()
        return texture
    }

    private func fileURL(_ name: String) -> URL {
        SceneStore.folderURL(forVideoPath: videoPath).appendingPathComponent(name)
    }

    /// Decodes into sRGB RGBA8 so the shader knows exactly what it samples, whatever
    /// the file's color space or alpha layout. Flow maps are data: an sRGB file read
    /// into an sRGB context comes back unchanged, and they are never premultiplied.
    private static func decodeRGBA(url: URL, device: MTLDevice, premultiplied: Bool = true) throws -> MTLTexture {
        let image = try decodeImage(url: url)
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let alpha: CGImageAlphaInfo = premultiplied ? .premultipliedLast : .noneSkipLast
        let drew: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: alpha.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else {
            throw RendererError.imageDecodeFailed(url.lastPathComponent)
        }
        return try makeTexture(device: device, pixelFormat: .rgba8Unorm, width: width, height: height, bytes: bytes)
    }

    private static func decodeMask(url: URL, device: MTLDevice) throws -> MTLTexture {
        let image = try decodeImage(url: url)
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drew: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpace(name: CGColorSpace.linearGray)!,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else {
            throw RendererError.imageDecodeFailed(url.lastPathComponent)
        }
        return try makeTexture(device: device, pixelFormat: .r8Unorm, width: width, height: height, bytes: bytes)
    }

    private static func decodeImage(url: URL) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxTextureEdge,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            throw RendererError.imageDecodeFailed(url.lastPathComponent)
        }
        return image
    }

    private static func makeTexture(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        bytes: [UInt8]
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RendererError.textureAllocationFailed
        }
        let bytesPerPixel = pixelFormat == .r8Unorm ? 1 : 4
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: bytes, bytesPerRow: width * bytesPerPixel
        )
        return texture
    }

    private static func makeSolidTexture(device: MTLDevice, pixelFormat: MTLPixelFormat, bytes: [UInt8]) throws -> MTLTexture {
        try makeTexture(device: device, pixelFormat: pixelFormat, width: 1, height: 1, bytes: bytes)
    }

    // Compiled from source at runtime: SwiftPM cannot build .metal files, and this
    // keeps macOS 13 support (runtime CIKernel sources need macOS 15).
    private static func makePipeline() throws -> Pipeline {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }
        if let sharedPipeline {
            return sharedPipeline
        }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RendererError.metalUnavailable
        }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            throw RendererError.shaderCompilationFailed(error.localizedDescription)
        }
        func state(
            vertex: String = "scene_vertex",
            fragment: String,
            format: MTLPixelFormat,
            additive: Bool? = nil
        ) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            if let additive {
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        var compositeFetch: MTLRenderPipelineState?
        if device.supportsFamily(.apple1) {
            let fetchLibrary = try device.makeLibrary(source: fetchShaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = fetchLibrary.makeFunction(name: "scene_vertex")
            descriptor.fragmentFunction = fetchLibrary.makeFunction(name: "scene_composite_fetch")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            compositeFetch = try device.makeRenderPipelineState(descriptor: descriptor)
        }
        let pipeline = try Pipeline(
            device: device, queue: queue,
            composite: state(fragment: "scene_composite", format: .bgra8Unorm),
            effect: state(fragment: "scene_effect", format: .rgba8Unorm),
            particlesOver: state(vertex: "particle_vertex", fragment: "particle_fragment", format: .rgba8Unorm, additive: false),
            particlesAdd: state(vertex: "particle_vertex", fragment: "particle_fragment", format: .rgba8Unorm, additive: true),
            compositeFetch: compositeFetch
        )
        sharedPipeline = pipeline
        return pipeline
    }

    /// Apple GPUs can read the pixel being drawn, so every layer is blended in one
    /// render pass without writing the canvas out between layers. Other GPUs cannot
    /// compile this.
    private static let fetchShaderSource = shaderSource + """

    fragment float4 scene_composite_fetch(VertexOut in [[stage_in]],
                                          float4 below [[color(0)]],
                                          texture2d<float> layer [[texture(1)]],
                                          texture2d<float> depth [[texture(2)]],
                                          constant LayerUniforms &u [[buffer(0)]]) {
        return float4(compositeLayer(below.rgb, in.uv, layer, depth, u), 1.0);
    }
    """

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut scene_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VertexOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(p.x, 1.0 - p.y);
        return out;
    }

    // MARK: composite

    struct LayerUniforms {
        float2 uvScale;
        float2 uvOffset;
        float2 cursor;
        float2 maskScale;
        float2 depthShift;
        float2 placementColumn0;
        float2 placementColumn1;
        float2 placementOffset;
        int hasDepth;
        int depthSteps;
        float opacity;
        float maskRadius;
        float maskSoftness;
        int blendMode;
        int maskMode;
        int hasCursor;
        int hasLayer;
    };

    float3 blend(int mode, float3 b, float3 s) {
        switch (mode) {
        case 1: return b * s;
        case 2: return 1.0 - (1.0 - b) * (1.0 - s);
        case 3: return select(1.0 - 2.0 * (1.0 - b) * (1.0 - s), 2.0 * b * s, b < 0.5);
        case 4: return min(b + s, 1.0);
        default: return s;
        }
    }

    float4 sampleInside(texture2d<float> t, sampler s, float2 uv) {
        float2 inside = step(0.0, uv) * step(uv, 1.0);
        return t.sample(s, uv) * inside.x * inside.y;
    }

    /// One layer over `below`: placement, depth, cursor mask and blend mode.
    float3 compositeLayer(float3 below, float2 uv, texture2d<float> layer, texture2d<float> depth,
                          constant LayerUniforms &u) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 relative = uv - 0.5 - u.placementOffset;
        float2 placed = u.placementColumn0 * relative.x + u.placementColumn1 * relative.y;
        float2 layerUV = placed * u.uvScale + 0.5 + u.uvOffset;
        if (u.hasDepth != 0) {
            // A source pixel at depth d shows up shifted by depthShift * (2d - 1).
            // March from the nearest possible depth to the farthest and take the
            // first surface that reaches this pixel, so near things cover far ones
            // (iterating a fixed point instead doubled edges where depth jumps).
            int steps = u.depthSteps;
            float previousT = 1.0;
            float previousF = depth.sample(s, layerUV - u.depthShift).r * 2.0 - 1.0 - 1.0;
            float hitT = -1.0;
            for (int i = 1; i <= steps; i++) {
                float t = 1.0 - 2.0 * float(i) / float(steps);
                float f = depth.sample(s, layerUV - u.depthShift * t).r * 2.0 - 1.0 - t;
                if (f >= 0.0) {
                    // Linear refinement between the last two steps.
                    hitT = mix(previousT, t, previousF / min(previousF - f, -1e-5));
                    break;
                }
                previousT = t;
                previousF = f;
            }
            layerUV = layerUV - u.depthShift * hitT;
        }
        float4 src = sampleInside(layer, s, layerUV);
        float alpha = src.a * u.opacity;
        float3 color = src.a > 0.0 ? src.rgb / src.a : float3(0.0);
        if (u.maskMode >= 0) {
            float near = 0.0;
            if (u.hasCursor != 0) {
                float dist = length((uv - u.cursor) * u.maskScale);
                float inner = u.maskRadius * (1.0 - u.maskSoftness);
                near = 1.0 - smoothstep(inner, u.maskRadius + 1e-4, dist);
            }
            alpha *= u.maskMode == 0 ? 1.0 - near : near;
        }
        float3 mixed = blend(u.blendMode, below, color);
        return mix(below, mixed, alpha);
    }

    fragment float4 scene_composite(VertexOut in [[stage_in]],
                                    texture2d<float> base [[texture(0)]],
                                    texture2d<float> layer [[texture(1)]],
                                    texture2d<float> depth [[texture(2)]],
                                    constant LayerUniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 below = base.sample(s, in.uv);
        if (u.hasLayer == 0) {
            return float4(below.rgb, 1.0);
        }
        return float4(compositeLayer(below.rgb, in.uv, layer, depth, u), 1.0);
    }

    // MARK: effects

    struct EffectUniforms {
        float2 center;
        float2 direction;
        float2 scrollStep;
        float phase;
        float strength;
        float scale;
        float aspect;
        int kind;
        int cycles;
        int reversed;
        int overlay;
        int hasMask;
    };

    constant float TAU = 6.28318530718;

    float hash3(float3 p) {
        p = fract(p * 0.3183099 + 0.1);
        p *= 17.0;
        return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
    }

    float valueNoise(float3 x) {
        float3 i = floor(x);
        float3 f = fract(x);
        f = f * f * (3.0 - 2.0 * f);
        return mix(mix(mix(hash3(i + float3(0, 0, 0)), hash3(i + float3(1, 0, 0)), f.x),
                       mix(hash3(i + float3(0, 1, 0)), hash3(i + float3(1, 1, 0)), f.x), f.y),
                   mix(mix(hash3(i + float3(0, 0, 1)), hash3(i + float3(1, 0, 1)), f.x),
                       mix(hash3(i + float3(0, 1, 1)), hash3(i + float3(1, 1, 1)), f.x), f.y), f.z);
    }

    float fbm(float3 x) {
        return valueNoise(x) * 0.65 + valueNoise(x * 2.03 + 7.1) * 0.35;
    }

    // Distortions read past the layer's edge as the edge colour: a full-canvas layer
    // would otherwise open black gaps, and a cut-out's edge is transparent anyway.
    // They work in a space where the layer's height is 1, so circles stay round.
    float2 toSpace(float2 uv, float aspect) { return float2(uv.x * aspect, uv.y); }
    float2 toUV(float2 q, float aspect) { return float2(q.x / aspect, q.y); }

    float2 rotateAround(float2 q, float2 c, float angle) {
        float s = sin(angle);
        float co = cos(angle);
        float2 d = q - c;
        return c + float2(d.x * co - d.y * s, d.x * s + d.y * co);
    }

    fragment float4 scene_effect(VertexOut in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 texture2d<float> mask [[texture(1)]],
                                 texture2d<float> flow [[texture(2)]],
                                 constant EffectUniforms &u [[buffer(0)]],
                                 constant float4 *pins [[buffer(1)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        constexpr sampler wrap(filter::linear, address::repeat);
        float2 uv = in.uv;
        float m = u.hasMask != 0 ? mask.sample(s, uv).r : 1.0;
        float w = TAU * float(u.cycles) * u.phase;
        float2 q = toSpace(uv, u.aspect);
        float2 c = toSpace(u.center, u.aspect);
        float2 dir = normalize(toSpace(u.direction, 1.0));
        float2 perp = float2(-dir.y, dir.x);
        float4 original = src.sample(s, uv);
        float4 result = original;

        switch (u.kind) {
        case 0: { // shake
            float2 d = dir * (u.strength * 0.03) * sin(w);
            result = src.sample(s, toUV(q - d * m, u.aspect));
            break;
        }
        case 1: { // sway
            float k = mix(2.0, 24.0, u.scale);
            float2 d = dir * (u.strength * 0.02) * sin(w - k * dot(q, dir));
            result = src.sample(s, toUV(q - d * m, u.aspect));
            break;
        }
        case 2: { // swing
            float angle = u.strength * 0.35 * sin(w) * m;
            result = src.sample(s, toUV(rotateAround(q, c, -angle), u.aspect));
            break;
        }
        case 3: { // waves
            float k = mix(4.0, 60.0, u.scale);
            float2 d = perp * (u.strength * 0.01) * sin(k * dot(q, dir) - w);
            result = src.sample(s, toUV(q - d * m, u.aspect));
            break;
        }
        case 4: { // ripple
            float2 v = q - c;
            float r = length(v);
            float k = mix(10.0, 120.0, u.scale);
            float2 d = r > 1e-4 ? (v / r) * (u.strength * 0.01) * sin(k * r - w) : float2(0.0);
            result = src.sample(s, toUV(q - d * m, u.aspect));
            break;
        }
        case 5: { // water flow: two samples half a cycle apart hide each one's reset
            float2 f = (flow.sample(s, uv).rg * 2.0 - 1.0) * (u.strength * 0.08) * m;
            float p0 = fract(float(u.cycles) * u.phase);
            float p1 = fract(p0 + 0.5);
            float4 a = src.sample(s, toUV(q - f * p0, u.aspect));
            float4 b = src.sample(s, toUV(q - f * p1, u.aspect));
            result = mix(a, b, abs(1.0 - 2.0 * p0));
            break;
        }
        case 6: { // scroll
            float2 shifted = uv - u.scrollStep * float(u.cycles) * u.phase;
            result = mix(original, src.sample(wrap, shifted), m);
            break;
        }
        case 7: { // cloud motion: noise drifting around a circle in time, so it loops
            float f = mix(1.5, 8.0, u.scale);
            float3 p = float3(q * f, 0.0) + float3(0.0, sin(w), cos(w)) * 0.8;
            float2 d = (float2(fbm(p), fbm(p + 19.3)) - 0.5) * (u.strength * 0.06);
            result = src.sample(s, toUV(q - d * m, u.aspect));
            break;
        }
        case 8: { // spin: whole turns per loop
            float angle = (u.reversed != 0 ? -1.0 : 1.0) * w;
            result = mix(original, src.sample(s, toUV(rotateAround(q, c, -angle), u.aspect)), m);
            break;
        }
        case 9: { // twirl
            float radius = mix(0.05, 0.7, u.scale);
            float r = length(q - c);
            float falloff = r < radius ? pow(1.0 - r / radius, 2.0) : 0.0;
            float angle = (u.reversed != 0 ? -1.0 : 1.0) * u.strength * 3.14159 * falloff * sin(w) * m;
            result = src.sample(s, toUV(rotateAround(q, c, -angle), u.aspect));
            break;
        }
        case 11: { // puppet: displacement blended from nearby pins, fading to none
            int count = int(pins[0].x);
            float radius = mix(0.05, 0.6, u.scale);
            float2 sum = float2(0.0);
            float weights = 0.05;
            for (int i = 1; i <= count; i++) {
                float distance = length(q - pins[i].xy) / radius;
                float w = 1.0 / (1.0 + distance * distance * distance * distance);
                sum += pins[i].zw * w;
                weights += w;
            }
            float2 d = sum / weights;
            result = src.sample(s, toUV(q - d * m, u.aspect));
            break;
        }
        case 10: { // pulse
            float dim = u.strength * (0.5 - 0.5 * cos(w));
            result = float4(original.rgb * (1.0 - dim * m), original.a);
            break;
        }
        default:
            break;
        }

        if (u.overlay == 1) {
            result = mix(result, float4(1.0, 0.25, 0.3, 1.0), m * 0.45);
        } else if (u.overlay == 2) {
            float strength = length(flow.sample(s, uv).rg * 2.0 - 1.0);
            result = mix(result, float4(0.2, 0.55, 1.0, 1.0), clamp(strength, 0.0, 1.0) * 0.5);
        }
        return result;
    }

    // MARK: particles

    struct ParticleUniforms {
        float2 direction;
        float2 cursor;
        float4 color;
        float phase;
        float aspect;
        float size;
        float sway;
        float opacity;
        float pixelHeight;
        int count;
        int cycles;
        int preset;
        int hasCursor;
        int cursorMode;
        int hasMask;
        int seed;
        int travels;
    };

    struct ParticleOut {
        float4 position [[position]];
        float2 local;
        float alpha;
        float tint;
    };

    float hash1(uint n) {
        n = (n << 13u) ^ n;
        n = n * (n * n * 15731u + 789221u) + 1376312589u;
        return float(n & 0x7fffffffu) / float(0x7fffffff);
    }

    // Everything below is a function of (particle index, phase); every term with
    // the phase repeats a whole number of times per loop.
    vertex ParticleOut particle_vertex(uint vid [[vertex_id]],
                                      uint iid [[instance_id]],
                                      constant ParticleUniforms &u [[buffer(0)]],
                                      texture2d<float> mask [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        uint base = iid * 9u + uint(u.seed) * 7919u;
        float h0 = hash1(base), h1 = hash1(base + 1u), h2 = hash1(base + 2u), h3 = hash1(base + 3u);
        float h4 = hash1(base + 4u), h5 = hash1(base + 5u), h6 = hash1(base + 6u);
        float margin = 0.08 + u.size * 0.06;
        float2 box = float2(u.aspect + 2.0 * margin, 1.0 + 2.0 * margin);
        float2 dir = u.direction;
        float2 perp = float2(-dir.y, dir.x);

        // Position in a space where the canvas is aspect × 1.
        float2 q = float2(h0 * u.aspect, h1);
        float life = 1.0;
        if (u.travels != 0) {
            // Depth-like variation: some particles a bit slower, a whole number of
            // crossings per loop either way.
            int crossings = max(1, u.cycles + int(h6 * 2.0) - (u.cycles > 1 ? 1 : 0));
            float t = fract(h2 + float(crossings) * u.phase);
            q += dir * (t * 1.25);
            life = smoothstep(0.0, 0.08, t) * (1.0 - smoothstep(0.92, 1.0, t));
        }
        float swayCycles = 1.0 + floor(h3 * 3.0);
        q += perp * (u.sway * 0.05) * sin(6.28318530718 * (swayCycles * u.phase + h4));
        // Wrap off-canvas, so a particle leaving one edge enters at the other.
        q = fmod(fmod(q + margin, box) + box, box) - margin;

        float2 uv = float2(q.x / u.aspect, q.y);
        if (u.hasCursor != 0) {
            float2 cq = float2(u.cursor.x * u.aspect, u.cursor.y);
            float2 d = q - cq;
            float dist = length(d);
            float push = 0.12 * pow(max(0.0, 1.0 - dist / 0.25), 2.0);
            float2 away = dist > 1e-4 ? d / dist : float2(0.0);
            q += (u.cursorMode == 1 ? -away : away) * push;
            uv = float2(q.x / u.aspect, q.y);
        }

        float sizeScale = 0.6 + h5 * 0.8;
        float radius = (0.004 + u.size * 0.03) * sizeScale;
        float2 corner = float2((vid & 1u) ? 1.0 : -1.0, (vid & 2u) ? 1.0 : -1.0);
        float2 offset;
        if (u.preset == 1) { // rain: a streak along the fall
            offset = dir * corner.y * radius * 4.0 + perp * corner.x * radius * 0.25;
        } else if (u.preset == 2) { // petals tumble
            float angle = 6.28318530718 * (h3 + swayCycles * u.phase);
            float c = cos(angle), sn = sin(angle);
            float2 r = corner * radius * float2(1.0, 0.6);
            offset = float2(r.x * c - r.y * sn, r.x * sn + r.y * c);
        } else {
            offset = corner * radius * (u.preset == 3 || u.preset == 5 ? 2.5 : 1.0);
        }
        // Keep at least a pixel wide so small particles do not shimmer away.
        float minRadius = 1.0 / max(u.pixelHeight, 1.0);
        offset = sign(offset) * max(abs(offset), float2(minRadius));
        float2 vertexQ = q + offset;
        float2 vertexUV = float2(vertexQ.x / u.aspect, vertexQ.y);

        float twinkle = 1.0;
        if (u.preset == 3 || u.preset == 5 || u.preset == 7) {
            float blinkCycles = 1.0 + floor(h6 * 4.0);
            twinkle = 0.35 + 0.65 * (0.5 + 0.5 * sin(6.28318530718 * (blinkCycles * u.phase + h0)));
        }
        float inside = u.hasMask != 0 ? mask.sample(s, uv, level(0)).r : 1.0;

        ParticleOut out;
        out.position = float4(vertexUV.x * 2.0 - 1.0, 1.0 - vertexUV.y * 2.0, 0.0, 1.0);
        out.local = corner;
        out.alpha = life * twinkle * inside * u.opacity * u.color.a * (0.6 + 0.4 * h4);
        out.tint = h1;
        return out;
    }

    fragment float4 particle_fragment(ParticleOut in [[stage_in]],
                                      constant ParticleUniforms &u [[buffer(0)]]) {
        float2 p = in.local;
        float r = length(p);
        float shape;
        switch (u.preset) {
        case 0: shape = 1.0 - smoothstep(0.55, 1.0, r); break;                       // snow
        case 1: shape = (1.0 - smoothstep(0.6, 1.0, abs(p.x))) * (1.0 - smoothstep(0.3, 1.0, abs(p.y))); break; // rain
        case 2: shape = 1.0 - smoothstep(0.8, 1.0, length(float2(p.x, p.y * 1.0 + 0.25 * p.x * p.x))); break;   // petal
        case 3: shape = exp(-r * r * 9.0) + 0.6 * (1.0 - smoothstep(0.08, 0.2, r)); break;  // firefly glow
        case 4: shape = exp(-r * r * 6.0); break;                                     // dust
        case 5: shape = exp(-r * r * 10.0) + 0.5 * (1.0 - smoothstep(0.1, 0.25, r)); break; // ember
        case 6: shape = smoothstep(0.65, 0.85, r) * (1.0 - smoothstep(0.85, 1.0, r)) + 0.15 * (1.0 - smoothstep(0.0, 0.9, r)); break; // bubble
        default: {                                                                    // star
            float cross = max(1.0 - smoothstep(0.0, 0.12, abs(p.x)) , 1.0 - smoothstep(0.0, 0.12, abs(p.y))) * (1.0 - r);
            shape = max(exp(-r * r * 16.0), cross);
        }
        }
        float3 color = u.color.rgb;
        if (u.preset == 5) { // embers vary from orange to yellow
            color = mix(color, float3(1.0, 0.85, 0.4), in.tint * 0.6);
        }
        float alpha = clamp(shape, 0.0, 1.0) * in.alpha;
        return float4(color * alpha, alpha);
    }
    """
}

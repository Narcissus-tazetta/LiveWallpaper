import Foundation
import Metal
import simd

extension SceneRenderer {
    // MARK: - Effects

    private struct EffectUniforms {
        /// The effect's area for `fixedEdge`: min x, min y, max x, max y in layer UV.
        /// First, so the 16-byte alignment matches the shader's struct.
        var bounds: SIMD4<Float>
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
        var fixedEdge: Int32
        var time: Float
        var hasTimeOffset: Int32
        var patternClamps: Int32
    }

    /// How the effect pass tints what is being painted: 1 the mask, 2 the flow, 3 the
    /// time offset.
    private func paintTint(_ override: ScenePaintOverride?) -> Int32 {
        guard let override, showsPaintTint else {
            return 0
        }
        switch override.target {
        case .mask: return 1
        case .flow: return 2
        case .timeOffset: return 3
        }
    }

    /// The settings of a real-time effect, in the order its shader reads them.
    private struct RealTimeEffectValues {
        // A homogeneous tuple is the only Swift type with C-array layout for the shader's buffer.
        // swiftlint:disable:next large_tuple
        var values: (
            Float, Float, Float, Float, Float, Float, Float, Float,
            Float, Float, Float, Float, Float, Float, Float, Float,
            Float, Float, Float, Float, Float, Float, Float, Float
        ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

        init(_ list: [Float]) {
            withUnsafeMutableBytes(of: &values) { raw in
                let slots = raw.bindMemory(to: Float.self)
                for (index, value) in list.prefix(slots.count).enumerated() {
                    slots[index] = value
                }
            }
        }
    }

    private func realTimeValues(
        _ effect: SceneEffect,
        input: SceneFrameInput,
        aspect: Float
    ) -> RealTimeEffectValues {
        func value(_ key: String) -> Float {
            Float(effect.value(key))
        }
        // A pattern shifted by whole repeats looks the same only when it repeats; a
        // clamped one keeps its real shift and cannot close a baked loop.
        let patternRepeats = effect.value(SceneEffect.patternClampsKey) == 0
        func patternShift(_ rate: Double) -> Float {
            patternRepeats ? loopPhase(rate, cycle: 1, keepsDirection: true, input: input) :
                unwrappedShift(
                    rate,
                    input: input
                )
        }
        /// The pulse and the swing add noise read along (1/12, 1/36) × noiseSpeed per second.
        func noiseShifts(_ speed: Double) -> [Float] {
            [patternShift(speed / 12), patternShift(speed / 36)]
        }
        switch effect.kind {
        case .travelingWaves:
            typealias Key = SceneEffect.WaveKey
            // Waves run one way, so a baked loop never winds them back.
            let speed2 = effect.value(Key.speed2)
            return RealTimeEffectValues([
                loopAngle(effect.value(Key.speed), keepsDirection: true, input: input),
                value(Key.scale),
                value(Key.amplitude), value(Key.exponent), value(Key.angle), value(Key.dual),
                loopAngle(speed2, keepsDirection: true, input: input), value(Key.scale2),
                value(Key.offset2),
                value(Key.exponent2), value(Key.angle2), Float(speed2)
            ])
        case .flowShake:
            typealias Key = SceneEffect.FlowShakeKey
            let speed = effect.value(Key.speed)
            // The irregular swing sums sines at these multiples of the speed; each closes
            // a baked loop on its own.
            let multiples = [1, -0.16161616, 0.0083333, -0.00019841]
            return RealTimeEffectValues(
                loopAngles([speed], input: input) + [
                    value(Key.amplitude), value(Key.frictionX), value(Key.frictionY),
                    value(Key.boundsMin),
                    value(Key.boundsMax), value(Key.side), value(Key.irregular)
                ] + loopAngles(multiples.map { speed * $0 }, input: input)
            )
        case .flowMap:
            typealias Key = SceneEffect.FlowMapKey
            return RealTimeEffectValues([
                loopPhase(effect.value(Key.speed), cycle: 1, keepsDirection: true, input: input),
                value(Key.strength), value(Key.feather),
                value(Key.phaseScale)
            ])
        case .normalRipples:
            typealias Key = SceneEffect.RipplesKey
            // Two copies of the pattern drift opposite ways while both scroll; each axis of
            // each copy, in pattern repeats, closes a baked loop on its own.
            let drift = effect.value(Key.animationSpeed) * effect.value(Key.animationSpeed)
            let scrollAngle = effect.value(Key.scrollAngle)
            let scroll = SIMD2(-sin(scrollAngle), cos(scrollAngle)) * effect
                .value(Key.scrollSpeed) * effect.value(Key.scrollSpeed)
            let stored = Double(textureAspect(effect))
            let repeats = SIMD2(stored > 0 ? stored : Double(aspect), effect.value(Key.ratio)) *
                effect.value(Key.scale)
            let first = (scroll + drift) * repeats, second = (scroll - drift) * repeats
            return RealTimeEffectValues([
                value(Key.animationSpeed), value(Key.scale), value(Key.scrollSpeed),
                value(Key.scrollAngle),
                value(Key.ratio), value(Key.strength), textureAspect(effect), value(Key.specular),
                value(Key.specularPower), value(Key.specularStrength), value(Key.specularRed),
                value(Key.specularGreen), value(Key.specularBlue)
            ] + [first.x, first.y, second.x, second.y].map(patternShift))
        case .noiseDrift:
            typealias Key = SceneEffect.NoiseDriftKey
            return RealTimeEffectValues([
                patternShift(effect.value(Key.speed)), value(Key.scale), value(Key.scaleX),
                value(Key.amount), value(Key.angle), textureAspect(effect)
            ])
        case .noiseSway:
            typealias Key = SceneEffect.NoiseSwayKey
            let speed = effect.value(Key.speed)
            let multiples = [
                1,
                -0.16161616,
                0.0083333,
                -0.00019841,
                -0.5,
                0.041666666,
                -0.0013888889,
                0.000024801587
            ]
            return RealTimeEffectValues(
                loopAngles(multiples.map { speed * $0 }, input: input) + [
                    value(Key.strength), value(Key.phase), value(Key.power), value(Key.noiseScale),
                    value(Key.ratio), value(Key.angle)
                ]
            )
        case .pulseBlend:
            typealias Key = SceneEffect.PulseKey
            return RealTimeEffectValues([
                loopAngle(effect.value(Key.speed), keepsDirection: false, input: input),
                value(Key.phase),
                value(Key.amount), value(Key.boundsMin), value(Key.boundsMax),
                value(Key.noiseSpeed),
                value(Key.noiseAmount),
                value(Key.power), value(Key.lowRed), value(Key.lowGreen), value(Key.lowBlue),
                value(Key.highRed), value(Key.highGreen), value(Key.highBlue), value(Key.blendMode),
                value(Key.pulsesColor), value(Key.pulsesOpacity)
            ] + noiseShifts(effect.value(Key.noiseSpeed)))
        case .uvScroll:
            typealias Key = SceneEffect.ScrollKey
            /// The picture repeats every 1 / repeats of the layer, so a loop closes on whole
            /// wraps of that; with no repeat nothing moves.
            func shift(_ raw: Double, repeats: Double) -> Float {
                guard repeats != 0 else { return 0 }
                return loopPhase(
                    raw * abs(raw),
                    cycle: 1 / abs(repeats),
                    keepsDirection: true,
                    input: input
                )
            }
            let repeatX = effect.value(Key.repeatX), repeatY = effect.value(Key.repeatY)
            return RealTimeEffectValues([
                shift(effect.value(Key.speedX), repeats: repeatX), shift(
                    effect.value(Key.speedY),
                    repeats: repeatY
                ),
                Float(repeatX), Float(repeatY)
            ])
        case .opacityMask:
            return RealTimeEffectValues([value("alpha")])
        case .axisSwing:
            typealias Key = SceneEffect.AxisSwingKey
            return RealTimeEffectValues([
                loopAngle(effect.value(Key.speed), keepsDirection: false, input: input),
                value(Key.phase),
                value(Key.amount), value(Key.x0), value(Key.y0), value(Key.x1), value(Key.y1),
                value(Key.size),
                value(Key.center), value(Key.feather), value(Key.doubleSided), value(Key.noise),
                value(Key.noiseSpeed), value(Key.noiseAmount), textureAspect(effect)
            ] + noiseShifts(effect.value(Key.noiseSpeed)))
        default:
            return RealTimeEffectValues([])
        }
    }

    /// The stored picture's width over height when the effect names it, else the
    /// layer picture's.
    private func textureAspect(_ effect: SceneEffect) -> Float {
        Float(effect.values[SceneEffect.textureAspectKey] ?? 0)
    }

    /// The baked loop's length, nil when drawn on real time.
    func bakedLoop(_ input: SceneFrameInput) -> Double? {
        input.isRealTime ? nil : Double(max(document.loopSeconds, 1))
    }

    /// Keys the finishing passes' loop fade among the layers' and effects'.
    static let finishingID = UUID()

    /// The time into a motion that repeats every `period` seconds: the frame's own on
    /// real time, bent in a baked loop to play it whole times (SceneLoopTiming).
    func pathTime(_ period: Double, input: SceneFrameInput) -> Double {
        guard let loop = bakedLoop(input), period > 0 else { return input.time }
        return SceneLoopTiming.phase(
            rate: 1,
            cycle: period,
            keepsDirection: true,
            time: input.time,
            loop: loop
        )
    }

    /// SceneLoopTiming.phase at the frame's time.
    private func loopPhase(
        _ rate: Double,
        cycle: Double,
        keepsDirection: Bool,
        input: SceneFrameInput
    ) -> Float {
        Float(SceneLoopTiming.phase(
            rate: rate,
            cycle: cycle,
            keepsDirection: keepsDirection,
            time: input.time,
            loop: bakedLoop(input)
        ))
    }

    /// `rate × time` with nothing wrapped or bent: the frame's own time drawn live, the
    /// time within the loop in a bake.
    private func unwrappedShift(_ rate: Double, input: SceneFrameInput) -> Float {
        Float(rate *
            (bakedLoop(input).map { SceneLoopTiming.timeInLoop(input.time, loop: $0) } ?? input
                .time))
    }

    /// `loopPhase` for a speed in radians per second.
    private func loopAngle(_ speed: Double, keepsDirection: Bool, input: SceneFrameInput) -> Float {
        loopPhase(speed, cycle: 2 * .pi, keepsDirection: keepsDirection, input: input)
    }

    func loopAngles(_ speeds: [Double], input: SceneFrameInput) -> [Float] {
        speeds.map { loopAngle($0, keepsDirection: false, input: input) }
    }

    /// Runs the layer's effects and returns the texture to composite.
    func applyEffects(
        to layer: SceneLayer,
        commandBuffer: MTLCommandBuffer,
        input: SceneFrameInput,
        targetSize: SIMD2<Float>,
        canvasSource: MTLTexture? = nil,
        compositeUniforms: LayerUniforms? = nil,
        captureRegion: CaptureRegion? = nil
    ) throws -> MTLTexture {
        let viewSize = SIMD2(input.viewport.z, input.viewport.w)
        let shown = targetSize / viewSize / layerUVScale(for: layer) * effectResolutionScale
        var source: MTLTexture
        if layer.capturesCanvas {
            let width = captureRegion?.width ?? max(
                Int((targetSize.x * effectResolutionScale).rounded()),
                16
            )
            let height = captureRegion?.height ?? max(
                Int((targetSize.y * effectResolutionScale).rounded()),
                16
            )
            let capture = try captureTexture(for: layer.id, width: width, height: height)
            try capturePass(
                commandBuffer: commandBuffer, destination: capture,
                base: canvasSource ?? blackTexture,
                uniforms: captureRegion?.uniforms ?? compositeUniforms ?? Self.passThroughUniforms
            )
            source = capture
        } else if layer.kind == .particles, layer.particleSystem != nil {
            source = try renderParticleSystem(
                layer,
                commandBuffer: commandBuffer,
                input: input,
                targetSize: targetSize,
                background: canvasSource ?? blackTexture
            )
        } else if layer.kind == .particles, let particles = layer.particles {
            source = try renderParticles(
                particles, layerID: layer.id, commandBuffer: commandBuffer, input: input,
                targetSize: targetSize
            )
        } else if let image = picture(for: layer) {
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
        if let graph = graphRenderers[layer.id] {
            var images = graphResources[layer.id]!
            // A puppet's effects (and their masks and flow maps) are authored on its texture sheet,
            // so they run there and the mesh then draws the result; run after the mesh they would
            // sit on the wrong parts.
            if drawsSkeleton(layer), !effects.isEmpty, let file = layer.renderGraph?.images[
                "atlas"
            ],
                let atlas = images[file]
            {
                let width = max(Int((Float(atlas.width) * effectResolutionScale).rounded()), 16)
                let height = max(Int((Float(atlas.height) * effectResolutionScale).rounded()), 16)
                images[file] = try encodeEffects(
                    effects,
                    on: atlas,
                    layer: layer,
                    width: width,
                    height: height,
                    commandBuffer: commandBuffer,
                    input: input,
                    canvasSource: canvasSource
                )
                effects = []
            }
            let picture = source
            source = try encodeClosingLoop(
                graph,
                id: layer.id,
                frame: input,
                commandBuffer: commandBuffer
            ) { time in
                try graph.encode(
                    input: picture,
                    images: images,
                    time: time,
                    cursor: input.cursor,
                    audio: input.audio,
                    meshes: lastFrame?.meshes ?? [],
                    layerFromCanvas: graph
                        .usesLayerPlacement ? layerFromCanvas(layer) :
                        matrix_identity_float3x3,
                    pointerPresses: input.pointerPresses,
                    parallax: input.parallax,
                    background: canvasSource ?? blackTexture,
                    commandBuffer: commandBuffer
                )
            }
        }
        guard !effects.isEmpty else {
            return source
        }
        // The size the layer shows on the target, never above its own resolution.
        let width = layer.capturesCanvas ? source.width : max(
            min(Int(shown.x.rounded()), source.width),
            16
        )
        let height = layer.capturesCanvas ? source.height : max(
            min(Int(shown.y.rounded()), source.height),
            16
        )
        return try encodeEffects(
            effects,
            on: source,
            layer: layer,
            width: width,
            height: height,
            commandBuffer: commandBuffer,
            input: input,
            canvasSource: canvasSource
        )
    }

    /// How long a baked loop takes to fade a converted shader from its picture one loop
    /// later into its own.
    private static let loopFadeSeconds = 2.0

    /// A converted shader's picture at the frame. Its time feeds a formula a bake cannot
    /// bend, so where the picture depends on the time alone a baked loop's first seconds
    /// fade in from the picture one loop later, which is where the loop's last frame left
    /// it. A shader that carries earlier frames, or steps by the frame time, draws as it is.
    func encodeClosingLoop(
        _ graph: SceneRenderGraphRenderer, id: UUID, frame input: SceneFrameInput,
        commandBuffer: MTLCommandBuffer,
        encode: (Double) throws -> MTLTexture
    ) throws -> MTLTexture {
        guard let loop = bakedLoop(input), graph.graph.uses(.time), !graph.graph.uses(.frameTime),
              !graph.graph.carriesFrames
        else { return try encode(input.time) }
        let fade = min(Self.loopFadeSeconds, loop / 4)
        let elapsed = SceneLoopTiming.timeInLoop(input.time, loop: loop)
        guard elapsed < fade else { return try encode(input.time) }
        let laterPicture = try encode(input.time + loop)
        var targets = loopFadeTargets[id]
        if targets
            .map({ $0.later.width != laterPicture.width || $0.later.height != laterPicture.height
                    || $0.later.pixelFormat != laterPicture.pixelFormat }) ?? true
        {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: laterPicture.pixelFormat, width: laterPicture.width,
                height: laterPicture.height, mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            guard let later = device.makeTexture(descriptor: descriptor),
                  let faded = device.makeTexture(descriptor: descriptor)
            else {
                throw RendererError.textureAllocationFailed
            }
            targets = (later, faded)
            loopFadeTargets[id] = targets
        }
        let (later, faded) = targets!
        // The shader draws both pictures into its own output, so the later one is set aside first.
        guard let blit = commandBuffer.makeBlitCommandEncoder()
        else { throw RendererError.textureAllocationFailed }
        blit.copy(from: laterPicture, to: later)
        blit.endEncoding()
        let now = try encode(input.time)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = faded
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw RendererError.textureAllocationFailed
        }
        try encoder.setRenderPipelineState(loopFadePipeline(faded.pixelFormat))
        encoder.setFragmentTexture(later, index: 0)
        encoder.setFragmentTexture(now, index: 1)
        let progress = elapsed / fade
        var weight = Float(progress * progress * (3 - 2 * progress))
        encoder.setFragmentBytes(&weight, length: MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return faded
    }

    private func loopFadePipeline(_ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let state = loopFadePipelines[format.rawValue] { return state }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = pipeline.library.makeFunction(name: "scene_vertex")
        descriptor.fragmentFunction = pipeline.library.makeFunction(name: "scene_loop_fade")
        descriptor.colorAttachments[0].pixelFormat = format
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        loopFadePipelines[format.rawValue] = state
        return state
    }

    private func drawsSkeleton(_ layer: SceneLayer) -> Bool {
        layer.renderGraph?.passes
            .contains { $0.draw?.skeleton != nil || $0.draw?.skeletonID != nil } == true
    }

    /// Runs `effects` over `source` into targets of the given size.
    private func encodeEffects(
        _ effects: [SceneEffect], on source: MTLTexture, layer: SceneLayer, width: Int, height: Int,
        commandBuffer: MTLCommandBuffer, input: SceneFrameInput, canvasSource: MTLTexture?
    ) throws -> MTLTexture {
        let standardEffectCount = effects.filter { graphRenderers[$0.id] == nil }.count
        let layerTarget = standardEffectCount > 0 ? try effectLayerTexture(
            for: layer.id,
            width: width,
            height: height
        ) : nil
        let scratchTarget = standardEffectCount > 1 ? try effectScratchTexture(
            width: width,
            height: height
        ) : nil

        let phase = loopPhase(input.time)
        let aspect = Float(source.width) / Float(max(source.height, 1))
        var current = source
        var standardIndex = 0
        let startsWithLayerTarget = (standardEffectCount % 2 != 0)

        for effect in effects {
            if let graph = graphRenderers[effect.id] {
                let picture = current
                current = try encodeClosingLoop(
                    graph,
                    id: effect.id,
                    frame: input,
                    commandBuffer: commandBuffer
                ) { time in
                    try graph.encode(
                        input: picture,
                        images: graphResources[effect.id]!,
                        time: time,
                        cursor: input.cursor,
                        values: effect.values,
                        audio: input.audio,
                        meshes: lastFrame?.meshes ?? [],
                        layerFromCanvas: graph
                            .usesLayerPlacement ? layerFromCanvas(layer) :
                            matrix_identity_float3x3,
                        pointerPresses: input.pointerPresses,
                        parallax: input.parallax,
                        background: canvasSource ?? blackTexture,
                        commandBuffer: commandBuffer
                    )
                }
                continue
            }
            let isLayerTarget = startsWithLayerTarget ? (standardIndex % 2 == 0) :
                (standardIndex % 2 != 0)
            let destination = isLayerTarget ? layerTarget! : scratchTarget!
            standardIndex += 1

            let override = paintOverride?.effectID == effect.id ? paintOverride : nil
            let mask = override?.target == .mask ? paintOverrideTexture : effect.maskFile.flatMap {
                effect.kind == .opacityMask ? flowTextures[$0] : maskTextures[$0]
            }
            let flow = override?.target == .flow ? paintOverrideTexture : effect.flowFile
                .flatMap { flowTextures[$0] }
            let timeOffset = override?.target == .timeOffset
                ? paintOverrideTexture : effect.timeOffsetFile.flatMap { maskTextures[$0] }
            let pattern = effect.patternFile.flatMap { flowTextures[$0] }
            let radians = Float(effect.direction * .pi / 180)
            // UV y points down, the direction angle counts counter-clockwise with y up.
            let direction = SIMD2<Float>(cos(radians), -sin(radians))
            let bounds = effect.areaBounds ?? .whole
            var uniforms = EffectUniforms(
                bounds: SIMD4(
                    Float(bounds.minX),
                    Float(bounds.minY),
                    Float(bounds.maxX),
                    Float(bounds.maxY)
                ),
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
                cycles: Int32(min(
                    max(effect.cycles, SceneEffect.cyclesRange.lowerBound),
                    SceneEffect.cyclesRange.upperBound
                )),
                reversed: effect.reversed ? 1 : 0,
                overlay: paintTint(override),
                hasMask: mask == nil ? 0 : 1,
                fixedEdge: Int32(SceneFixedEdge.allCases.firstIndex(of: effect.fixedEdge) ?? 0),
                // A baked loop reads its own time within the loop, so motions that
                // repeat whole times per loop land exactly where it starts again.
                time: Float(input.isRealTime ? input.time : Double(phase) * Double(max(
                    document.loopSeconds,
                    1
                ))),
                hasTimeOffset: timeOffset == nil ? 0 : 1,
                patternClamps: effect.value(SceneEffect.patternClampsKey) != 0 ? 1 : 0
            )
            var realTime = realTimeValues(effect, input: input, aspect: aspect)
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
            encoder.setFragmentTexture(timeOffset ?? blackTexture, index: 3)
            encoder.setFragmentTexture(pattern ?? blackTexture, index: 4)
            encoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<EffectUniforms>.stride,
                index: 0
            )
            var pins = puppetPins(effect, phase: phase, aspect: aspect)
            encoder.setFragmentBytes(
                &pins,
                length: MemoryLayout<SIMD4<Float>>.stride * pins.count,
                index: 1
            )
            encoder.setFragmentBytes(
                &realTime,
                length: MemoryLayout<RealTimeEffectValues>.stride,
                index: 2
            )
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
                displacement = SIMD2(cos(radians), -sin(radians)) * Float(min(
                    max(pin.amount, 0),
                    1
                )) * 0.06 * swing
            }
            result[index + 1] = SIMD4(
                Float(pin.x) * aspect,
                Float(pin.y),
                displacement.x,
                displacement.y
            )
        }
        result[0] = SIMD4(Float(pins.count), 0, 0, 0)
        return result
    }

    private func effectLayerTexture(
        for layerID: UUID,
        width: Int,
        height: Int
    ) throws -> MTLTexture {
        if let existing = effectLayerTargets[layerID], existing.width == width,
           existing.height == height
        {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RendererError.textureAllocationFailed
        }
        effectLayerTargets[layerID] = texture
        return texture
    }

    private func effectScratchTexture(width: Int, height: Int) throws -> MTLTexture {
        let key = SIMD2(width, height)
        usedEffectScratchSizes.insert(key)
        if let existing = effectScratchTargets[key] {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RendererError.textureAllocationFailed
        }
        effectScratchTargets[key] = texture
        return texture
    }

    private func captureTexture(for layerID: UUID, width: Int, height: Int) throws -> MTLTexture {
        if let existing = captureTargets[layerID], existing.width == width,
           existing.height == height
        {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RendererError.textureAllocationFailed
        }
        captureTargets[layerID] = texture
        return texture
    }
}

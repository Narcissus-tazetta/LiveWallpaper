import CoreGraphics
import Foundation
import Metal
import simd

extension SceneRenderer {
    func composite(
        into target: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        input: SceneFrameInput,
        frame: SceneEvaluatedFrame?
    ) throws {
        usedEffectScratchSizes.removeAll(keepingCapacity: true)
        defer {
            graphTexturePool.endFrame()
            if effectScratchTargets.count != usedEffectScratchSizes.count {
                effectScratchTargets = effectScratchTargets
                    .filter { usedEffectScratchSizes.contains($0.key) }
            }
        }
        if frame == nil, document.scripts.contains(where: \.canRun), Thread.isMainThread {
            throw SceneScriptIssue(
                scriptID: document.scripts.first!.id,
                name: "JavaScript",
                message: "Scripts must be evaluated off the main thread"
            )
        }
        let evaluated = try frame ?? frameEvaluator.evaluate(
            document,
            input: input,
            timeOfDay: timeOfDay
        )
        rigs!.setPlaybackOverrides(evaluated.rigPlayback)
        rigs!.setLoop(bakedLoop(input))
        lastFrame = evaluated
        try prepareMediaArtwork(input.media)
        let placements = placementEvaluator!.evaluate(time: input.time)
        lastPlacements = [:]
        // A copy a script made is placed like its template, moved by its own transform.
        for (id, template) in evaluated.instances.map({ ($0.key, $0.value) }) + placements.keys
            .map({ (
                $0,
                $0
            ) })
        {
            guard let matrix = placements[template],
                  let layer = evaluated.layers[id] else { continue }
            let reference = layer.layer.placement!.referenceTransform
            lastPlacements[id] = placementMatrix(layer.transform) *
                simd_inverse(placementMatrix(reference)) * matrix
        }
        lastInversePlacements = lastPlacements.compactMapValues(Self.inversePlacement)
        lastPhase = Double(loopPhase(input.time))
        lastTime = input.time
        advanceParticles(evaluated, input: input)
        let targetSize = SIMD2(Float(target.width), Float(target.height))
        let copies = evaluated.instances.keys
            .sorted { evaluated.order[$0] ?? 0 < evaluated.order[$1] ?? 0 }
            .compactMap { evaluated.layers[$0]?.layer }
        let ordered = (document.layers + copies).enumerated().sorted { a, b in
            let left = evaluated.order[a.element.id] ?? a.offset
            let right = evaluated.order[b.element.id] ?? b.offset
            return left == right ? a.offset < b.offset : left < right
        }.map(\.element)
        for layer in ordered where layer.kind == .text {
            try prepareText(evaluated.layers[layer.id]!.layer)
        }
        // A video follows the scene's time unless a script holds a layer showing it at its own.
        var videoTimes: [String: Double] = [:]
        for layer in ordered {
            guard let evaluatedLayer = evaluated.layers[layer.id], evaluatedLayer.layer.isVisible,
                  let file = layer.videoFile else { continue }
            if let time = evaluatedLayer.videoTime {
                videoTimes[file] = time
            } else if videoTimes[file] == nil {
                // A baked loop plays the video through whole times, as it times the scene's other
                // motions.
                videoTimes[file] = videoFrames[file]
                    .map { pathTime($0.duration, input: input) } ?? input.time
            }
        }
        for (file, time) in videoTimes {
            guard let frames = videoFrames[file] else { continue }
            if decodesVideoAhead { frames.request(time) } else { try frames.advance(to: time) }
            videoFramesShown[file] = frames.frame
        }
        let visibleLayers = ordered.filter { layer in
            evaluated.layers[layer.id]!.layer.isVisible &&
                (lastPlacements[layer.id] == nil || lastInversePlacements[layer.id] != nil) &&
                (layer.capturesCanvas || layer.model != nil
                    || (layer.kind == .particles ? layer.hasParticles : picture(for: layer) != nil))
        }
        // On the canvas a solid model stands in the layer order, like the ones a script makes.
        let placed = visibleLayers.map { layer -> Drawn in
            layer.model != nil && document.camera?.perspective != true
                ? .model(staticModelFrame(layer, evaluated: evaluated)) : .layer(layer)
        }
        if modelRenderer == nil &&
            (!evaluated.models.isEmpty || visibleLayers.contains { $0.model != nil })
        {
            modelRenderer = try SceneModelRenderer(materials: allMeshMaterials, device: device)
        }
        var visible = modelRenderer == nil || evaluated.models.isEmpty
            ? placed
            : Self.interleave(
                visibleLayers,
                placed: placed,
                models: evaluated.models,
                place: { id in
                    evaluated.order[id] ?? document.layers.firstIndex { $0.id == id } ?? 0
                }
            )
        let lights = currentLights(evaluated.lights)
        var views = modelViews(
            camera: evaluated.camera,
            input: input,
            target: target,
            lights: lights
        )
        if document.modelStage != nil, document.camera?.perspective != true, modelRenderer != nil {
            if let floor = floorFrame(),
               let first = visible
               .firstIndex(where: { if case .model = $0 { true } else { false } })
            {
                visible.insert(.model(floor), at: first)
            }
            if let shadowLights = modelCamera?.shadowLights, !shadowLights.isEmpty {
                let casters = visible.compactMap { item -> SceneModelLayerFrame? in
                    if case let .model(model) = item { return model }
                    return nil
                }
                views.flat.shadows = try modelRenderer!.renderShadows(
                    lights: shadowLights, casters: casters, commandBuffer: commandBuffer,
                    rigs: rigs,
                    time: input.time
                )
            }
        }
        let layerPictures = try modelLayerPictures(
            evaluated: evaluated,
            commandBuffer: commandBuffer,
            input: input,
            targetSize: targetSize
        )
        // The frame's model layers share one depth buffer; the first pass clears it.
        var depthCleared = false
        func drawModels(
            _ models: [SceneModelLayerFrame],
            into texture: MTLTexture,
            clear: Bool
        ) throws {
            if modelRenderer == nil {
                modelRenderer = try SceneModelRenderer(materials: allMeshMaterials, device: device)
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = clear ? .clear : .load
            pass.colorAttachments[0].clearColor = backgroundClearColor
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = try modelDepth(
                width: texture.width,
                height: texture.height
            )
            pass.depthAttachment.loadAction = depthCleared ? .load : .clear
            pass.depthAttachment.clearDepth = 1
            pass.depthAttachment.storeAction = .store
            depthCleared = true
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw RendererError.textureAllocationFailed
            }
            defer { encoder.endEncoding() }
            for model in models {
                try modelRenderer!.draw(
                    model, view: model.perspective ? views.perspective : views.flat,
                    images: modelImages,
                    layerPictures: layerPictures, frame: .init(),
                    time: input.time, cursor: input.cursor, audio: input.audio,
                    format: texture.pixelFormat, encoder: encoder,
                    mipHistory: mipHistory, rigs: rigs
                )
            }
        }
        if document.camera?.perspective == true {
            try compositeInSpace(
                visible,
                evaluated: evaluated,
                views: views,
                layerPictures: layerPictures,
                target: target,
                commandBuffer: commandBuffer,
                input: input,
                targetSize: targetSize
            )
            try keepMipHistory(of: target, commandBuffer: commandBuffer)
            return
        }
        if allowsSinglePassComposite, let fetch = pipeline.compositeFetch(for: target.pixelFormat) {
            enum Segment {
                case batch([SceneLayer])
                case capture(SceneLayer)
                case models([SceneModelLayerFrame])
            }
            var segments: [Segment] = []
            var currentBatch: [SceneLayer] = []
            var currentModels: [SceneModelLayerFrame] = []
            func close() {
                if !currentBatch.isEmpty { segments.append(.batch(currentBatch)) }
                if !currentModels.isEmpty { segments.append(.models(currentModels)) }
                currentBatch.removeAll()
                currentModels.removeAll()
            }
            for item in visible {
                guard case let .layer(layer) = item else {
                    if case let .model(model) = item {
                        if !currentBatch.isEmpty { close() }
                        currentModels.append(model)
                    }
                    continue
                }
                if !currentModels.isEmpty { close() }
                // A layer whose effects read what lies below it needs the canvas drawn
                // up to it, as a canvas-capturing layer does.
                if layer.capturesCanvas || readsBackground(layer) {
                    close()
                    segments.append(.capture(layer))
                } else {
                    currentBatch.append(layer)
                }
            }
            close()

            try ensureAccumulation(
                width: target.width,
                height: target.height,
                format: target.pixelFormat
            )
            var source: MTLTexture?
            var nextIndex = 0

            for (segIndex, segment) in segments.enumerated() {
                let isLast = (segIndex == segments.count - 1)
                let destination = isLast ? target : accumulation[nextIndex]

                switch segment {
                case let .models(models):
                    // Drawn straight onto the canvas so far; the last segment has to end in the
                    // target.
                    if let current = source {
                        if isLast, current !== target {
                            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                                throw RendererError.textureAllocationFailed
                            }
                            blit.copy(from: current, to: target)
                            blit.endEncoding()
                            try drawModels(models, into: target, clear: false)
                            source = target
                        } else {
                            try drawModels(models, into: current, clear: false)
                        }
                    } else {
                        try drawModels(models, into: destination, clear: true)
                        source = destination
                        nextIndex = 1 - nextIndex
                    }

                case let .batch(layers):
                    var prepared: [PreparedLayer] = []
                    for layer in layers {
                        let drawn = evaluated.layers[layer.id]!
                        let layerTexture = try applyEffects(
                            to: drawn.layer, commandBuffer: commandBuffer, input: input,
                            targetSize: targetSize
                        )
                        prepared.append(PreparedLayer(
                            layerTexture: layerTexture,
                            uniforms: compositeUniforms(
                                for: drawn.layer,
                                drawn: drawn,
                                input: input,
                                targetSize: targetSize
                            ),
                            depth: layer.depthFile.flatMap { maskTextures[$0] }
                        ))
                    }

                    if let currentSource = source {
                        if currentSource !== destination {
                            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                                throw RendererError.textureAllocationFailed
                            }
                            blit.copy(
                                from: currentSource, sourceSlice: 0, sourceLevel: 0,
                                sourceOrigin: MTLOrigin(),
                                sourceSize: MTLSize(
                                    width: currentSource.width,
                                    height: currentSource.height,
                                    depth: 1
                                ),
                                to: destination, destinationSlice: 0, destinationLevel: 0,
                                destinationOrigin: MTLOrigin()
                            )
                            blit.endEncoding()
                        }
                    }

                    let pass = MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture = destination
                    if source == nil {
                        pass.colorAttachments[0].loadAction = .clear
                        pass.colorAttachments[0].clearColor = backgroundClearColor
                    } else {
                        pass.colorAttachments[0].loadAction = .load
                    }
                    pass.colorAttachments[0].storeAction = .store
                    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
                    else {
                        throw RendererError.textureAllocationFailed
                    }
                    encoder.setRenderPipelineState(fetch)
                    for item in prepared {
                        guard let scissor = Self.scissor(
                            for: item.uniforms,
                            width: target.width,
                            height: target.height
                        ) else {
                            continue
                        }
                        var uniforms = item.uniforms
                        encoder.setScissorRect(scissor)
                        encoder.setFragmentTexture(item.layerTexture, index: 1)
                        encoder.setFragmentTexture(item.depth ?? whiteMask, index: 2)
                        encoder.setFragmentBytes(
                            &uniforms,
                            length: MemoryLayout<LayerUniforms>.stride,
                            index: 0
                        )
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    }
                    encoder.endEncoding()
                    source = destination
                    nextIndex = 1 - nextIndex

                case let .capture(layer):
                    let drawn = evaluated.layers[layer.id]!
                    let uniforms = compositeUniforms(
                        for: drawn.layer,
                        drawn: drawn,
                        input: input,
                        targetSize: targetSize
                    )
                    let base = try source ?? backgroundTexture()
                    let layerTexture = try applyEffects(
                        to: drawn.layer, commandBuffer: commandBuffer, input: input,
                        targetSize: targetSize,
                        canvasSource: base, compositeUniforms: uniforms
                    )
                    try compositePass(
                        commandBuffer: commandBuffer, destination: destination, base: base,
                        layerTexture: layerTexture, uniforms: uniforms,
                        depth: layer.depthFile.flatMap { maskTextures[$0] }
                    )
                    source = destination
                    nextIndex = 1 - nextIndex
                }
            }
            if source == nil {
                // No visible layers: clear target to black
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].clearColor = backgroundClearColor
                pass.colorAttachments[0].storeAction = .store
                guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                    throw RendererError.textureAllocationFailed
                }
                encoder.endEncoding()
            }
            return
        }

        try ensureAccumulation(
            width: target.width,
            height: target.height,
            format: target.pixelFormat
        )
        var source = try backgroundTexture()
        var nextIndex = 0
        for item in visible {
            guard case let .layer(layer) = item else {
                guard case let .model(model) = item else { continue }
                if !accumulation.contains(where: { $0 === source }) {
                    // The canvas so far may still be the background's single pixel.
                    let destination = accumulation[nextIndex]
                    try compositePass(
                        commandBuffer: commandBuffer, destination: destination, base: source,
                        layerTexture: blackTexture, uniforms: Self.passThroughUniforms
                    )
                    source = destination
                    nextIndex = 1 - nextIndex
                }
                try drawModels([model], into: source, clear: false)
                continue
            }
            let drawn = evaluated.layers[layer.id]!
            let uniforms = compositeUniforms(
                for: drawn.layer,
                drawn: drawn,
                input: input,
                targetSize: targetSize
            )
            let layerTexture = try applyEffects(
                to: drawn.layer, commandBuffer: commandBuffer, input: input, targetSize: targetSize,
                canvasSource: source, compositeUniforms: uniforms
            )
            let destination = accumulation[nextIndex]
            try compositePass(
                commandBuffer: commandBuffer, destination: destination, base: source,
                layerTexture: layerTexture, uniforms: uniforms,
                depth: layer.depthFile.flatMap { maskTextures[$0] }
            )
            source = destination
            nextIndex = 1 - nextIndex
        }
        try compositePass(
            commandBuffer: commandBuffer, destination: target, base: source,
            layerTexture: blackTexture, uniforms: Self.passThroughUniforms
        )
    }

    /// The target pixels a layer can change. Outside its picture (pushed out by the
    /// depth shift at most) the composite returns the pixel below unchanged, so
    /// drawing only here gives the same image. nil when it covers nothing.
    private static func scissor(for u: LayerUniforms, width: Int, height: Int) -> MTLScissorRect? {
        let whole = MTLScissorRect(x: 0, y: 0, width: width, height: height)
        let det = u.placementColumn0.x * u.placementColumn1.y - u.placementColumn1.x * u
            .placementColumn0.y
        guard det != 0, u.uvScale.x != 0, u.uvScale.y != 0, u.viewSize.x != 0,
              u.viewSize.y != 0
        else {
            return whole
        }
        let reach = u.hasDepth != 0 ? abs(u.depthShift) : .zero
        var low = SIMD2<Float>(repeating: .infinity), high = SIMD2<Float>(repeating: -.infinity)
        for corner in [SIMD2<Float>(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)] {
            let layerUV = corner * (1 + 2 * reach) - reach
            let placed = (layerUV - 0.5 - u.uvOffset) / u.uvScale
            let relative = SIMD2(
                u.placementColumn1.y * placed.x - u.placementColumn1.x * placed.y,
                -u.placementColumn0.y * placed.x + u.placementColumn0.x * placed.y
            ) / det
            let targetUV = (relative + 0.5 + u.placementOffset - u.viewOrigin) / u.viewSize
            low = simd_min(low, targetUV)
            high = simd_max(high, targetUV)
        }
        guard low.x.isFinite, low.y.isFinite, high.x.isFinite, high.y.isFinite else {
            return whole
        }
        // Two pixels of slack for the GPU's own rounding of the same mapping.
        let size = SIMD2(Float(width), Float(height))
        let minPixel = simd_max((low * size).rounded(.down) - 2, .zero)
        let maxPixel = simd_min((high * size).rounded(.up) + 2, size)
        guard maxPixel.x > minPixel.x, maxPixel.y > minPixel.y else {
            return nil
        }
        return MTLScissorRect(
            x: Int(minPixel.x), y: Int(minPixel.y),
            width: Int(maxPixel.x - minPixel.x), height: Int(maxPixel.y - minPixel.y)
        )
    }

    /// A rectangle's part of the frame, as the picture the effects start from.
    struct CaptureRegion {
        var uniforms: LayerUniforms
        var width: Int
        var height: Int
    }

    /// The target UV box a rectangle in the scene projects to. nil when a corner is behind the eye.
    private func screenFootprint(
        of space: SceneSpace, world: simd_float4x4, viewProjection: simd_float4x4
    ) -> (origin: SIMD2<Float>, size: SIMD2<Float>)? {
        var low = SIMD2<Float>(repeating: .infinity), high = SIMD2<Float>(repeating: -.infinity)
        for (cx, cy) in [(-0.5, -0.5), (0.5, -0.5), (-0.5, 0.5), (0.5, 0.5)] as [(Float, Float)] {
            let local = SIMD4(
                cx * Float(space.width) + Float(space.offsetX),
                cy * Float(space.height) + Float(space.offsetY),
                0,
                1
            )
            let clip = viewProjection * world * local
            guard clip.w > 1e-6 else { return nil }
            let uv = SIMD2((clip.x / clip.w) * 0.5 + 0.5, 0.5 - (clip.y / clip.w) * 0.5)
            low = simd_min(low, uv)
            high = simd_max(high, uv)
        }
        let size = high - low
        guard size.x > 1e-6, size.y > 1e-6, size.x.isFinite, size.y.isFinite else { return nil }
        return (low, size)
    }

    /// The effects run at the layer's own size, not at the size it is shown: a small layer gets a
    /// coarse picture.
    private static func captureRegion(
        _ footprint: (origin: SIMD2<Float>, size: SIMD2<Float>),
        space: SceneSpace
    ) -> CaptureRegion {
        var uniforms = passThroughUniforms
        // The capture pass reads target UV = (UV - viewOrigin) / viewSize.
        uniforms.viewSize = 1 / footprint.size
        uniforms.viewOrigin = -footprint.origin / footprint.size
        let edge = Double(maxTextureEdge)
        return CaptureRegion(
            uniforms: uniforms, width: Int(min(max(space.width.rounded(), 1), edge)),
            height: Int(min(
                max(space.height.rounded(), 1),
                edge
            ))
        )
    }

    private struct PreparedLayer {
        let layerTexture: MTLTexture
        let uniforms: LayerUniforms
        let depth: MTLTexture?
    }

    /// A scene seen through its camera: each layer's picture, effects applied, stands as
    /// a plane in the scene; planes and model layers draw in order over one depth buffer.
    private func compositeInSpace(
        _ items: [Drawn], evaluated: SceneEvaluatedFrame,
        views: (flat: SceneModelRenderer.View, perspective: SceneModelRenderer.View),
        layerPictures: [Int: MTLTexture], target: MTLTexture,
        commandBuffer: MTLCommandBuffer, input: SceneFrameInput, targetSize: SIMD2<Float>
    ) throws {
        if modelRenderer == nil { modelRenderer = try SceneModelRenderer(
            materials: allMeshMaterials,
            device: device
        ) }
        enum Prepared {
            case model(SceneModelLayerFrame), plane(
                MTLTexture,
                SceneEvaluatedFrame.Layer,
                SceneSpace
            )
            case particles(SceneLayer, SceneEvaluatedFrame.Layer, SceneSpace)
            /// Runs its effects over everything drawn before it: the whole frame, or, with a
            /// space, the part of the frame that rectangle stands over.
            case capture(SceneLayer, SceneEvaluatedFrame.Layer, SceneSpace?)
        }
        var prepared: [Prepared] = []
        for item in items {
            switch item {
            case let .model(model): prepared.append(.model(model))
            case let .layer(layer):
                if layer.model != nil {
                    prepared.append(.model(staticModelFrame(layer, evaluated: evaluated)))
                    continue
                }
                if layer.capturesCanvas {
                    prepared.append(.capture(layer, evaluated.layers[layer.id]!, layer.space))
                    continue
                }
                guard var space = layer.space else { continue }
                if layer.kind == .text {
                    // The plane is the drawn string's picture, centred away from where its anchor
                    // sits.
                    guard let text = textTextures[layer.id], text.texture != nil else { continue }
                    space.width = text.canvasSize.x
                    space.height = text.canvasSize.y
                    space.offsetX = text.centerOffset.x
                    space.offsetY = text.centerOffset.y
                }
                let drawn = evaluated.layers[layer.id]!
                if drawsParticlesInSpace(drawn.layer) {
                    prepared.append(.particles(drawn.layer, drawn, space))
                    continue
                }
                let picture = try applyEffects(
                    to: drawn.layer,
                    commandBuffer: commandBuffer,
                    input: input,
                    targetSize: targetSize
                )
                prepared.append(.plane(picture, drawn, space))
            }
        }
        if document.camera?.sortsByDistance == true {
            /// Ties keep the listed order. The distance is the depth along the camera's axis
            /// (not the straight line to the eye): measured with the camera turned off the z axis
            /// and with plates off the axis. The perspective projection's w is that depth.
            func distance(_ item: Prepared) -> Float {
                let world: simd_float4x4 = switch item {
                case let .model(model): model.world
                case let .plane(_, drawn, space),
                     let .particles(_, drawn, space): drawn.world ?? space.matrix
                case .capture: matrix_identity_float4x4
                }
                return (views.flat.viewProjection * SIMD4(
                    world.columns.3.x,
                    world.columns.3.y,
                    world.columns.3.z,
                    1
                )).w
            }
            // A capturing layer reads what the sorted ones drew, so it stays after them.
            var keyed: [(distance: Float, index: Int, item: Prepared)] = []
            var captures: [Prepared] = []
            for (index, item) in prepared.enumerated() {
                if case .capture = item { captures.append(item) } else { keyed.append((
                    distance(item),
                    index,
                    item
                )) }
            }
            keyed
                .sort {
                    $0.distance == $1.distance ? $0.index < $1.index : $0.distance > $1.distance
                }
            prepared = keyed.map(\.item) + captures
        }
        var views = views
        if var lights = modelCamera?.shadowLights, !lights.isEmpty {
            for index in lights.indices {
                guard let moving = lights[index].dynamicLight,
                      views.flat.lights.indices.contains(moving) else { continue }
                let light = views.flat.lights[moving]
                lights[index].origin = [
                    Double(light.origin.x),
                    Double(light.origin.y),
                    Double(light.origin.z)
                ]
                lights[index].axis = [
                    Double(light.axis.x),
                    Double(light.axis.y),
                    Double(light.axis.z)
                ]
            }
            let casters = prepared.compactMap { item -> SceneModelLayerFrame? in
                if case let .model(model) = item { return model }
                return nil
            }
            let shadows = try modelRenderer!.renderShadows(
                lights: lights,
                casters: casters,
                commandBuffer: commandBuffer
            )
            views.flat.shadows = shadows
            views.perspective.shadows = shadows
        } else if modelRenderer?.shadowState.targets.isEmpty == false {
            modelRenderer?.shadowState.targets = [:]
        }
        let hasCapture = prepared.contains { if case .capture = $0 { true } else { false } }
        var drewBefore = false
        func openPass() throws -> MTLRenderCommandEncoder {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = drewBefore ? .load : .clear
            pass.colorAttachments[0].clearColor = backgroundClearColor
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = try modelDepth(
                width: target.width,
                height: target.height
            )
            pass.depthAttachment.loadAction = drewBefore ? .load : .clear
            pass.depthAttachment.clearDepth = 1
            // Kept only so the models drawn after a capturing layer test against those before it.
            pass.depthAttachment.storeAction = hasCapture ? .store : .dontCare
            drewBefore = true
            guard let opened = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw RendererError.textureAllocationFailed
            }
            return opened
        }
        var encoder: MTLRenderCommandEncoder? = try openPass()
        defer { encoder?.endEncoding() }
        for item in prepared {
            switch item {
            case let .model(model):
                try modelRenderer!.draw(
                    model, view: model.perspective ? views.perspective : views.flat,
                    images: modelImages,
                    layerPictures: layerPictures, frame: .init(),
                    time: input.time, cursor: input.cursor, audio: input.audio,
                    format: target.pixelFormat, encoder: encoder!,
                    mipHistory: mipHistory, rigs: rigs
                )
            case let .plane(picture, drawn, space):
                let tint = drawn.layer.tint
                let opacity = Float(min(
                    max(drawn.layer.opacity * tint.alpha * drawn.opacity, 0),
                    1
                ))
                // A fully transparent plane still writes depth, which would cut a hole in whatever
                // is drawn after it.
                guard opacity > 0 else { break }
                let local = simd_float4x4(columns: (
                    SIMD4(Float(space.width), 0, 0, 0), SIMD4(0, Float(space.height), 0, 0), SIMD4(
                        0,
                        0,
                        1,
                        0
                    ),
                    SIMD4(Float(space.offsetX), Float(space.offsetY), 0, 1)
                ))
                try modelRenderer!.drawPlane(
                    picture,
                    transform: views.flat
                        .viewProjection * (drawn.world ?? space.matrix) * local,
                    color: SIMD4(Float(tint.red), Float(tint.green), Float(tint.blue), opacity),
                    space: space,
                    format: target.pixelFormat, encoder: encoder!
                )
            case let .particles(layer, drawn, space):
                try drawParticlesInSpace(
                    layer, drawn: drawn, space: space, view: views.flat, format: target.pixelFormat,
                    encoder: encoder!
                )
            case let .capture(layer, drawn, space):
                encoder?.endEncoding()
                encoder = nil
                try ensureAccumulation(
                    width: target.width,
                    height: target.height,
                    format: target.pixelFormat
                )
                // Without a rectangle the layer covers the whole frame and needs no placement of
                // its own.
                var uniforms = Self.passThroughUniforms
                uniforms.opacity = Float(min(
                    max(layer.opacity * layer.tint.alpha * drawn.opacity, 0),
                    1
                ))
                uniforms
                    .blendMode = Int32(SceneBlendMode.allCases.firstIndex(of: layer.blendMode) ?? 0)
                // passThroughUniforms leaves hasLayer 0, which makes the composite return the base
                // untouched.
                uniforms.hasLayer = 1
                var region: CaptureRegion?
                if let space {
                    guard let footprint = screenFootprint(
                        of: space, world: drawn.world ?? space.matrix,
                        viewProjection: views.flat.viewProjection
                    ) else {
                        encoder = try openPass()
                        continue
                    }
                    region = Self.captureRegion(footprint, space: space)
                    // The picture the effects made stands over the footprint, its UV running across
                    // it.
                    uniforms.uvScale = 1 / footprint.size
                    uniforms.placementOffset = footprint.origin + 0.5 * footprint.size - 0.5
                }
                let layerTexture = try applyEffects(
                    to: drawn.layer, commandBuffer: commandBuffer, input: input,
                    targetSize: targetSize,
                    canvasSource: target, compositeUniforms: uniforms, captureRegion: region
                )
                try compositePass(
                    commandBuffer: commandBuffer, destination: accumulation[0], base: target,
                    layerTexture: layerTexture, uniforms: uniforms
                )
                guard let blit = commandBuffer.makeBlitCommandEncoder()
                else { throw RendererError.textureAllocationFailed }
                blit.copy(from: accumulation[0], to: target)
                blit.endEncoding()
                encoder = try openPass()
            }
        }
    }

    /// What the canvas draws, bottom to top.
    private enum Drawn {
        case layer(SceneLayer)
        case model(SceneModelLayerFrame)
    }

    /// The scene's layers, bottom to top, with the model layers scripts made, by their
    /// shared drawing order (`place` of a scene layer).
    private static func interleave(
        _ layers: [SceneLayer], placed: [Drawn], models: [SceneModelLayerFrame],
        place: (UUID) -> Int
    ) -> [Drawn] {
        var result: [Drawn] = []
        var pending = models.sorted { $0.order < $1.order }[...]
        for (layer, item) in zip(layers, placed) {
            let place = place(layer.id)
            while let next = pending.first, next.order < place {
                result.append(.model(next))
                pending.removeFirst()
            }
            result.append(item)
        }
        result += pending.map(Drawn.model)
        return result
    }

    /// The scene at rest (no cursor, loop start), at canvas resolution capped like the layers.
    func renderStill(input: SceneFrameInput = .rest) throws -> CGImage {
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
        try encode(into: target, commandBuffer: commandBuffer, input: input)
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
        target.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
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
        let scale = min(
            1,
            Double(maxEdge) / Double(max(document.canvasWidth, document.canvasHeight, 1))
        )
        func even(_ value: Double) -> Int {
            max(Int((value / 2).rounded()) * 2, 2)
        }
        return (
            even(Double(document.canvasWidth) * scale),
            even(Double(document.canvasHeight) * scale)
        )
    }
}

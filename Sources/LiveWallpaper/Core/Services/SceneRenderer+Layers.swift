import CoreGraphics
import Foundation
import ImageIO
import Metal
import simd

extension SceneRenderer {
    // MARK: - Composite

    struct LayerUniforms {
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
        /// Target UV → canvas UV, for the editor's zoom.
        var viewOrigin: SIMD2<Float>
        var viewSize: SIMD2<Float>
        var hasDepth: Int32
        var depthSteps: Int32
        var opacity: Float
        var maskRadius: Float
        var maskSoftness: Float
        var blendMode: Int32
        var maskMode: Int32
        var hasCursor: Int32
        var hasLayer: Int32
        var brightness: Float
        var saturation: Float
        var warmth: Float
        var hasColor: Int32
        var tintRed: Float
        var tintGreen: Float
        var tintBlue: Float
    }

    func compositePass(
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
        encoder.setRenderPipelineState(pipeline.composite(for: destination.pixelFormat))
        encoder.setFragmentTexture(base, index: 0)
        encoder.setFragmentTexture(layerTexture, index: 1)
        encoder.setFragmentTexture(depth ?? whiteMask, index: 2)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    func capturePass(
        commandBuffer: MTLCommandBuffer,
        destination: MTLTexture,
        base: MTLTexture,
        uniforms: LayerUniforms
    ) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw RendererError.textureAllocationFailed
        }
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline.capture)
        encoder.setFragmentTexture(base, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    static let passThroughUniforms = LayerUniforms(
        uvScale: .one, uvOffset: .zero, cursor: .zero, maskScale: .one, depthShift: .zero,
        placementColumn0: SIMD2(1, 0), placementColumn1: SIMD2(0, 1), placementOffset: .zero,
        viewOrigin: .zero, viewSize: .one, hasDepth: 0,
        depthSteps: 0,
        opacity: 0, maskRadius: 0,
        maskSoftness: 0, blendMode: 0, maskMode: -1, hasCursor: 0, hasLayer: 0,
        brightness: 0, saturation: 1, warmth: 0, hasColor: 0,
        tintRed: 1, tintGreen: 1, tintBlue: 1
    )

    /// Canvas UV → layer UV scale: aspect-fit, zoomed in just enough that the full
    /// parallax travel never samples past the edge. A cut-out of another shape keeps
    /// its size and proportions (the area outside it stays transparent).
    func layerUVScale(for layer: SceneLayer) -> SIMD2<Float> {
        let canvasAspect = Float(document.aspectRatio)
        let layerAspect: Float
        if let placement = layer.modelPlacement {
            // An imported model is selected by its footprint, which its placement gives in pixels.
            let size = SIMD2(max(Float(placement.size[0]), 1), max(Float(placement.size[1]), 1))
            return SIMD2(
                Float(document.canvasWidth) / size.x,
                Float(document.canvasHeight) / size.y
            )
        }
        if layer.kind == .text {
            // Text keeps its pixel size instead of filling the canvas, and does not
            // move with the parallax zoom.
            let size = textTextures[layer.id]?.canvasSize ?? SIMD2(1, 1)
            return SIMD2(
                Float(Double(document.canvasWidth) / size.x),
                Float(Double(document.canvasHeight) / size.y)
            )
        } else if layer.kind == .particles || layer.capturesCanvas {
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
        // A scene that sets its own travel draws layers at their size and lets edges
        // show, as the scenes it is made for expect.
        guard document.parallaxTravel == nil else { return depthTravel(for: layer) }
        let cursorTravel = Float(min(max(layer.parallaxDepth, 0), 1)) * Self.maxParallaxTravel
        return max(cursorTravel, depthTravel(for: layer))
    }

    /// The canvas fraction the cursor parallax and the camera shake move the layer by.
    private func viewShift(for layer: SceneLayer, input: SceneFrameInput) -> SIMD2<Float> {
        var shift: SIMD2<Float> = .zero
        if let travel = document.parallaxTravel {
            let depth = SIMD2(layer.parallaxDepth, layer.parallaxDepthY ?? layer.parallaxDepth)
                .clamped(lowerBound: SIMD2(repeating: -10), upperBound: SIMD2(repeating: 10))
            shift = input.parallax * SIMD2<Float>(depth) * Float(travel)
        } else {
            shift = input.parallax * Float(min(max(layer.parallaxDepth, 0), 1)) * Self
                .maxParallaxTravel
        }
        if let shake = document.cameraShake {
            let angles = loopAngles(shake.angularSpeeds, input: input)
            let offset = shake.offset(angles: SIMD2(Double(angles[0]), Double(angles[1])))
            shift += SIMD2(Float(offset.x / document.aspectRatio), Float(offset.y))
        }
        return shift
    }

    private func depthTravel(for layer: SceneLayer) -> Float {
        layer.hasDepth ? Float(min(max(layer.depthStrength, 0), 1)) * Self.maxParallaxTravel : 0
    }

    struct Placement {
        let column0: SIMD2<Float>
        let column1: SIMD2<Float>
        let offset: SIMD2<Float>
    }

    static func inversePlacement(_ matrix: simd_float3x3) -> simd_float3x3? {
        // A script can shrink one axis until Float's reciprocal determinant overflows,
        // even while every element of the inverse still fits in Float.
        let wide = simd_double3x3(columns: (
            SIMD3<Double>(matrix.columns.0), SIMD3<Double>(matrix.columns.1),
            SIMD3<Double>(matrix.columns.2)
        ))
        guard simd_determinant(wide) != 0 else { return nil }
        let inverse = simd_inverse(wide)
        let result = simd_float3x3(columns: (
            SIMD3<Float>(inverse.columns.0), SIMD3<Float>(inverse.columns.1),
            SIMD3<Float>(inverse.columns.2)
        ))
        // Collapsed geometry has no representable UV mapping for the GPU or picking.
        return [result.columns.0, result.columns.1, result.columns.2].allSatisfy {
            $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
        } ? result : nil
    }

    func placementMatrix(_ transform: SceneTransform) -> simd_float3x3 {
        let angle = Float(transform.rotation * .pi / 180)
        let scaleX = Float(transform.scale), scaleY = Float(transform.scaleY ?? transform.scale),
            aspect = Float(document.aspectRatio)
        let column0 = SIMD3(cos(angle), sin(angle) * aspect, 0) * scaleX
        let column1 = SIMD3(-sin(angle) / aspect, cos(angle), 0) * scaleY
        return simd_float3x3(columns: (column0, column1, SIMD3(
            0.5 + Float(transform.offsetX) - (column0.x + column1.x) * 0.5,
            0.5 + Float(transform.offsetY) - (column0.y + column1.y) * 0.5, 1
        )))
    }

    /// The inverse of the layer's placement in canvas UV. Rotation happens in a space
    /// with the canvas's proportions, so a turned layer is not skewed.
    func placement(for transform: SceneTransform) -> Placement {
        let aspect = Float(document.aspectRatio)
        let radians = Float(transform.rotation * .pi / 180)
        let c = cos(radians)
        let s = sin(radians)
        let inverseScaleX = 1 / Float(max(abs(transform.scale), 0.0001)) *
            (transform.scale < 0 ? -1 : 1)
        let sy = transform.scaleY ?? transform.scale
        let inverseScaleY = 1 / Float(max(abs(sy), 0.0001)) * (sy < 0 ? -1 : 1)
        return Placement(
            column0: SIMD2(c * inverseScaleX, -s * aspect * inverseScaleY),
            column1: SIMD2(s / aspect * inverseScaleX, c * inverseScaleY),
            offset: SIMD2(Float(transform.offsetX), Float(transform.offsetY))
        )
    }

    /// About one step per 10 pixels the march covers on screen; the linear
    /// refinement between steps keeps edges in place, and small shifts need few.
    private func depthSteps(
        shift: SIMD2<Float>,
        scale: SIMD2<Float>,
        targetSize: SIMD2<Float>
    ) -> Int32 {
        let pixels = shift / scale * targetSize
        let sweep = 2 * max(abs(pixels.x), abs(pixels.y))
        return Int32(min(max((sweep / 10).rounded(.up), 4), 12))
    }

    func compositeUniforms(
        for layer: SceneLayer,
        drawn: SceneEvaluatedFrame.Layer,
        input: SceneFrameInput,
        targetSize: SIMD2<Float>
    ) -> LayerUniforms {
        let canvasAspect = Float(document.aspectRatio)
        let link = drawn.color
        let custom = lastPlacements[layer.id]
        let placement: Placement
        if let custom {
            let inverse = lastInversePlacements[layer.id]!
            let center = custom * SIMD3(0.5, 0.5, 1)
            placement = Placement(
                column0: SIMD2(inverse.columns.0.x, inverse.columns.0.y),
                column1: SIMD2(inverse.columns.1.x, inverse.columns.1.y),
                offset: SIMD2(center.x, center.y) - 0.5
            )
        } else if layer.particleSystem != nil {
            // Simulated particles are drawn already placed on the canvas.
            placement = self.placement(for: .identity)
        } else {
            placement = self.placement(for: placedTransform(layer, drawn.transform))
        }
        let scale: SIMD2<Float> = custom == nil ? layerUVScale(for: layer) : .one
        func layerDirection(_ value: SIMD2<Float>) -> SIMD2<Float> {
            guard custom != nil else { return value * scale }
            let direction = lastInversePlacements[layer.id]! * SIMD3(value.x, value.y, 0)
            return SIMD2(direction.x, direction.y)
        }
        // The travel is a fraction of the canvas, converted into layer UV units.
        let shift = viewShift(for: layer, input: input)
        let offset = shift != .zero ? layerDirection(shift) : .zero
        var depthView = layer.depthFollowsCursor ? input.parallax : .zero
        if layer.depthAutoMotion > 0 {
            // A circle repeats every turn, so the drift loops.
            let angle = 2 * Float.pi * Float(max(layer.depthAutoCycles, 1)) * loopPhase(input.time)
            depthView += SIMD2(cos(angle), sin(angle) * 0.6) * Float(min(layer.depthAutoMotion, 1))
        }
        let depthShift = layerDirection(depthView.clamped(
            lowerBound: SIMD2(repeating: -1),
            upperBound: SIMD2(repeating: 1)
        )
            * depthTravel(for: layer))

        // Mask distances are measured in units of the canvas's shorter side.
        let maskScale = canvasAspect >= 1 ? SIMD2<Float>(canvasAspect, 1) : SIMD2<Float>(
            1,
            1 / canvasAspect
        )
        let mask = layer.cursorMask
        let hasTint = layer.tint.red != 1 || layer.tint.green != 1 || layer.tint.blue != 1
        return LayerUniforms(
            uvScale: scale,
            uvOffset: offset,
            cursor: input.cursor ?? .zero,
            maskScale: maskScale,
            depthShift: depthShift,
            placementColumn0: placement.column0,
            placementColumn1: placement.column1,
            placementOffset: placement.offset,
            viewOrigin: SIMD2(input.viewport.x, input.viewport.y),
            viewSize: SIMD2(input.viewport.z, input.viewport.w),
            hasDepth: layer.hasDepth && layer.depthFile
                .flatMap({ maskTextures[$0] }) != nil ? 1 : 0,
            depthSteps: depthSteps(shift: depthShift, scale: scale, targetSize: targetSize),
            opacity: Float(min(max(layer.opacity * layer.tint.alpha * drawn.opacity, 0), 1)),
            maskRadius: Float(max(mask?.radius ?? 0, 0.001)),
            maskSoftness: Float(min(max(mask?.softness ?? 0, 0), 1)),
            blendMode: Int32(SceneBlendMode.allCases.firstIndex(of: layer.blendMode) ?? 0),
            maskMode: mask.map { $0.mode == .hide ? 0 : 1 } ?? -1,
            hasCursor: input.cursor == nil ? 0 : 1,
            hasLayer: 1,
            brightness: Float(link.brightness),
            saturation: Float(max(link.saturation, 0)),
            warmth: Float(link.warmth),
            hasColor: (link.changesColor || hasTint) ? 1 : 0,
            tintRed: Float(layer.tint.red),
            tintGreen: Float(layer.tint.green),
            tintBlue: Float(layer.tint.blue)
        )
    }

    /// The picture a layer composites before its effects; particles draw their own.
    func picture(for layer: SceneLayer) -> MTLTexture? {
        if layer.kind == .text { return textTextures[layer.id]?.texture }
        if layer.usesMediaArtwork, let texture = mediaArtworkTextures[layer.id] { return texture }
        return layer.videoFile
            .flatMap { videoFramesShown[$0]?.texture } ?? textures[layer.imageFile]
    }

    func prepareMediaArtwork(_ media: SceneMediaState?) throws {
        let id = media?.isAvailable == true ? media!.artworkID : ""
        guard mediaArtworkID != id else { return }
        mediaArtworkTextures = [:]
        mediaArtworkID = ""
        guard !id.isEmpty, let data = media?.artworkData else { return }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw RendererError.imageDecodeFailed("media artwork")
        }
        for layer in document.layers where layer.usesMediaArtwork {
            let mask = try Self.decodeImage(url: fileURL(layer.imageFile))
            let width = mask.width, height = mask.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                let rect = CGRect(x: 0, y: 0, width: width, height: height)
                context.draw(image, in: rect)
                // Imported album frames use their image's alpha for rounded corners.
                context.setBlendMode(.destinationIn)
                context.draw(mask, in: rect)
                return true
            }
            guard drew else { throw RendererError.imageDecodeFailed("media artwork") }
            mediaArtworkTextures[layer.id] = try Self.makeTexture(
                device: device, pixelFormat: .rgba8Unorm, width: width, height: height, bytes: bytes
            )
        }
        mediaArtworkID = id
    }

    /// A text layer's position is where its aligned edge sits, so its picture is
    /// centred away from it, turned and scaled with the layer.
    func placedTransform(_ layer: SceneLayer, _ transform: SceneTransform) -> SceneTransform {
        guard layer.kind == .text,
              let offset = textTextures[layer.id]?.centerOffset else { return transform }
        // The rotation turns clockwise on the canvas, whose y points down; the offset
        // has y up.
        let radians = -transform.rotation * .pi / 180
        let scaled = SIMD2(
            offset.x * transform.scale,
            offset.y * (transform.scaleY ?? transform.scale)
        )
        let turned = SIMD2(
            scaled.x * cos(radians) - scaled.y * sin(radians),
            scaled.x * sin(radians) + scaled.y * cos(radians)
        )
        var placed = transform
        placed.offsetX += turned.x / Double(document.canvasWidth)
        placed.offsetY -= turned.y / Double(document.canvasHeight)
        return placed
    }

    func prepareText(_ layer: SceneLayer) throws {
        guard let text = layer.text else {
            textTextures[layer.id] = nil
            return
        }
        if textTextures[layer.id]?.text == text { return }
        guard let raster = try SceneTextRasterizer
            .render(text, fontURL: text.fontFile.map(fileURL))
        else {
            textTextures[layer.id] = TextTexture(
                text: text,
                texture: nil,
                canvasSize: SIMD2(1, 1),
                centerOffset: .zero
            )
            return
        }
        let texture = try Self.makeTexture(
            device: device, pixelFormat: .rgba8Unorm, width: raster.width, height: raster.height,
            bytes: raster.bytes
        )
        textTextures[layer.id] = TextTexture(
            text: text, texture: texture, canvasSize: raster.canvasSize,
            centerOffset: raster.centerOffset
        )
    }
}

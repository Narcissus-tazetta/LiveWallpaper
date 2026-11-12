import Foundation
import Metal
import simd

extension SceneRenderer {
    /// The pictures of the layers model materials sample, effects applied even where the layer
    /// itself
    /// is hidden. Encoded before any pass of the frame opens.
    func modelLayerPictures(
        evaluated: SceneEvaluatedFrame, commandBuffer: MTLCommandBuffer, input: SceneFrameInput,
        targetSize: SIMD2<Float>
    ) throws -> [Int: MTLTexture] {
        guard let sampled = modelRenderer?.sampledLayerObjectIDs,
              !sampled.isEmpty else { return [:] }
        var pictures: [Int: MTLTexture] = [:]
        for layer in document.layers {
            guard let id = layer.objectID, sampled.contains(id),
                  var drawn = evaluated.layers[layer.id]?.layer else { continue }
            drawn.isVisible = true
            pictures[id] = try applyEffects(
                to: drawn,
                commandBuffer: commandBuffer,
                input: input,
                targetSize: targetSize
            )
        }
        return pictures
    }

    func staticModelFrame(
        _ layer: SceneLayer,
        evaluated: SceneEvaluatedFrame
    ) -> SceneModelLayerFrame {
        let drawn = evaluated.layers[layer.id]!
        if let placement = drawn.layer.modelPlacement,
           let shapes = importedShapes[layer.id]?.shapes
        {
            let tint = drawn.layer.tint
            return SceneModelLayerFrame(
                serial: 0, order: 0, alpha: Float(drawn.layer.opacity * drawn.opacity),
                color: SIMD3(Float(tint.red), Float(tint.green), Float(tint.blue)),
                world: placement.world(
                    transform: drawn.transform, canvasWidth: Double(document.canvasWidth),
                    canvasHeight: Double(document.canvasHeight)
                ),
                perspective: false, shapes: shapes,
                materialValues: document.modelStage?
                    .materialValues(canvasHeight: Double(document.canvasHeight)) ?? [:],
                castsShadow: drawn.layer.castsShadow ?? true, rig: layer.model?.skeleton
            )
        }
        let shape = staticShapes[layer.id]?.shape
            ?? evaluated.instances[layer.id].flatMap { staticShapes[$0]?.shape }
            ?? staticShapes.values.first { $0.model == layer.model }?.shape
            ?? layer.model?.shape
            ?? SceneModelLayerFrame.Shape(
                material: nil, components: 0, vertices: [], indices: nil
            )
        let tint = drawn.layer.tint
        return SceneModelLayerFrame(
            serial: 0, order: 0, alpha: Float(drawn.layer.opacity * drawn.opacity),
            color: SIMD3(Float(tint.red), Float(tint.green), Float(tint.blue)),
            world: drawn.world ?? layer.space?.matrix ?? matrix_identity_float4x4,
            perspective: false, shapes: [shape],
            materialValues: drawn.layer.modelValues ?? [:],
            // The shadow pass draws the shape unposed, so a skinned model casts none.
            castsShadow: layer.model?.skeleton == nil && (drawn.layer.castsShadow ?? true),
            rig: layer.model?.skeleton
        )
    }

    /// The stage's floor: a wide level square at its height, centred under the canvas.
    func floorFrame() -> SceneModelLayerFrame? {
        guard let stage = document.modelStage, let floor = stage.floor,
              let material = floorMaterialIndex else { return nil }
        let width = Float(document.canvasWidth), height = Float(document.canvasHeight)
        let y = Float(1 - floor.height) * height, reach = max(width, height) * 4, x = width / 2
        let corners: [SIMD2<Float>] = [
            SIMD2(x - reach, -reach),
            SIMD2(x + reach, -reach),
            SIMD2(x + reach, reach),
            SIMD2(x - reach, reach)
        ]
        let vertices: [Float] = corners.flatMap { corner -> [Float] in [
            corner.x,
            y,
            corner.y,
            0,
            1,
            0
        ] }
        let shape = SceneModelLayerFrame.Shape(
            material: material,
            components: 0b11,
            vertices: vertices,
            indices: [0, 2, 1, 0, 3, 2]
        )
        return SceneModelLayerFrame(
            serial: 0, order: 0, alpha: 1, color: SIMD3(repeating: 1),
            world: matrix_identity_float4x4, perspective: false,
            shapes: [shape], materialValues: stage.materialValues(canvasHeight: Double(height)),
            castsShadow: false
        )
    }

    /// Particles with nothing to run them through (effects, a painted area, a picture of
    /// what is behind) are sprites in the scene itself rather than a picture on a plane.
    func drawsParticlesInSpace(_ layer: SceneLayer) -> Bool {
        guard layer.kind == .particles, let system = layer.particleSystem,
              particleSimulators[layer.id] != nil else { return false }
        return !system.refracts && layer.activeEffects.isEmpty && graphRenderers[layer.id] == nil
            && paintOverride?.effectID != layer.id
    }

    func drawParticlesInSpace(
        _ layer: SceneLayer, drawn: SceneEvaluatedFrame.Layer, space: SceneSpace,
        view: SceneModelRenderer.View,
        format: MTLPixelFormat, encoder: MTLRenderCommandEncoder
    ) throws {
        guard let simulator = particleSimulators[layer.id] else { return }
        let toCanvas = particleLocalToCanvas(currentTransform(layerID: layer.id) ?? layer.transform)
        let tint = drawn.layer.tint
        let opacity = Float(min(max(drawn.layer.opacity * tint.alpha * drawn.opacity, 0), 1))
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
            let style = SceneModelRenderer.SpaceParticleStyle(
                column0: SIMD2(toCanvas.columns.0.x, toCanvas.columns.0.y),
                column1: SIMD2(toCanvas.columns.1.x, toCanvas.columns.1.y),
                origin: SIMD2(toCanvas.columns.2.x, toCanvas.columns.2.y),
                plane: SIMD4(
                    Float(space.width),
                    Float(space.height),
                    Float(space.offsetX),
                    Float(space.offsetY)
                ),
                tint: SIMD4(Float(tint.red), Float(tint.green), Float(tint.blue), opacity),
                brightness: Float(system.brightness),
                cutout: system.cutout
                    .map { SIMD3(Float($0.start), Float($0.end), Float($0.opacity)) },
                blend: system.blend,
                fog: system.receivesFog == true ? document.camera?.fog : nil
            )
            try modelRenderer!.drawParticles(
                instances: buffer, count: instances.count, texture: texture,
                world: drawn.world ?? space.matrix, view: view,
                style: style, depthTest: space.depthTest, depthWrite: space.depthWrite,
                format: format, encoder: encoder
            )
        }
    }

    /// The number of levels measured for 1280x720, 1600x900 and 512x512 (7, 7, 6) and for 640x360
    /// and 1024x256 (6, 5): halved until the short side is 16 or less, the base included.
    static func mipLevelCount(width: Int, height: Int) -> Int {
        let shortSide = min(width, height)
        guard shortSide > 0 else { return 1 }
        return max(1, Int(ceil(log2(Double(shortSide) / 16))) + 1)
    }

    func keepMipHistory(of target: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        guard readsMipHistory, target.width > 0, target.height > 0 else { return }
        if mipHistory?.width != target.width || mipHistory?.height != target.height || mipHistory?
            .pixelFormat != target.pixelFormat
        {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: target.pixelFormat, width: target.width, height: target.height,
                mipmapped: false
            )
            descriptor.mipmapLevelCount = Self.mipLevelCount(
                width: target.width,
                height: target.height
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor)
            else { throw RendererError.textureAllocationFailed }
            mipHistory = texture
        }
        guard let blit = commandBuffer.makeBlitCommandEncoder()
        else { throw RendererError.textureAllocationFailed }
        blit.copy(from: target, to: mipHistory!)
        blit.generateMipmaps(for: mipHistory!)
        blit.endEncoding()
    }

    /// Where model layers are seen from and lit by: the editor's stage for imported models
    /// when the scene has one, else the scene's camera.
    var modelCamera: SceneCamera? {
        document.modelStage.map { $0.camera(
            canvasWidth: Double(document.canvasWidth),
            canvasHeight: Double(document.canvasHeight)
        ) }
            ?? document.camera
    }

    /// The scripted lights as scripts left them, the scene file's values where they left none.
    func currentLights(_ scripted: [Int: SceneLightState]) -> [SceneModelRenderer.DynamicLight] {
        (modelCamera?.dynamicLights ?? []).map { base in
            if let state = scripted[base.objectID] { return .init(
                origin: state.origin,
                axis: state.axis,
                color: state.color
            ) }
            return .init(
                origin: SIMD3(base.origin.map(Float.init)),
                axis: SIMD3(base.axis.map(Float.init)),
                color: SIMD3(base.color.map(Float.init))
            )
        }
    }

    func modelViews(
        camera: SceneCameraState?,
        input: SceneFrameInput,
        target: MTLTexture,
        lights: [SceneModelRenderer.DynamicLight]
    )
        -> (flat: SceneModelRenderer.View, perspective: SceneModelRenderer.View)
    {
        let scene = modelCamera
        let ambient = SIMD3((scene?.ambientColor ?? [0, 0, 0]).map(Float.init))
        let skylight = SIMD3((scene?.skylightColor ?? [0, 0, 0]).map(Float.init))
        var state = camera ?? scene.map { scene in
            var state = SceneCameraState(
                eye: SIMD3(scene.eye.map(Float.init)),
                center: SIMD3(scene.center.map(Float.init)),
                up: SIMD3(scene.up.map(Float.init)),
                zoom: 1,
                fov: Float(scene.fov),
                nearZ: Float(scene.nearZ),
                farZ: Float(scene.farZ)
            )
            state.isPlacedByScript = false
            return state
        }
        if let path = scene?.path, var moved = state, !moved.isPlacedByScript {
            let pose = path.transform(at: pathTime(path.period, input: input))
            moved.eye = pose.eye
            moved.center = pose.center
            moved.up = pose.up
            state = moved
        }
        // Fog and highlights on a solid model of a canvas scene are measured from a point
        // 2000 in front of the canvas's centre, not from the camera's eye.
        let eye: SIMD3<Float> = scene?.perspective != true && document.layers
            .contains { $0.model != nil }
            ? SIMD3(Float(document.canvasWidth) / 2, Float(document.canvasHeight) / 2, 2000) :
            state?.eye ?? .zero
        var canvas = SceneModelRenderer.View(
            viewProjection: SceneModelRenderer.canvasProjection(
                width: Double(document.canvasWidth), height: Double(document.canvasHeight),
                viewport: input.viewport
            ),
            eye: eye, ambient: ambient, skylight: skylight, lights: lights,
            screen: SIMD3(
                Float(target.width),
                Float(target.height),
                Float(target.width) / Float(target.height)
            )
        )
        if let stage = document.modelStage, document.camera?.perspective != true {
            (canvas.viewProjection, canvas.eye) = stage.viewProjection(
                canvasWidth: Double(document.canvasWidth),
                canvasHeight: Double(document.canvasHeight), viewport: input.viewport
            )
        }
        guard let state, scene?.perspective == true else { return (canvas, canvas) }
        // A camera scene fills the target, whatever its shape.
        let aspect = Float(target.width) / Float(target.height)
        var flat = canvas, perspective = canvas
        flat.viewProjection = SceneModelRenderer.perspective(state, aspect: aspect)
        let back = simd_normalize(state.eye - state.center)
        flat.cameraRight = simd_normalize(simd_cross(state.up, back))
        flat.cameraUp = simd_cross(back, flat.cameraRight)
        perspective.viewProjection = SceneModelRenderer.unitPerspective(state, aspect: aspect)
        return (flat, perspective)
    }

    func modelDepth(width: Int, height: Int) throws -> MTLTexture {
        if let depth = modelDepthTexture, depth.width == width,
           depth.height == height { return depth }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: SceneModelRenderer.depthFormat, width: width, height: height,
            mipmapped: false
        )
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor)
        else { throw RendererError.textureAllocationFailed }
        modelDepthTexture = texture
        return texture
    }
}

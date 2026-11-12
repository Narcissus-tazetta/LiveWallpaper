import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Metal
import simd

/// What changes from frame to frame. Positions are in canvas UV space (origin top-left).
struct SceneFrameInput: Equatable {
    /// -1...1 per axis, already eased; positive x/y move the sampled area right/down.
    var parallax: SIMD2<Float> = .zero
    /// nil when no cursor masks should react (cursor elsewhere, or not allowed).
    var cursor: SIMD2<Float>?
    /// Seconds into the scene loop; with `isRealTime`, seconds since the scene was
    /// first shown.
    var time: Double = 0
    /// Real-time effects take `time` at their own speed. Otherwise (a baked loop, a
    /// preview of it) they keep their speed through the loop's first half and ease onto
    /// whole repeats over the second, so the loop closes.
    var isRealTime = false
    /// The part of the canvas drawn into the target: origin and size in canvas UV.
    /// Only the editor zooms; everything else draws the whole canvas.
    var viewport = SIMD4<Float>(0, 0, 1, 1)
    /// Presses and releases of the primary button on the desktop since the scripts last
    /// ran, oldest first. Only scripts see them.
    var pointerPresses: [ScenePointerPress] = []
    /// What is playing, for scripts that read it; nil where nothing provides it (a bake).
    var media: SceneMediaState?
    /// The system audio, for effects that react to it; nil plays them silent.
    var audio: SceneAudioSpectrum?
    /// Pixels of the surface drawn on screen, for scripts told when it changes; nil off screen.
    var screenSize: SIMD2<Int>?
    /// Author properties for scene evaluation and scripts; nil when no custom properties.
    var userProperties: [String: WebPropertyValue]?

    static let rest = SceneFrameInput()
}

struct ScenePointerPress: Equatable {
    var isDown: Bool
    /// Canvas UV, origin top-left.
    var position: SIMD2<Float>
}

struct SceneMediaState: Equatable {
    enum Playback: String {
        case stopped, playing, paused
    }

    /// False while the track information cannot be read (no automation permission).
    var isAvailable: Bool
    var playback: Playback = .stopped
    var title = ""
    var artist = ""
    var album = ""
    var position: Double = 0
    var duration: Double = 0
    /// Changes whenever the artwork does; empty without artwork.
    var artworkID = ""
    var palette: SceneMediaPalette?
    var artworkData: Data?
}

/// A mask or flow map being painted, shown before it is saved to a file.
struct ScenePaintOverride {
    enum Target: Equatable {
        case mask
        case flow
        /// When each pixel moves (grey), for real-time effects.
        case timeOffset

        /// Painted as one grey channel; a flow holds a direction.
        var isGrey: Bool {
            self != .flow
        }
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
        case bufferAllocationFailed

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
            case .bufferAllocationFailed:
                return "Could not allocate a particle instance buffer"
            }
        }
    }

    /// Longest edge a layer is decoded at; larger images only cost memory.
    static let maxTextureEdge = 4096
    /// Fraction of the canvas a depth-1 layer can travel each way.
    static let maxParallaxTravel: Float = 0.05

    struct Pipeline {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let composite: MTLRenderPipelineState
        let capture: MTLRenderPipelineState
        let effect: MTLRenderPipelineState
        let particlesOver: MTLRenderPipelineState
        let particlesAdd: MTLRenderPipelineState
        /// Simulated particles, for an ordinary and a wide canvas.
        let particleSystemOver: MTLRenderPipelineState
        let particleSystemAdd: MTLRenderPipelineState
        let particleSystemOverWide: MTLRenderPipelineState
        let particleSystemAddWide: MTLRenderPipelineState
        /// Single-pass compositing; nil where the GPU cannot read its framebuffer.
        let compositeFetch: MTLRenderPipelineState?
        /// The same two for a high-dynamic-range canvas (half floats).
        let compositeWide: MTLRenderPipelineState
        let compositeFetchWide: MTLRenderPipelineState?

        func composite(for format: MTLPixelFormat) -> MTLRenderPipelineState {
            format == .rgba16Float ? compositeWide : composite
        }

        let library: MTLLibrary

        func compositeFetch(for format: MTLPixelFormat) -> MTLRenderPipelineState? {
            format == .rgba16Float ? compositeFetchWide : compositeFetch
        }
    }

    static let pipelineLock = NSLock()
    nonisolated(unsafe) static var sharedPipeline: Pipeline?

    /// Decoded layer images shared by every renderer alive (the editor preview, each
    /// desktop, the baker): decoding a large photo takes seconds and renderers are
    /// recreated on the main thread. Weak, so an image is freed with its last user.
    final class TextureCacheEntry {
        weak var texture: MTLTexture?

        init(_ texture: MTLTexture) {
            self.texture = texture
        }
    }

    static let textureCacheLock = NSLock()
    nonisolated(unsafe) static var textureCache: [String: TextureCacheEntry] = [:]

    let pipeline: Pipeline
    var graphRenderers: [UUID: SceneRenderGraphRenderer] = [:]
    /// Per converted shader: its picture one loop later, and the fade into its own.
    var loopFadeTargets: [UUID: (later: MTLTexture, faded: MTLTexture)] = [:]
    var loopFadePipelines: [UInt: MTLRenderPipelineState] = [:]
    var modelRenderer: SceneModelRenderer?
    var modelImages: [String: MTLTexture] = [:]
    var modelDepthTexture: MTLTexture?
    struct StaticShapeCache {
        var model: SceneStaticModel
        var shape: SceneModelLayerFrame.Shape
    }

    /// The mesh and buffers of each layer that is a solid model.
    private(set) var staticShapes: [UUID: StaticShapeCache] = [:]
    /// The materials model layers draw with: the scene's mesh materials, then those of the
    /// models the editor imported, then the floor's.
    var allMeshMaterials: [SceneMeshMaterial?] = []
    struct ImportedShapeCache {
        var parts: [SceneStaticModel]
        var materials: [Int]
        /// `parts` in order, each with its material and buffers.
        var shapes: [SceneModelLayerFrame.Shape]
    }

    /// The shapes of each model the editor imported, `model` then `modelParts`.
    var importedShapes: [UUID: ImportedShapeCache] = [:]
    var floorMaterialIndex: Int?
    let graphTexturePool = SceneTexturePool()
    private var graphTextures: [String: MTLTexture] = [:]
    var graphResources: [UUID: [String: MTLTexture]] = [:]
    var rigs: SceneSkeletonRegistry?
    var placementEvaluator: ScenePlacementEvaluator?
    var lastPlacements: [UUID: simd_float3x3] = [:]
    var lastInversePlacements: [UUID: simd_float3x3] = [:]
    private(set) var document: SceneDocument
    let videoPath: String
    var textures: [String: MTLTexture] = [:]
    var mediaArtworkID = ""
    var mediaArtworkTextures: [UUID: MTLTexture] = [:]
    /// By file name; loaded by the owner (SceneMetalLayer, prepareVideos) because
    /// reading a video's tracks is asynchronous. Until then the layer shows its image.
    var videoFrames: [String: SceneVideoFrames] = [:]
    /// The frame each video layer draws, held until the next encode so the GPU can read it.
    var videoFramesShown: [String: SceneVideoFrames.Frame] = [:]
    /// Live drawing decodes on the video's queue and shows the newest frame (one
    /// request behind); otherwise each frame waits for its exact video frame (a bake).
    var decodesVideoAhead = false
    struct TextTexture {
        let text: SceneText
        let texture: MTLTexture?
        let canvasSize: SIMD2<Double>
        let centerOffset: SIMD2<Double>
    }

    /// Drawn again only when the text or its style changes (a script can change it).
    var textTextures: [UUID: TextTexture] = [:]
    var maskTextures: [String: MTLTexture] = [:]
    var flowTextures: [String: MTLTexture] = [:]
    var effectLayerTargets: [UUID: MTLTexture] = [:]
    var effectScratchTargets: [SIMD2<Int>: MTLTexture] = [:]
    var usedEffectScratchSizes: Set<SIMD2<Int>> = []
    var captureTargets: [UUID: MTLTexture] = [:]
    var particleTargets: [UUID: MTLTexture] = [:]
    var particleSimulators: [UUID: SceneParticleSimulator] = [:]
    var particleInstanceBuffers = SceneParticleInstanceBuffers()
    /// The input time the simulators last advanced to.
    var particleTime: Double?
    /// Script requests from frames that were not drawn, applied with the next one.
    var pendingParticleControls: [UUID: SceneParticleSimulator.Control] = [:]
    /// By file, with mipmaps: sprites are often drawn far smaller than their image.
    var particleTextures: [String: MTLTexture] = [:]
    var accumulation: [MTLTexture] = []
    private var finishingCanvas: MTLTexture?
    private var finishingRenderer: SceneRenderGraphRenderer?
    private var finishingImages: [String: MTLTexture] = [:]
    private var solidBackground: MTLTexture?

    var backgroundClearColor: MTLClearColor {
        let color = document.backgroundColor ?? [0, 0, 0]
        return MTLClearColor(red: color[0], green: color[1], blue: color[2], alpha: 1)
    }

    private func finishingImage(_ file: String) throws -> MTLTexture {
        let alpha: ImageAlpha = document.finishing?
            .straightAlphaImages == true ? .straightDropped : .premultiplied
        return try Self.cachedTexture(url: fileURL(file), variant: "rgba-\(alpha)") { url in
            try Self.decodeRGBA(url: url, device: device, alpha: alpha)
        }
    }

    /// The canvas before any layer: the background colour, as a texture to draw over.
    func backgroundTexture() throws -> MTLTexture {
        guard let color = document.backgroundColor else { return blackTexture }
        if let solidBackground { return solidBackground }
        let bytes = color.map { UInt8((min(max($0, 0), 1) * 255).rounded()) } + [255]
        solidBackground = try Self.makeSolidTexture(
            device: device,
            pixelFormat: .rgba8Unorm,
            bytes: bytes
        )
        return solidBackground!
    }

    let blackTexture: MTLTexture
    let whiteTexture: MTLTexture
    let whiteMask: MTLTexture
    let stillFlow: MTLTexture
    /// Fraction of the displayed size that effects are computed at. The baked video
    /// uses full resolution.
    var effectResolutionScale: Float = 1
    /// Off forces the ping-pong composite that other GPUs use.
    var allowsSinglePassComposite = true
    /// Loop phase of the last encoded frame, for mapping preview clicks.
    var lastPhase: Double = 0
    var lastTime: Double = 0
    var paintOverride: ScenePaintOverride?
    var paintOverrideTexture: MTLTexture?
    /// Tints where the painted mask or flow map applies, so weak motion can be seen.
    var showsPaintTint = true
    /// The part of the day the links see: now unless the owner says otherwise (a bake
    /// fixes it at its start, the editor shows what it simulates).
    var timeOfDay: SceneTimeOfDay
    /// Evaluates scripts only off the main thread: for bakes (live drawing evaluates
    /// them on SceneScriptWorker and passes the frame in).
    lazy var frameEvaluator = SceneFrameEvaluator(
        budget: .offline,
        storage: SceneScriptStorage.shared.snapshot(path: videoPath)
    )
    var lastFrame: SceneEvaluatedFrame?
    var lastDrawnInput: SceneFrameInput? {
        lastFrame?.input
    }

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
        timeOfDay = document.timeOfDay(at: Date())
        blackTexture = try Self.makeSolidTexture(
            device: pipeline.device,
            pixelFormat: .rgba8Unorm,
            bytes: [0, 0, 0, 255]
        )
        whiteTexture = try Self.makeSolidTexture(
            device: pipeline.device,
            pixelFormat: .rgba8Unorm,
            bytes: [255, 255, 255, 255]
        )
        whiteMask = try Self.makeSolidTexture(
            device: pipeline.device,
            pixelFormat: .r8Unorm,
            bytes: [255]
        )
        stillFlow = try Self.makeSolidTexture(
            device: pipeline.device,
            pixelFormat: .rgba8Unorm,
            bytes: [128, 128, 0, 255]
        )
        try loadTextures()
    }

    func update(document: SceneDocument) throws {
        particleInstanceBuffers.removeAll()
        self.document = document
        try loadTextures()
    }

    var usesCursor: Bool {
        document.usesCursor
    }

    /// Video layers whose frames are not loaded yet, with the file to load.
    var videosToLoad: [(file: String, url: URL)] {
        Set(document.layers.compactMap(\.videoFile)).subtracting(videoFrames.keys).sorted().map { (
            $0,
            fileURL($0)
        ) }
    }

    func install(_ frames: SceneVideoFrames, videoFile: String) {
        guard document.layers.contains(where: { $0.videoFile == videoFile }) else { return }
        videoFrames[videoFile] = frames
    }

    /// Loads every video layer, for renderers that draw a fixed sequence of frames.
    func prepareVideos() async throws {
        for video in videosToLoad {
            try await install(
                SceneVideoFrames.load(url: video.url, device: device),
                videoFile: video.file
            )
        }
    }

    /// Shows `override` in place of that effect's saved mask or flow map, with a tint
    /// marking where it is painted. nil goes back to the saved files.
    func setPaintOverride(_ override: ScenePaintOverride?) throws {
        paintOverride = override
        guard let override else {
            paintOverrideTexture = nil
            return
        }
        let format: MTLPixelFormat = override.target.isGrey ? .r8Unorm : .rgba8Unorm
        if let texture = paintOverrideTexture, texture.width == override.width,
           texture.height == override.height,
           texture.pixelFormat == format
        {
            texture.replace(
                region: MTLRegionMake2D(0, 0, override.width, override.height), mipmapLevel: 0,
                withBytes: override.bytes,
                bytesPerRow: override.width * (format == .r8Unorm ? 1 : 4)
            )
            return
        }
        paintOverrideTexture = try Self.makeTexture(
            device: device, pixelFormat: format, width: override.width, height: override.height,
            bytes: override.bytes
        )
    }

    /// Canvas UV → the layer's UV with the layer at rest (no parallax travel).
    func layerUV(canvasUV: SIMD2<Float>, layerID: UUID) -> SIMD2<Float>? {
        guard let layer = document.layers.first(where: { $0.id == layerID }) else {
            return nil
        }
        if lastPlacements[layerID] != nil {
            guard let inverse = lastInversePlacements[layerID] else { return nil }
            let point = inverse * SIMD3(canvasUV.x, canvasUV.y, 1)
            return SIMD2(point.x, point.y)
        }
        let placement = placement(for: placedTransform(
            layer,
            currentTransform(layerID: layerID) ?? layer.pose(at: lastPhase, time: lastTime)
                .transform
        ))
        let relative = canvasUV - 0.5 - placement.offset
        let placed = placement.column0 * relative.x + placement.column1 * relative.y + 0.5
        return (placed - 0.5) * layerUVScale(for: layer) + 0.5
    }

    func readsBackground(_ layer: SceneLayer) -> Bool {
        if graphRenderers[layer.id]?.graph.readsBackground == true { return true }
        if layer.particleSystem?.refracts == true { return true }
        return layer.activeEffects.contains { graphRenderers[$0.id]?.graph.readsBackground == true }
    }

    /// Canvas UV → layer UV as an affine matrix, for effects that place the cursor on
    /// their layer; identity for layers drawn over the whole canvas.
    func layerFromCanvas(_ layer: SceneLayer) -> simd_float3x3 {
        guard !layer.capturesCanvas, let origin = layerUV(canvasUV: .zero, layerID: layer.id),
              let right = layerUV(canvasUV: SIMD2(1, 0), layerID: layer.id),
              let down = layerUV(canvasUV: SIMD2(0, 1), layerID: layer.id)
        else { return matrix_identity_float3x3 }
        return simd_float3x3(columns: (
            SIMD3(right - origin, 0), SIMD3(down - origin, 0), SIMD3(origin, 1)
        ))
    }

    /// Layer UV → canvas UV, the inverse of layerUV(canvasUV:layerID:); for markers
    /// drawn over the preview.
    func canvasUV(layerUV: SIMD2<Float>, layerID: UUID) -> SIMD2<Float>? {
        guard let layer = document.layers.first(where: { $0.id == layerID }) else {
            return nil
        }
        if let matrix = lastPlacements[layerID] {
            let point = matrix * SIMD3(layerUV.x, layerUV.y, 1)
            return SIMD2(point.x, point.y)
        }
        return canvasUV(
            layerUV: layerUV,
            layer: layer,
            transform: currentTransform(layerID: layerID) ?? layer.pose(
                at: lastPhase,
                time: lastTime
            ).transform
        )
    }

    /// Where the layer's picture would sit with `transform`, at rest.
    func canvasUV(
        layerUV: SIMD2<Float>,
        layer: SceneLayer,
        transform: SceneTransform
    ) -> SIMD2<Float> {
        if let current = lastPlacements[layer.id] {
            let previous = currentTransform(layerID: layer.id) ?? layer.pose(
                at: lastPhase,
                time: lastTime
            ).transform
            let matrix = placementMatrix(transform) * simd_inverse(placementMatrix(previous)) *
                current
            let point = matrix * SIMD3(layerUV.x, layerUV.y, 1)
            return SIMD2(point.x, point.y)
        }
        let transform = placedTransform(layer, transform)
        let placed = (layerUV - 0.5) / layerUVScale(for: layer)
        let aspect = Float(document.aspectRatio)
        let radians = Float(transform.rotation * .pi / 180)
        let c = cos(radians)
        let s = sin(radians)
        let scaleX = Float(transform.scale)
        let scaleY = Float(transform.scaleY ?? transform.scale)
        let column0 = SIMD2(c, s * aspect) * scaleX
        let column1 = SIMD2(-s / aspect, c) * scaleY
        return column0 * placed.x + column1 * placed.y + 0.5 + SIMD2(
            Float(transform.offsetX),
            Float(transform.offsetY)
        )
    }

    /// The layer's pose at the frame last drawn.
    func currentTransform(layerID: UUID) -> SceneTransform? {
        lastFrame?.layers[layerID]?.transform ?? document.layers.first { $0.id == layerID }?.pose(
            at: lastPhase,
            time: lastTime
        ).transform
    }

    func currentLayer(layerID: UUID) -> SceneLayer? {
        lastFrame?.layers[layerID]?.layer ?? document.layers.first { $0.id == layerID }
    }

    func currentOpacity(layerID: UUID) -> Double? {
        if let drawn = lastFrame?.layers[layerID] { return drawn.layer.opacity * drawn.opacity }
        return document.layers.first { $0.id == layerID }.map { $0.opacity * $0.pose(
            at: lastPhase,
            time: lastTime
        ).opacity }
    }

    /// The caller must finish the previous frame on the GPU before encoding another:
    /// particle uploads overwrite the buffers retained from that frame.
    func encode(
        into target: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        input: SceneFrameInput,
        frame: SceneEvaluatedFrame? = nil
    ) throws {
        particleInstanceBuffers.beginFrame()
        var input = input
        // A flat scene's camera shows a window of the canvas: its eye moves the window
        // (y up, from the canvas's bottom left) and its zoom shrinks it about its middle.
        // The editor's own zoom takes precedence.
        if let camera = document.camera, !camera.perspective, let path = camera.path,
           input.viewport == SceneFrameInput.rest.viewport
        {
            let pose = path.transform(at: pathTime(path.period, input: input))
            let eye = pose.eye, zoom = pose.zoom
            let size = SIMD2(Float(document.canvasWidth), Float(document.canvasHeight))
            let window = size / zoom
            let origin = (size - window) / 2 + SIMD2(eye.x, eye.y)
            input.viewport = SIMD4(
                origin.x / size.x,
                1 - (origin.y + window.y) / size.y,
                window.x / size.x,
                window.y / size.y
            )
        }
        guard document.highDynamicRange || document.finishing != nil else {
            return try composite(
                into: target,
                commandBuffer: commandBuffer,
                input: input,
                frame: frame
            )
        }
        // The layers go onto a canvas of their own first, wide when the scene is, then
        // through the finishing passes; the copy to the target clamps to its range.
        let format: MTLPixelFormat = document.highDynamicRange ? .rgba16Float : .bgra8Unorm
        if finishingCanvas?.width != target.width || finishingCanvas?.height != target.height
            || finishingCanvas?.pixelFormat != format
        {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: target.width, height: target.height, mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            guard let canvas = device.makeTexture(descriptor: descriptor)
            else { throw RendererError.textureAllocationFailed }
            finishingCanvas = canvas
        }
        let canvas = finishingCanvas!
        try composite(into: canvas, commandBuffer: commandBuffer, input: input, frame: frame)
        var finished = canvas
        if let finishing = document.finishing {
            if finishingRenderer?.graph != finishing {
                finishingRenderer = try SceneRenderGraphRenderer(
                    graph: finishing,
                    device: device,
                    pool: graphTexturePool
                )
                finishingImages = try finishing.images.values.reduce(into: [:]) { result, file in
                    result[file] = try finishingImage(file)
                }
            }
            let finisher = finishingRenderer!
            finished = try encodeClosingLoop(
                finisher,
                id: Self.finishingID,
                frame: input,
                commandBuffer: commandBuffer
            ) { time in
                try finisher.encode(
                    input: canvas, images: finishingImages, time: time, cursor: input.cursor,
                    audio: input.audio,
                    commandBuffer: commandBuffer
                )
            }
        }
        try compositePass(
            commandBuffer: commandBuffer, destination: target, base: finished,
            layerTexture: blackTexture, uniforms: Self.passThroughUniforms
        )
    }

    /// How model layers are seen this frame: `flat` for those laid out on the canvas,
    /// `perspective` for those marked perspective. In a scene seen through its camera
    /// the unmarked ones go through the camera.
    /// The previous frame's finished picture, which materials sample as `_rt_MipMappedFrameBuffer`.
    /// Measured: it holds what lies before and behind the model, and the model itself comes back
    /// into it; one frame of delay is the reading that fits, its length was not measured.
    var mipHistory: MTLTexture?

    lazy var readsMipHistory: Bool = (document.meshMaterials ?? []).contains {
        $0?.draw.textures.contains { $0.source == SceneModelRenderer.mipHistorySource } ?? false
    }

    private func loadTextures() throws {
        if rigs?.skeletons != document.rigs {
            rigs = try SceneSkeletonRegistry(document.rigs)
            graphRenderers.removeAll()
            loopFadeTargets.removeAll()
        }
        placementEvaluator = try ScenePlacementEvaluator(layers: document.layers, rigs: rigs!)
        lastPlacements.removeAll()
        lastInversePlacements.removeAll()
        mediaArtworkID = ""
        mediaArtworkTextures = [:]
        let layerIDs = Set(document.layers.map(\.id))
        effectLayerTargets = effectLayerTargets.filter { layerIDs.contains($0.key) }
        captureTargets = captureTargets.filter { layerIDs.contains($0.key) }
        particleTargets = particleTargets.filter { layerIDs.contains($0.key) }
        particleSimulators = particleSimulators.filter { id, simulator in
            document.layers.first { $0.id == id }?.particleSystem == simulator.system
        }
        pendingParticleControls = pendingParticleControls
            .filter { particleSimulators[$0.key] != nil }
        let spriteFiles = Set(document.layers.compactMap(\.particleSystem).flatMap(\.textureFiles))
        particleTextures = particleTextures.filter { spriteFiles.contains($0.key) }
        let normalFiles = Set(document.layers.compactMap(\.particleSystem).flatMap(\.normalFiles))
        for file in spriteFiles where particleTextures[file] == nil {
            // Normal maps are opaque data; sprites keep their soft edge.
            let alpha: ImageAlpha = normalFiles.contains(file) ? .straightDropped : .straightKept
            let image = try Self
                .cachedTexture(url: fileURL(file), variant: "rgba-\(alpha)") { url in
                    try Self.decodeRGBA(url: url, device: device, alpha: alpha)
                }
            particleTextures[file] = try mipmapped(image)
        }
        var meshMaterials = document.meshMaterials ?? []
        var importedMaterials: [UUID: [Int]] = [:]
        for layer in document.layers {
            guard layer.modelPlacement != nil, let model = layer.model else { continue }
            let bones = model.skeleton.flatMap { document.rigs[$0]?.bones.count }
            importedMaterials[layer.id] = ([model] + (layer.modelParts ?? [])).map { part in
                let material = SceneModelShading.material(
                    surface: part.surface ?? SceneModelSurface(),
                    boneCount: bones
                )
                if let index = meshMaterials.firstIndex(of: material) { return index }
                meshMaterials.append(material)
                return meshMaterials.count - 1
            }
        }
        floorMaterialIndex = nil
        if document.modelStage?.floor != nil, !importedMaterials.isEmpty {
            meshMaterials.append(SceneModelShading.floorMaterial())
            floorMaterialIndex = meshMaterials.count - 1
        }
        allMeshMaterials = meshMaterials
        let hasModelLayers = document.layers.contains { $0.model != nil }
        if modelRenderer?.materials != meshMaterials || (modelRenderer == nil && hasModelLayers) {
            modelRenderer = (meshMaterials.isEmpty && !hasModelLayers) ? nil :
                try SceneModelRenderer(
                    materials: meshMaterials,
                    device: device
                )
            modelImages = [:]
            let surfaceImages = Set(document.layers.flatMap { layer in
                ([layer.model].compactMap { $0 } + (layer.modelParts ?? [])).compactMap(\.surface)
                    .flatMap(\.images)
            })
            for file in modelRenderer?.imageFiles ?? [] {
                // Materials read the alpha of their images as it was saved.
                let texture = try Self.cachedTexture(
                    url: fileURL(file),
                    variant: "rgba-\(ImageAlpha.straightKept)"
                ) { url in
                    try Self.decodeRGBA(url: url, device: device, alpha: .straightKept)
                }
                // Imported models are seen far smaller than their images, which alias without
                // mipmaps.
                modelImages[file] = surfaceImages.contains(file) ? try mipmapped(texture) : texture
            }
        }
        var graphs: [UUID: SceneRenderGraph] = [:]
        for layer in document.layers {
            if let graph = layer.renderGraph { graphs[layer.id] = graph }
            for effect in layer.effects {
                if let graph = effect.renderGraph { graphs[effect.id] = graph }
            }
        }
        graphRenderers = graphRenderers.filter { graphs[$0.key] != nil }
        loopFadeTargets = loopFadeTargets.filter { graphs[$0.key] != nil }
        for (id, graph) in graphs where graphRenderers[id]?.graph != graph {
            graphRenderers[id] = try SceneRenderGraphRenderer(
                graph: graph,
                device: device,
                rigs: rigs,
                pool: graphTexturePool
            )
        }
        var retainedGraphTextures: [String: MTLTexture] = [:]
        graphResources = [:]
        for (id, graph) in graphs {
            var resources: [String: MTLTexture] = [:]
            // A particle sprite's alpha is its soft edge. Dropping it (as other straight images
            // do) fills the whole quad with opaque black around the glow.
            let spriteFiles = Set(
                graph.passes.compactMap { $0.draw?.dynamic }.flatMap(\.materials.values)
                    .flatMap { $0 }
                    .compactMap { graph.images[$0.source] }
            )
            for file in Set(graph.images.values) {
                let straight = graph.straightAlphaImages == true
                let alpha: ImageAlpha = !straight ? .premultiplied : spriteFiles
                    .contains(file) ? .straightKept : .straightDropped
                let key = "\(alpha):\(file)"
                let texture = try graphTextures[key] ?? Self.cachedTexture(
                    url: fileURL(file),
                    variant: "rgba-\(alpha)"
                ) { url in
                    try Self.decodeRGBA(url: url, device: device, alpha: alpha)
                }
                retainedGraphTextures[key] = texture
                resources[file] = texture
            }
            graphResources[id] = resources
        }
        graphTextures = retainedGraphTextures

        textTextures = textTextures.filter { layerIDs.contains($0.key) }
        for layer in document.layers where layer.kind == .text {
            try prepareText(layer)
        }

        let videos = Set(document.layers.compactMap(\.videoFile))
        videoFrames = videoFrames.filter { videos.contains($0.key) }
        videoFramesShown = videoFramesShown.filter { videos.contains($0.key) }

        let images = Set(document.layers.filter { $0.kind == .image && !$0.imageFile.isEmpty }
            .map(\.imageFile))
        textures = textures.filter { images.contains($0.key) }
        for file in images where textures[file] == nil {
            textures[file] = try Self.cachedTexture(
                url: fileURL(file),
                variant: "rgba-\(ImageAlpha.premultiplied)"
            ) { url in
                try Self.decodeRGBA(url: url, device: device)
            }
        }

        let effects = document.layers.flatMap(\.effects)
        let masks = Set(
            effects.filter { $0.kind != .opacityMask }.compactMap(\.maskFile) + effects
                .compactMap(\.timeOffsetFile)
                + document.layers.compactMap { $0.particles?.maskFile }
                + document.layers.compactMap(\.depthFile)
        )
        maskTextures = maskTextures.filter { masks.contains($0.key) }
        for file in masks where maskTextures[file] == nil {
            maskTextures[file] = try Self
                .cachedTexture(url: fileURL(file), variant: "mask") { url in
                    try Self.decodeMask(url: url, device: device)
                }
        }
        let flows = Set(
            effects.compactMap(\.flowFile) + effects.compactMap(\.patternFile)
                + effects.filter { $0.kind == .opacityMask }.compactMap(\.maskFile)
        )
        flowTextures = flowTextures.filter { flows.contains($0.key) }
        for file in flows where flowTextures[file] == nil {
            flowTextures[file] = try Self.cachedTexture(
                url: fileURL(file),
                variant: "rgba-\(ImageAlpha.straightDropped)"
            ) { url in
                try Self.decodeRGBA(url: url, device: device, alpha: .straightDropped)
            }
        }

        solidBackground = nil
        modelRenderer?.shadowState.targets = [:]
        if document.finishing == nil {
            finishingCanvas = nil
            finishingRenderer = nil
            finishingImages = [:]
        }

        let modelLayers = document.layers.filter { $0.model != nil }
        let modelLayerIDs = Set(modelLayers.map(\.id))
        staticShapes = staticShapes.filter { modelLayerIDs.contains($0.key) }
        importedShapes = importedShapes.filter { importedMaterials[$0.key] != nil }
        for layer in modelLayers where layer.modelPlacement != nil {
            let parts = [layer.model!] + (layer.modelParts ?? [])
            let materials = importedMaterials[layer.id]!
            if let skeleton = layer.model!.skeleton, document.rigs[skeleton] == nil {
                throw SceneSkeletonEvaluator
                    .InvalidSkeleton(detail: "model layer \(layer.name) skins with a missing rig")
            }
            // Every edit of the scene comes through here; decoding and uploading the vertices again
            // is the slow part.
            if let cached = importedShapes[layer.id], cached.parts == parts,
               cached.materials == materials
            {
                continue
            }
            if let skeleton = layer.model!.skeleton {
                guard let rig = document.rigs[skeleton],
                      parts.allSatisfy({ $0.maxJoint < rig.bones.count })
                else {
                    throw SceneSkeletonEvaluator
                        .InvalidSkeleton(
                            detail: "model layer \(layer.name) skins with a missing rig or bone"
                        )
                }
            }
            let shapes = try zip(parts, materials).map { part, material in
                var shape = part.shape
                shape.material = material
                shape.vertexBuffer = try shape.vertices.withUnsafeBytes { bytes in
                    guard let baseAddress = bytes.baseAddress, !bytes.isEmpty,
                          let buffer = device.makeBuffer(
                        bytes: baseAddress,
                        length: bytes.count,
                        options: .storageModeShared
                    )
                    else { throw RendererError.textureAllocationFailed }
                    return buffer
                }
                if let indices = shape.indices, !indices.isEmpty {
                    shape.indexBuffer = try indices.withUnsafeBytes { bytes in
                        guard let baseAddress = bytes.baseAddress,
                              let buffer = device.makeBuffer(
                            bytes: baseAddress,
                            length: bytes.count,
                            options: .storageModeShared
                        )
                        else { throw RendererError.textureAllocationFailed }
                        return buffer
                    }
                } else {
                    shape.indexBuffer = nil
                }
                return shape
            }
            importedShapes[layer.id] = ImportedShapeCache(
                parts: parts,
                materials: materials,
                shapes: shapes
            )
        }
        for layer in modelLayers where layer.modelPlacement == nil {
            guard let model = layer.model else { continue }
            if let skeleton = model.skeleton {
                guard let rig = document.rigs[skeleton], model.maxJoint < rig.bones.count else {
                    throw SceneSkeletonEvaluator
                        .InvalidSkeleton(
                            detail: "model layer \(layer.name) skins with a missing rig or bone"
                        )
                }
            }
            if let cached = staticShapes[layer.id], cached.model == model {
                continue
            }
            if let existing = staticShapes.values.first(where: { $0.model == model }) {
                staticShapes[layer.id] = StaticShapeCache(model: model, shape: existing.shape)
                continue
            }
            var shape = model.shape
            if !shape.vertices.isEmpty {
                let buffer: (any MTLBuffer)? = shape.vertices.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress, !bytes.isEmpty else { return nil }
                    return device.makeBuffer(
                        bytes: base,
                        length: bytes.count,
                        options: .storageModeShared
                    )
                }
                guard let buffer else { throw RendererError.textureAllocationFailed }
                shape.vertexBuffer = buffer
            }
            if let indices = shape.indices, !indices.isEmpty {
                let buffer: (any MTLBuffer)? = indices.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress, !bytes.isEmpty else { return nil }
                    return device.makeBuffer(
                        bytes: base,
                        length: bytes.count,
                        options: .storageModeShared
                    )
                }
                guard let buffer else { throw RendererError.textureAllocationFailed }
                shape.indexBuffer = buffer
            }
            staticShapes[layer.id] = StaticShapeCache(model: model, shape: shape)
        }
    }
}

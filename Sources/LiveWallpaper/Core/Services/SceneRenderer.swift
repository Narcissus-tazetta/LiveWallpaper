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
    /// preview of it) their speeds are rounded to whole repeats per loop.
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

    private struct Pipeline {
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

        func compositeFetch(for format: MTLPixelFormat) -> MTLRenderPipelineState? {
            format == .rgba16Float ? compositeFetchWide : compositeFetch
        }
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
    private var graphRenderers: [UUID: SceneRenderGraphRenderer] = [:]
    private var modelRenderer: SceneModelRenderer?
    private var modelImages: [String: MTLTexture] = [:]
    private var modelDepthTexture: MTLTexture?
    struct StaticShapeCache {
        var model: SceneStaticModel
        var shape: SceneModelLayerFrame.Shape
    }
    /// The mesh and buffers of each layer that is a solid model.
    private(set) var staticShapes: [UUID: StaticShapeCache] = [:]
    private let graphTexturePool = SceneTexturePool()
    private var graphTextures: [String: MTLTexture] = [:]
    private var graphResources: [UUID: [String: MTLTexture]] = [:]
    private var rigs: SceneSkeletonRegistry?
    private var placementEvaluator: ScenePlacementEvaluator?
    private var lastPlacements: [UUID: simd_float3x3] = [:]
    private var lastInversePlacements: [UUID: simd_float3x3] = [:]
    private(set) var document: SceneDocument
    private let videoPath: String
    private var textures: [String: MTLTexture] = [:]
    private var mediaArtworkID = ""
    private var mediaArtworkTextures: [UUID: MTLTexture] = [:]
    /// By file name; loaded by the owner (SceneMetalLayer, prepareVideos) because
    /// reading a video's tracks is asynchronous. Until then the layer shows its image.
    private var videoFrames: [String: SceneVideoFrames] = [:]
    /// The frame each video layer draws, held until the next encode so the GPU can read it.
    private var videoFramesShown: [String: SceneVideoFrames.Frame] = [:]
    /// Live drawing decodes on the video's queue and shows the newest frame (one
    /// request behind); otherwise each frame waits for its exact video frame (a bake).
    var decodesVideoAhead = false
    private struct TextTexture {
        let text: SceneText
        let texture: MTLTexture?
        let canvasSize: SIMD2<Double>
        let centerOffset: SIMD2<Double>
    }
    /// Drawn again only when the text or its style changes (a script can change it).
    private var textTextures: [UUID: TextTexture] = [:]
    private var maskTextures: [String: MTLTexture] = [:]
    private var flowTextures: [String: MTLTexture] = [:]
    private var effectLayerTargets: [UUID: MTLTexture] = [:]
    private var effectScratchTargets: [SIMD2<Int>: MTLTexture] = [:]
    private var usedEffectScratchSizes: Set<SIMD2<Int>> = []
    private var captureTargets: [UUID: MTLTexture] = [:]
    private var particleTargets: [UUID: MTLTexture] = [:]
    private var particleSimulators: [UUID: SceneParticleSimulator] = [:]
    private var particleInstanceBuffers = SceneParticleInstanceBuffers()
    /// The input time the simulators last advanced to.
    private var particleTime: Double?
    /// Script requests from frames that were not drawn, applied with the next one.
    private var pendingParticleControls: [UUID: SceneParticleSimulator.Control] = [:]
    /// By file, with mipmaps: sprites are often drawn far smaller than their image.
    private var particleTextures: [String: MTLTexture] = [:]
    private var accumulation: [MTLTexture] = []
    private var finishingCanvas: MTLTexture?
    private var finishingRenderer: SceneRenderGraphRenderer?
    private var finishingImages: [String: MTLTexture] = [:]
    private var solidBackground: MTLTexture?

    private var backgroundClearColor: MTLClearColor {
        let color = document.backgroundColor ?? [0, 0, 0]
        return MTLClearColor(red: color[0], green: color[1], blue: color[2], alpha: 1)
    }

    private func finishingImage(_ file: String) throws -> MTLTexture {
        let alpha: ImageAlpha = document.finishing?.straightAlphaImages == true ? .straightDropped : .premultiplied
        return try Self.cachedTexture(url: fileURL(file), variant: "rgba-\(alpha)") { url in
            try Self.decodeRGBA(url: url, device: device, alpha: alpha)
        }
    }

    /// The canvas before any layer: the background colour, as a texture to draw over.
    private func backgroundTexture() throws -> MTLTexture {
        guard let color = document.backgroundColor else { return blackTexture }
        if let solidBackground { return solidBackground }
        let bytes = color.map { UInt8((min(max($0, 0), 1) * 255).rounded()) } + [255]
        solidBackground = try Self.makeSolidTexture(device: device, pixelFormat: .rgba8Unorm, bytes: bytes)
        return solidBackground!
    }
    private let blackTexture: MTLTexture
    private let whiteTexture: MTLTexture
    private let whiteMask: MTLTexture
    private let stillFlow: MTLTexture
    /// Fraction of the displayed size that effects are computed at. The baked video
    /// uses full resolution.
    var effectResolutionScale: Float = 1
    /// Off forces the ping-pong composite that other GPUs use.
    var allowsSinglePassComposite = true
    /// Loop phase of the last encoded frame, for mapping preview clicks.
    private var lastPhase: Double = 0
    private var lastTime: Double = 0
    private var paintOverride: ScenePaintOverride?
    private var paintOverrideTexture: MTLTexture?
    /// Tints where the painted mask or flow map applies, so weak motion can be seen.
    var showsPaintTint = true
    /// The part of the day the links see: now unless the owner says otherwise (a bake
    /// fixes it at its start, the editor shows what it simulates).
    var timeOfDay: SceneTimeOfDay
    /// Evaluates scripts only off the main thread: for bakes (live drawing evaluates
    /// them on SceneScriptWorker and passes the frame in).
    private lazy var frameEvaluator = SceneFrameEvaluator(budget: .offline, storage: SceneScriptStorage.shared.snapshot(path: videoPath))
    private var lastFrame: SceneEvaluatedFrame?
    var lastDrawnInput: SceneFrameInput? { lastFrame?.input }

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
        blackTexture = try Self.makeSolidTexture(device: pipeline.device, pixelFormat: .rgba8Unorm, bytes: [0, 0, 0, 255])
        whiteTexture = try Self.makeSolidTexture(device: pipeline.device, pixelFormat: .rgba8Unorm, bytes: [255, 255, 255, 255])
        whiteMask = try Self.makeSolidTexture(device: pipeline.device, pixelFormat: .r8Unorm, bytes: [255])
        stillFlow = try Self.makeSolidTexture(device: pipeline.device, pixelFormat: .rgba8Unorm, bytes: [128, 128, 0, 255])
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
        Set(document.layers.compactMap(\.videoFile)).subtracting(videoFrames.keys).sorted().map { ($0, fileURL($0)) }
    }

    func install(_ frames: SceneVideoFrames, videoFile: String) {
        guard document.layers.contains(where: { $0.videoFile == videoFile }) else { return }
        videoFrames[videoFile] = frames
    }

    /// Loads every video layer, for renderers that draw a fixed sequence of frames.
    func prepareVideos() async throws {
        for video in videosToLoad {
            install(try await SceneVideoFrames.load(url: video.url, device: device), videoFile: video.file)
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
        if lastPlacements[layerID] != nil {
            guard let inverse = lastInversePlacements[layerID] else { return nil }
            let point = inverse * SIMD3(canvasUV.x, canvasUV.y, 1)
            return SIMD2(point.x, point.y)
        }
        let placement = placement(for: placedTransform(layer, currentTransform(layerID: layerID) ?? layer.pose(at: lastPhase, time: lastTime).transform))
        let relative = canvasUV - 0.5 - placement.offset
        let placed = placement.column0 * relative.x + placement.column1 * relative.y + 0.5
        return (placed - 0.5) * layerUVScale(for: layer) + 0.5
    }

    private func readsBackground(_ layer: SceneLayer) -> Bool {
        if graphRenderers[layer.id]?.graph.readsBackground == true { return true }
        if layer.particleSystem?.refracts == true { return true }
        return layer.activeEffects.contains { graphRenderers[$0.id]?.graph.readsBackground == true }
    }

    /// Canvas UV → layer UV as an affine matrix, for effects that place the cursor on
    /// their layer; identity for layers drawn over the whole canvas.
    private func layerFromCanvas(_ layer: SceneLayer) -> simd_float3x3 {
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
        return canvasUV(layerUV: layerUV, layer: layer, transform: currentTransform(layerID: layerID) ?? layer.pose(at: lastPhase, time: lastTime).transform)
    }

    /// Where the layer's picture would sit with `transform`, at rest.
    func canvasUV(layerUV: SIMD2<Float>, layer: SceneLayer, transform: SceneTransform) -> SIMD2<Float> {
        if let current = lastPlacements[layer.id] {
            let previous = currentTransform(layerID: layer.id) ?? layer.pose(at: lastPhase, time: lastTime).transform
            let matrix = placementMatrix(transform) * simd_inverse(placementMatrix(previous)) * current
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
        return column0 * placed.x + column1 * placed.y + 0.5 + SIMD2(Float(transform.offsetX), Float(transform.offsetY))
    }

    /// The layer's pose at the frame last drawn.
    func currentTransform(layerID: UUID) -> SceneTransform? {
        lastFrame?.layers[layerID]?.transform ?? document.layers.first { $0.id == layerID }?.pose(at: lastPhase, time: lastTime).transform
    }

    func currentLayer(layerID: UUID) -> SceneLayer? {
        lastFrame?.layers[layerID]?.layer ?? document.layers.first { $0.id == layerID }
    }

    func currentOpacity(layerID: UUID) -> Double? {
        if let drawn = lastFrame?.layers[layerID] { return drawn.layer.opacity * drawn.opacity }
        return document.layers.first { $0.id == layerID }.map { $0.opacity * $0.pose(at: lastPhase, time: lastTime).opacity }
    }

    /// The caller must finish the previous frame on the GPU before encoding another:
    /// particle uploads overwrite the buffers retained from that frame.
    func encode(into target: MTLTexture, commandBuffer: MTLCommandBuffer, input: SceneFrameInput, frame: SceneEvaluatedFrame? = nil) throws {
        particleInstanceBuffers.beginFrame()
        var input = input
        // A flat scene's camera shows a window of the canvas: its eye moves the window
        // (y up, from the canvas's bottom left) and its zoom shrinks it about its middle.
        // The editor's own zoom takes precedence.
        if let camera = document.camera, !camera.perspective, let path = camera.path, input.viewport == SceneFrameInput.rest.viewport {
            let (eye, _, _, zoom) = path.transform(at: input.time)
            let size = SIMD2(Float(document.canvasWidth), Float(document.canvasHeight))
            let window = size / zoom
            let origin = (size - window) / 2 + SIMD2(eye.x, eye.y)
            input.viewport = SIMD4(origin.x / size.x, 1 - (origin.y + window.y) / size.y, window.x / size.x, window.y / size.y)
        }
        guard document.highDynamicRange || document.finishing != nil else {
            return try composite(into: target, commandBuffer: commandBuffer, input: input, frame: frame)
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
            guard let canvas = device.makeTexture(descriptor: descriptor) else { throw RendererError.textureAllocationFailed }
            finishingCanvas = canvas
        }
        let canvas = finishingCanvas!
        try composite(into: canvas, commandBuffer: commandBuffer, input: input, frame: frame)
        var finished = canvas
        if let finishing = document.finishing {
            if finishingRenderer?.graph != finishing {
                finishingRenderer = try SceneRenderGraphRenderer(graph: finishing, device: device, pool: graphTexturePool)
                finishingImages = try finishing.images.values.reduce(into: [:]) { result, file in
                    result[file] = try finishingImage(file)
                }
            }
            finished = try finishingRenderer!.encode(
                input: canvas, images: finishingImages, time: input.time, cursor: input.cursor, audio: input.audio,
                commandBuffer: commandBuffer
            )
        }
        try compositePass(
            commandBuffer: commandBuffer, destination: target, base: finished,
            layerTexture: blackTexture, uniforms: Self.passThroughUniforms
        )
    }

    private func composite(into target: MTLTexture, commandBuffer: MTLCommandBuffer, input: SceneFrameInput, frame: SceneEvaluatedFrame?) throws {
        usedEffectScratchSizes.removeAll(keepingCapacity: true)
        defer {
            graphTexturePool.endFrame()
            if effectScratchTargets.count != usedEffectScratchSizes.count {
                effectScratchTargets = effectScratchTargets.filter { usedEffectScratchSizes.contains($0.key) }
            }
        }
        if frame == nil, document.scripts.contains(where: \.canRun), Thread.isMainThread {
            throw SceneScriptIssue(scriptID: document.scripts.first!.id, name: "JavaScript", message: "Scripts must be evaluated off the main thread")
        }
        let evaluated = try frame ?? frameEvaluator.evaluate(document, input: input, timeOfDay: timeOfDay)
        rigs!.setPlaybackOverrides(evaluated.rigPlayback)
        lastFrame = evaluated
        try prepareMediaArtwork(input.media)
        let placements = placementEvaluator!.evaluate(time: input.time)
        lastPlacements = [:]
        // A copy a script made is placed like its template, moved by its own transform.
        for (id, template) in evaluated.instances.map({ ($0.key, $0.value) }) + placements.keys.map({ ($0, $0) }) {
            guard let matrix = placements[template], let layer = evaluated.layers[id] else { continue }
            let reference = layer.layer.placement!.referenceTransform
            lastPlacements[id] = placementMatrix(layer.transform) * simd_inverse(placementMatrix(reference)) * matrix
        }
        lastInversePlacements = lastPlacements.compactMapValues(Self.inversePlacement)
        lastPhase = Double(loopPhase(input.time))
        lastTime = input.time
        advanceParticles(evaluated, input: input)
        let targetSize = SIMD2(Float(target.width), Float(target.height))
        let copies = evaluated.instances.keys.sorted { evaluated.order[$0] ?? 0 < evaluated.order[$1] ?? 0 }
            .compactMap { evaluated.layers[$0]?.layer }
        let ordered = (document.layers + copies).enumerated().sorted { a, b in
            let left = evaluated.order[a.element.id] ?? a.offset
            let right = evaluated.order[b.element.id] ?? b.offset
            return left == right ? a.offset < b.offset : left < right
        }.map(\.element)
        for layer in ordered where layer.kind == .text {
            try prepareText(evaluated.layers[layer.id]!.layer)
        }
        for file in Set(ordered.filter { evaluated.layers[$0.id]!.layer.isVisible }.compactMap(\.videoFile)) {
            guard let frames = videoFrames[file] else { continue }
            if decodesVideoAhead { frames.request(input.time) } else { try frames.advance(to: input.time) }
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
        if modelRenderer == nil && (!evaluated.models.isEmpty || visibleLayers.contains { $0.model != nil }) {
            modelRenderer = try SceneModelRenderer(materials: document.meshMaterials ?? [], device: device)
        }
        let visible = modelRenderer == nil || evaluated.models.isEmpty
            ? placed
            : Self.interleave(visibleLayers, placed: placed, models: evaluated.models, place: { id in
                evaluated.order[id] ?? document.layers.firstIndex { $0.id == id } ?? 0
            })
        let views = modelViews(camera: evaluated.camera, input: input, target: target)
        let layerPictures = try modelLayerPictures(evaluated: evaluated, commandBuffer: commandBuffer, input: input, targetSize: targetSize)
        // The frame's model layers share one depth buffer; the first pass clears it.
        var depthCleared = false
        func drawModels(_ models: [SceneModelLayerFrame], into texture: MTLTexture, clear: Bool) throws {
            if modelRenderer == nil {
                modelRenderer = try SceneModelRenderer(materials: document.meshMaterials ?? [], device: device)
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = clear ? .clear : .load
            pass.colorAttachments[0].clearColor = backgroundClearColor
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = try modelDepth(width: texture.width, height: texture.height)
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
                    model, view: model.perspective ? views.perspective : views.flat, images: modelImages,
                    layerPictures: layerPictures, frame: .init(),
                    time: input.time, cursor: input.cursor, audio: input.audio, format: texture.pixelFormat, encoder: encoder
                )
            }
        }
        if document.camera?.perspective == true {
            try compositeInSpace(visible, evaluated: evaluated, views: views, layerPictures: layerPictures, target: target,
                                 commandBuffer: commandBuffer, input: input, targetSize: targetSize)
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

            try ensureAccumulation(width: target.width, height: target.height, format: target.pixelFormat)
            var source: MTLTexture? = nil
            var nextIndex = 0

            for (segIndex, segment) in segments.enumerated() {
                let isLast = (segIndex == segments.count - 1)
                let destination = isLast ? target : accumulation[nextIndex]

                switch segment {
                case .models(let models):
                    // Drawn straight onto the canvas so far; the last segment has to end in the target.
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

                case .batch(let layers):
                    var prepared: [PreparedLayer] = []
                    for layer in layers {
                        let drawn = evaluated.layers[layer.id]!
                        let layerTexture = try applyEffects(
                            to: drawn.layer, commandBuffer: commandBuffer, input: input, targetSize: targetSize
                        )
                        prepared.append(PreparedLayer(
                            layerTexture: layerTexture,
                            uniforms: compositeUniforms(for: drawn.layer, drawn: drawn, input: input, targetSize: targetSize),
                            depth: layer.depthFile.flatMap { maskTextures[$0] }
                        ))
                    }

                    if let currentSource = source {
                        if currentSource !== destination {
                            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                                throw RendererError.textureAllocationFailed
                            }
                            blit.copy(
                                from: currentSource, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                                sourceSize: MTLSize(width: currentSource.width, height: currentSource.height, depth: 1),
                                to: destination, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin()
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
                    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                        throw RendererError.textureAllocationFailed
                    }
                    encoder.setRenderPipelineState(fetch)
                    for item in prepared {
                        guard let scissor = Self.scissor(for: item.uniforms, width: target.width, height: target.height) else {
                            continue
                        }
                        var uniforms = item.uniforms
                        encoder.setScissorRect(scissor)
                        encoder.setFragmentTexture(item.layerTexture, index: 1)
                        encoder.setFragmentTexture(item.depth ?? whiteMask, index: 2)
                        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    }
                    encoder.endEncoding()
                    source = destination
                    nextIndex = 1 - nextIndex

                case .capture(let layer):
                    let drawn = evaluated.layers[layer.id]!
                    let uniforms = compositeUniforms(for: drawn.layer, drawn: drawn, input: input, targetSize: targetSize)
                    let base = try source ?? backgroundTexture()
                    let layerTexture = try applyEffects(
                        to: drawn.layer, commandBuffer: commandBuffer, input: input, targetSize: targetSize,
                        canvasSource: base, compositeUniforms: uniforms
                    )
                    try compositePass(
                        commandBuffer: commandBuffer, destination: destination, base: base,
                        layerTexture: layerTexture, uniforms: uniforms, depth: layer.depthFile.flatMap { maskTextures[$0] }
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

        try ensureAccumulation(width: target.width, height: target.height, format: target.pixelFormat)
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
            let uniforms = compositeUniforms(for: drawn.layer, drawn: drawn, input: input, targetSize: targetSize)
            let layerTexture = try applyEffects(
                to: drawn.layer, commandBuffer: commandBuffer, input: input, targetSize: targetSize,
                canvasSource: source, compositeUniforms: uniforms
            )
            let destination = accumulation[nextIndex]
            try compositePass(
                commandBuffer: commandBuffer, destination: destination, base: source,
                layerTexture: layerTexture, uniforms: uniforms, depth: layer.depthFile.flatMap { maskTextures[$0] }
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
        let det = u.placementColumn0.x * u.placementColumn1.y - u.placementColumn1.x * u.placementColumn0.y
        guard det != 0, u.uvScale.x != 0, u.uvScale.y != 0, u.viewSize.x != 0, u.viewSize.y != 0 else {
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
        if modelRenderer == nil { modelRenderer = try SceneModelRenderer(materials: document.meshMaterials ?? [], device: device) }
        enum Prepared {
            case model(SceneModelLayerFrame), plane(MTLTexture, SceneEvaluatedFrame.Layer, SceneSpace)
            case particles(SceneLayer, SceneEvaluatedFrame.Layer, SceneSpace)
            /// Runs its effects over everything drawn before it, whole frame.
            case capture(SceneLayer, SceneEvaluatedFrame.Layer)
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
                    prepared.append(.capture(layer, evaluated.layers[layer.id]!))
                    continue
                }
                guard var space = layer.space else { continue }
                if layer.kind == .text {
                    // The plane is the drawn string's picture, centred away from where its anchor sits.
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
                let picture = try applyEffects(to: drawn.layer, commandBuffer: commandBuffer, input: input, targetSize: targetSize)
                prepared.append(.plane(picture, drawn, space))
            }
        }
        if document.camera?.sortsByDistance == true {
            // Ties keep the listed order. The distance is the depth along the camera's axis
            // (not the straight line to the eye): measured with the camera turned off the z axis
            // and with plates off the axis. The perspective projection's w is that depth.
            func distance(_ item: Prepared) -> Float {
                let world: simd_float4x4 = switch item {
                case let .model(model): model.world
                case let .plane(_, drawn, space), let .particles(_, drawn, space): drawn.world ?? space.matrix
                case .capture: matrix_identity_float4x4
                }
                return (views.flat.viewProjection * SIMD4(world.columns.3.x, world.columns.3.y, world.columns.3.z, 1)).w
            }
            // A capturing layer reads what the sorted ones drew, so it stays after them.
            var keyed: [(distance: Float, index: Int, item: Prepared)] = []
            var captures: [Prepared] = []
            for (index, item) in prepared.enumerated() {
                if case .capture = item { captures.append(item) } else { keyed.append((distance(item), index, item)) }
            }
            keyed.sort { $0.distance == $1.distance ? $0.index < $1.index : $0.distance > $1.distance }
            prepared = keyed.map(\.item) + captures
        }
        var views = views
        if let lights = document.camera?.shadowLights, !lights.isEmpty {
            let casters = prepared.compactMap { item -> SceneModelLayerFrame? in
                if case let .model(model) = item { return model }
                return nil
            }
            let shadows = try modelRenderer!.renderShadows(lights: lights, casters: casters, commandBuffer: commandBuffer)
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
            pass.depthAttachment.texture = try modelDepth(width: target.width, height: target.height)
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
                    model, view: model.perspective ? views.perspective : views.flat, images: modelImages,
                    layerPictures: layerPictures, frame: .init(),
                    time: input.time, cursor: input.cursor, audio: input.audio, format: target.pixelFormat, encoder: encoder!
                )
            case let .plane(picture, drawn, space):
                let tint = drawn.layer.tint
                let opacity = Float(min(max(drawn.layer.opacity * tint.alpha * drawn.opacity, 0), 1))
                let local = simd_float4x4(columns: (
                    SIMD4(Float(space.width), 0, 0, 0), SIMD4(0, Float(space.height), 0, 0), SIMD4(0, 0, 1, 0),
                    SIMD4(Float(space.offsetX), Float(space.offsetY), 0, 1)
                ))
                try modelRenderer!.drawPlane(
                    picture, transform: views.flat.viewProjection * (drawn.world ?? space.matrix) * local,
                    color: SIMD4(Float(tint.red), Float(tint.green), Float(tint.blue), opacity), space: space,
                    format: target.pixelFormat, encoder: encoder!
                )
            case let .particles(layer, drawn, space):
                try drawParticlesInSpace(
                    layer, drawn: drawn, space: space, view: views.flat, format: target.pixelFormat, encoder: encoder!
                )
            case let .capture(layer, drawn):
                encoder?.endEncoding()
                encoder = nil
                try ensureAccumulation(width: target.width, height: target.height, format: target.pixelFormat)
                // The layer covers the whole frame, so it needs no placement of its own.
                var uniforms = Self.passThroughUniforms
                uniforms.opacity = Float(min(max(layer.opacity * layer.tint.alpha * drawn.opacity, 0), 1))
                uniforms.blendMode = Int32(SceneBlendMode.allCases.firstIndex(of: layer.blendMode) ?? 0)
                let layerTexture = try applyEffects(
                    to: drawn.layer, commandBuffer: commandBuffer, input: input, targetSize: targetSize,
                    canvasSource: target, compositeUniforms: uniforms
                )
                try compositePass(
                    commandBuffer: commandBuffer, destination: accumulation[0], base: target,
                    layerTexture: layerTexture, uniforms: uniforms
                )
                guard let blit = commandBuffer.makeBlitCommandEncoder() else { throw RendererError.textureAllocationFailed }
                blit.copy(from: accumulation[0], to: target)
                blit.endEncoding()
                encoder = try openPass()
            }
        }
    }

    /// The pictures of the layers model materials sample, effects applied even where the layer itself
    /// is hidden. Encoded before any pass of the frame opens.
    private func modelLayerPictures(
        evaluated: SceneEvaluatedFrame, commandBuffer: MTLCommandBuffer, input: SceneFrameInput, targetSize: SIMD2<Float>
    ) throws -> [Int: MTLTexture] {
        guard let sampled = modelRenderer?.sampledLayerObjectIDs, !sampled.isEmpty else { return [:] }
        var pictures: [Int: MTLTexture] = [:]
        for layer in document.layers {
            guard let id = layer.objectID, sampled.contains(id), var drawn = evaluated.layers[layer.id]?.layer else { continue }
            drawn.isVisible = true
            pictures[id] = try applyEffects(to: drawn, commandBuffer: commandBuffer, input: input, targetSize: targetSize)
        }
        return pictures
    }

    private func staticModelFrame(_ layer: SceneLayer, evaluated: SceneEvaluatedFrame) -> SceneModelLayerFrame {
        let drawn = evaluated.layers[layer.id]!
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
            world: drawn.world ?? layer.space?.matrix ?? matrix_identity_float4x4, perspective: false, shapes: [shape],
            materialValues: drawn.layer.modelValues ?? [:], castsShadow: drawn.layer.castsShadow ?? true
        )
    }

    /// Particles with nothing to run them through (effects, a painted area, a picture of
    /// what is behind) are sprites in the scene itself rather than a picture on a plane.
    private func drawsParticlesInSpace(_ layer: SceneLayer) -> Bool {
        guard layer.kind == .particles, let system = layer.particleSystem, particleSimulators[layer.id] != nil else { return false }
        return !system.refracts && layer.activeEffects.isEmpty && graphRenderers[layer.id] == nil
            && paintOverride?.effectID != layer.id
    }

    private func drawParticlesInSpace(
        _ layer: SceneLayer, drawn: SceneEvaluatedFrame.Layer, space: SceneSpace, view: SceneModelRenderer.View,
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
                plane: SIMD4(Float(space.width), Float(space.height), Float(space.offsetX), Float(space.offsetY)),
                tint: SIMD4(Float(tint.red), Float(tint.green), Float(tint.blue), opacity),
                brightness: Float(system.brightness),
                cutout: system.cutout.map { SIMD3(Float($0.start), Float($0.end), Float($0.opacity)) },
                blend: system.blend,
                fog: system.receivesFog == true ? document.camera?.fog : nil
            )
            try modelRenderer!.drawParticles(
                instances: buffer, count: instances.count, texture: texture, world: drawn.world ?? space.matrix, view: view,
                style: style, depthTest: space.depthTest, depthWrite: space.depthWrite, format: format, encoder: encoder
            )
        }
    }

    /// How model layers are seen this frame: `flat` for those laid out on the canvas,
    /// `perspective` for those marked perspective. In a scene seen through its camera
    /// the unmarked ones go through the camera.
    private func modelViews(camera: SceneCameraState?, input: SceneFrameInput, target: MTLTexture)
        -> (flat: SceneModelRenderer.View, perspective: SceneModelRenderer.View)
    {
        let scene = document.camera
        let ambient = SIMD3((scene?.ambientColor ?? [0, 0, 0]).map(Float.init))
        let skylight = SIMD3((scene?.skylightColor ?? [0, 0, 0]).map(Float.init))
        var state = camera ?? scene.map { scene in
            var state = SceneCameraState(eye: SIMD3(scene.eye.map(Float.init)), center: SIMD3(scene.center.map(Float.init)),
                                         up: SIMD3(scene.up.map(Float.init)), zoom: 1, fov: Float(scene.fov),
                                         nearZ: Float(scene.nearZ), farZ: Float(scene.farZ))
            state.isPlacedByScript = false
            return state
        }
        if let path = scene?.path, var moved = state, !moved.isPlacedByScript {
            (moved.eye, moved.center, moved.up, _) = path.transform(at: input.time)
            state = moved
        }
        // Fog and highlights on a solid model of a canvas scene are measured from a point
        // 2000 in front of the canvas's centre, not from the camera's eye.
        let eye: SIMD3<Float> = scene?.perspective != true && document.layers.contains { $0.model != nil }
            ? SIMD3(Float(document.canvasWidth) / 2, Float(document.canvasHeight) / 2, 2000) : state?.eye ?? .zero
        let canvas = SceneModelRenderer.View(
            viewProjection: SceneModelRenderer.canvasProjection(
                width: Double(document.canvasWidth), height: Double(document.canvasHeight), viewport: input.viewport
            ),
            eye: eye, ambient: ambient, skylight: skylight
        )
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

    private func modelDepth(width: Int, height: Int) throws -> MTLTexture {
        if let depth = modelDepthTexture, depth.width == width, depth.height == height { return depth }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: SceneModelRenderer.depthFormat, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RendererError.textureAllocationFailed }
        modelDepthTexture = texture
        return texture
    }

    /// What the canvas draws, bottom to top.
    private enum Drawn {
        case layer(SceneLayer)
        case model(SceneModelLayerFrame)
    }

    /// The scene's layers, bottom to top, with the model layers scripts made, by their
    /// shared drawing order (`place` of a scene layer).
    private static func interleave(
        _ layers: [SceneLayer], placed: [Drawn], models: [SceneModelLayerFrame], place: (UUID) -> Int
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

    /// A speed in radians per second, rounded to whole turns per loop unless drawn
    /// on real time; a motion that would round to none keeps one turn.
    private func loopSpeed(_ speed: Double, input: SceneFrameInput) -> Float {
        guard !input.isRealTime, speed != 0 else {
            return Float(speed)
        }
        let loop = Double(max(document.loopSeconds, 1))
        let turns = max((abs(speed) * loop / (2 * .pi)).rounded(), 1)
        return Float((speed < 0 ? -1 : 1) * turns * 2 * .pi / loop)
    }

    private func realTimeValues(_ effect: SceneEffect, input: SceneFrameInput) -> RealTimeEffectValues {
        func value(_ key: String) -> Float {
            Float(effect.value(key))
        }
        switch effect.kind {
        case .travelingWaves:
            typealias Key = SceneEffect.WaveKey
            return RealTimeEffectValues([
                loopSpeed(effect.value(Key.speed), input: input), value(Key.scale), value(Key.amplitude),
                value(Key.exponent), value(Key.angle), value(Key.dual),
                loopSpeed(effect.value(Key.speed2), input: input), value(Key.scale2), value(Key.offset2),
                value(Key.exponent2), value(Key.angle2)
            ])
        case .flowShake:
            typealias Key = SceneEffect.FlowShakeKey
            let speed = effect.value(Key.speed)
            // The irregular swing sums sines at these multiples of the speed; each is
            // rounded on its own so a baked loop still closes.
            let multiples = [1, -0.16161616, 0.0083333, -0.00019841]
            return RealTimeEffectValues([
                loopSpeed(speed, input: input), value(Key.amplitude), value(Key.frictionX),
                value(Key.frictionY), value(Key.boundsMin), value(Key.boundsMax), value(Key.side),
                value(Key.irregular)
            ] + multiples.map { input.isRealTime ? Float(speed * $0) : loopSpeedAllowingStill(speed * $0) })
        case .flowMap:
            typealias Key = SceneEffect.FlowMapKey
            return RealTimeEffectValues([
                loopRate(effect.value(Key.speed), input: input), value(Key.strength), value(Key.feather),
                value(Key.phaseScale)
            ])
        case .normalRipples:
            typealias Key = SceneEffect.RipplesKey
            // Its pattern drifts along two axes at once; a baked loop does not close
            // exactly (only the desktop draws it live).
            return RealTimeEffectValues([
                value(Key.animationSpeed), value(Key.scale), value(Key.scrollSpeed), value(Key.scrollAngle),
                value(Key.ratio), value(Key.strength), textureAspect(effect), value(Key.specular),
                value(Key.specularPower), value(Key.specularStrength), value(Key.specularRed),
                value(Key.specularGreen), value(Key.specularBlue)
            ])
        case .noiseDrift:
            typealias Key = SceneEffect.NoiseDriftKey
            return RealTimeEffectValues([
                loopRate(effect.value(Key.speed), input: input), value(Key.scale), value(Key.scaleX),
                value(Key.amount), value(Key.angle), textureAspect(effect)
            ])
        case .noiseSway:
            typealias Key = SceneEffect.NoiseSwayKey
            let speed = effect.value(Key.speed)
            let multiples = [1, -0.16161616, 0.0083333, -0.00019841, -0.5, 0.041666666, -0.0013888889, 0.000024801587]
            return RealTimeEffectValues(
                multiples.map { input.isRealTime ? Float(speed * $0) : loopSpeedAllowingStill(speed * $0) } + [
                    value(Key.strength), value(Key.phase), value(Key.power), value(Key.noiseScale),
                    value(Key.ratio), value(Key.angle)
                ]
            )
        case .pulseBlend:
            typealias Key = SceneEffect.PulseKey
            // The noise term wanders on its own; a baked loop does not close exactly.
            return RealTimeEffectValues([
                loopSpeed(effect.value(Key.speed), input: input), value(Key.phase), value(Key.amount),
                value(Key.boundsMin), value(Key.boundsMax), value(Key.noiseSpeed), value(Key.noiseAmount),
                value(Key.power), value(Key.lowRed), value(Key.lowGreen), value(Key.lowBlue),
                value(Key.highRed), value(Key.highGreen), value(Key.highBlue), value(Key.blendMode),
                value(Key.pulsesColor), value(Key.pulsesOpacity)
            ])
        case .uvScroll:
            typealias Key = SceneEffect.ScrollKey
            func speed(_ raw: Double, repeats: Double) -> Float {
                let perSecond = raw * abs(raw)
                guard !input.isRealTime, repeats != 0, perSecond != 0 else {
                    return Float(perSecond)
                }
                // Whole wraps of the repeated picture per loop, at least one.
                let loop = Double(max(document.loopSeconds, 1))
                let wraps = max((abs(perSecond * repeats) * loop).rounded(), 1)
                return Float((perSecond < 0 ? -1 : 1) * wraps / (abs(repeats) * loop))
            }
            let repeatX = effect.value(Key.repeatX), repeatY = effect.value(Key.repeatY)
            return RealTimeEffectValues([
                speed(effect.value(Key.speedX), repeats: repeatX), speed(effect.value(Key.speedY), repeats: repeatY),
                Float(repeatX), Float(repeatY)
            ])
        case .opacityMask:
            return RealTimeEffectValues([value("alpha")])
        case .axisSwing:
            typealias Key = SceneEffect.AxisSwingKey
            return RealTimeEffectValues([
                loopSpeed(effect.value(Key.speed), input: input), value(Key.phase), value(Key.amount),
                value(Key.x0), value(Key.y0), value(Key.x1), value(Key.y1), value(Key.size),
                value(Key.center), value(Key.feather), value(Key.doubleSided), value(Key.noise),
                value(Key.noiseSpeed), value(Key.noiseAmount), textureAspect(effect)
            ])
        default:
            return RealTimeEffectValues([])
        }
    }

    /// A rate in cycles per second, rounded to whole cycles per loop unless drawn on
    /// real time; a motion that would round to none keeps one cycle, or a slow drift
    /// would stop altogether in a baked loop.
    private func loopRate(_ rate: Double, input: SceneFrameInput) -> Float {
        guard !input.isRealTime, rate != 0 else {
            return Float(rate)
        }
        let loop = Double(max(document.loopSeconds, 1))
        let cycles = max((abs(rate) * loop).rounded(), 1)
        return Float((rate < 0 ? -1 : 1) * cycles / loop)
    }

    /// The stored picture's width over height when the effect names it, else the
    /// layer picture's.
    private func textureAspect(_ effect: SceneEffect) -> Float {
        Float(effect.values[SceneEffect.textureAspectKey] ?? 0)
    }

    /// Like loopSpeed, but a speed too slow for one turn per loop stands still.
    private func loopSpeedAllowingStill(_ speed: Double) -> Float {
        let loop = Double(max(document.loopSeconds, 1))
        let turns = (speed * loop / (2 * .pi)).rounded()
        return Float(turns * 2 * .pi / loop)
    }

    /// Runs the layer's effects and returns the texture to composite.
    private func applyEffects(
        to layer: SceneLayer,
        commandBuffer: MTLCommandBuffer,
        input: SceneFrameInput,
        targetSize: SIMD2<Float>,
        canvasSource: MTLTexture? = nil,
        compositeUniforms: LayerUniforms? = nil
    ) throws -> MTLTexture {
        let viewSize = SIMD2(input.viewport.z, input.viewport.w)
        let shown = targetSize / viewSize / layerUVScale(for: layer) * effectResolutionScale
        var source: MTLTexture
        if layer.capturesCanvas {
            let width = max(Int((targetSize.x * effectResolutionScale).rounded()), 16)
            let height = max(Int((targetSize.y * effectResolutionScale).rounded()), 16)
            let capture = try captureTexture(for: layer.id, width: width, height: height)
            try capturePass(
                commandBuffer: commandBuffer, destination: capture, base: canvasSource ?? blackTexture,
                uniforms: compositeUniforms ?? Self.passThroughUniforms
            )
            source = capture
        } else if layer.kind == .particles, layer.particleSystem != nil {
            source = try renderParticleSystem(layer, commandBuffer: commandBuffer, input: input, targetSize: targetSize,
                                              background: canvasSource ?? blackTexture)
        } else if layer.kind == .particles, let particles = layer.particles {
            source = try renderParticles(
                particles, layerID: layer.id, commandBuffer: commandBuffer, input: input, targetSize: targetSize
            )
        } else if let image = picture(for: layer) {
            source = image
        } else {
            return blackTexture
        }
        if let graph = graphRenderers[layer.id] {
            source = try graph.encode(input: source, images: graphResources[layer.id]!, time: input.time,
                                      cursor: input.cursor, audio: input.audio, meshes: lastFrame?.meshes ?? [],
                                      layerFromCanvas: graph.usesLayerPlacement ? layerFromCanvas(layer) : matrix_identity_float3x3,
                                      pointerPresses: input.pointerPresses, parallax: input.parallax,
                                      background: canvasSource ?? blackTexture,
                                      commandBuffer: commandBuffer)
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
        let width = layer.capturesCanvas ? source.width : max(min(Int(shown.x.rounded()), source.width), 16)
        let height = layer.capturesCanvas ? source.height : max(min(Int(shown.y.rounded()), source.height), 16)

        let standardEffectCount = effects.filter { graphRenderers[$0.id] == nil }.count
        let layerTarget = standardEffectCount > 0 ? try effectLayerTexture(for: layer.id, width: width, height: height) : nil
        let scratchTarget = standardEffectCount > 1 ? try effectScratchTexture(width: width, height: height) : nil

        let phase = loopPhase(input.time)
        let aspect = Float(source.width) / Float(max(source.height, 1))
        var current = source
        var standardIndex = 0
        let startsWithLayerTarget = (standardEffectCount % 2 != 0)

        for effect in effects {
            if let graph = graphRenderers[effect.id] {
                current = try graph.encode(input: current, images: graphResources[effect.id]!, time: input.time,
                                           cursor: input.cursor, values: effect.values, audio: input.audio,
                                           meshes: lastFrame?.meshes ?? [],
                                           layerFromCanvas: graph.usesLayerPlacement ? layerFromCanvas(layer) : matrix_identity_float3x3,
                                      pointerPresses: input.pointerPresses, parallax: input.parallax,
                                      background: canvasSource ?? blackTexture,
                                           commandBuffer: commandBuffer)
                continue
            }
            let isLayerTarget = startsWithLayerTarget ? (standardIndex % 2 == 0) : (standardIndex % 2 != 0)
            let destination = isLayerTarget ? layerTarget! : scratchTarget!
            standardIndex += 1

            let override = paintOverride?.effectID == effect.id ? paintOverride : nil
            let mask = override?.target == .mask ? paintOverrideTexture : effect.maskFile.flatMap {
                effect.kind == .opacityMask ? flowTextures[$0] : maskTextures[$0]
            }
            let flow = override?.target == .flow ? paintOverrideTexture : effect.flowFile.flatMap { flowTextures[$0] }
            let timeOffset = override?.target == .timeOffset
                ? paintOverrideTexture : effect.timeOffsetFile.flatMap { maskTextures[$0] }
            let pattern = effect.patternFile.flatMap { flowTextures[$0] }
            let radians = Float(effect.direction * .pi / 180)
            // UV y points down, the direction angle counts counter-clockwise with y up.
            let direction = SIMD2<Float>(cos(radians), -sin(radians))
            let bounds = effect.areaBounds ?? .whole
            var uniforms = EffectUniforms(
                bounds: SIMD4(Float(bounds.minX), Float(bounds.minY), Float(bounds.maxX), Float(bounds.maxY)),
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
                overlay: paintTint(override),
                hasMask: mask == nil ? 0 : 1,
                fixedEdge: Int32(SceneFixedEdge.allCases.firstIndex(of: effect.fixedEdge) ?? 0),
                // A baked loop reads its own time within the loop, so the rounded
                // speeds land exactly where the loop starts again.
                time: Float(input.isRealTime ? input.time : Double(phase) * Double(max(document.loopSeconds, 1))),
                hasTimeOffset: timeOffset == nil ? 0 : 1,
                patternClamps: effect.value(SceneEffect.patternClampsKey) != 0 ? 1 : 0
            )
            var realTime = realTimeValues(effect, input: input)
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
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<EffectUniforms>.stride, index: 0)
            var pins = puppetPins(effect, phase: phase, aspect: aspect)
            encoder.setFragmentBytes(&pins, length: MemoryLayout<SIMD4<Float>>.stride * pins.count, index: 1)
            encoder.setFragmentBytes(&realTime, length: MemoryLayout<RealTimeEffectValues>.stride, index: 2)
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

    private func effectLayerTexture(for layerID: UUID, width: Int, height: Int) throws -> MTLTexture {
        if let existing = effectLayerTargets[layerID], existing.width == width, existing.height == height {
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
        if let existing = captureTargets[layerID], existing.width == width, existing.height == height {
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
        // The whole canvas at the zoomed-in density, within texture limits.
        var canvasSize = targetSize / SIMD2(input.viewport.z, input.viewport.w)
        canvasSize *= min(1, Float(Self.maxTextureEdge) / max(canvasSize.x, canvasSize.y))
        // Glows are soft, so half the resolution looks the same at a quarter of the cost.
        let size = particles.preset.isAdditive ? canvasSize * 0.5 : canvasSize
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

    private func particleSimulator(for layer: SceneLayer, system: SceneParticleSystem) -> SceneParticleSimulator {
        if let existing = particleSimulators[layer.id], existing.system == system { return existing }
        let bytes = layer.id.uuid
        let seed = [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7]
            .reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let simulator = SceneParticleSimulator(system: system, seed: seed)
        particleSimulators[layer.id] = simulator
        return simulator
    }

    private func advanceParticles(_ evaluated: SceneEvaluatedFrame, input: SceneFrameInput) {
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
            let toCanvas = particleLocalToCanvas(evaluated.layers[layer.id]?.transform ?? layer.transform)
            var surroundings = SceneParticleSimulator.Surroundings()
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
    private func particleLocalToCanvas(_ transform: SceneTransform) -> simd_float3x3 {
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
    private func renderParticleSystem(
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
        if let existing = particleTargets[layer.id], existing.width == width, existing.height == height,
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
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<ParticleSystemUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ParticleSystemUniforms>.stride, index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentTexture(background, index: 1)
            encoder.setFragmentTexture(normal ?? whiteTexture, index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
        }
        return target
    }

    private func mipmapped(_ texture: MTLTexture) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: true
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
        encoder.setRenderPipelineState(pipeline.composite(for: destination.pixelFormat))
        encoder.setFragmentTexture(base, index: 0)
        encoder.setFragmentTexture(layerTexture, index: 1)
        encoder.setFragmentTexture(depth ?? whiteMask, index: 2)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func capturePass(
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

    private static let passThroughUniforms = LayerUniforms(
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
    private func layerUVScale(for layer: SceneLayer) -> SIMD2<Float> {
        let canvasAspect = Float(document.aspectRatio)
        let layerAspect: Float
        if layer.kind == .text {
            // Text keeps its pixel size instead of filling the canvas, and does not
            // move with the parallax zoom.
            let size = textTextures[layer.id]?.canvasSize ?? SIMD2(1, 1)
            return SIMD2(Float(Double(document.canvasWidth) / size.x), Float(Double(document.canvasHeight) / size.y))
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
            shift = input.parallax * Float(min(max(layer.parallaxDepth, 0), 1)) * Self.maxParallaxTravel
        }
        if let shake = document.cameraShake {
            let offset = shake.offset(at: input.time)
            shift += SIMD2(Float(offset.x / document.aspectRatio), Float(offset.y))
        }
        return shift
    }

    private func depthTravel(for layer: SceneLayer) -> Float {
        layer.hasDepth ? Float(min(max(layer.depthStrength, 0), 1)) * Self.maxParallaxTravel : 0
    }

    private struct Placement {
        let column0: SIMD2<Float>
        let column1: SIMD2<Float>
        let offset: SIMD2<Float>
    }

    private static func inversePlacement(_ matrix: simd_float3x3) -> simd_float3x3? {
        // A script can shrink one axis until Float's reciprocal determinant overflows,
        // even while every element of the inverse still fits in Float.
        let wide = simd_double3x3(columns: (
            SIMD3<Double>(matrix.columns.0), SIMD3<Double>(matrix.columns.1), SIMD3<Double>(matrix.columns.2)
        ))
        guard simd_determinant(wide) != 0 else { return nil }
        let inverse = simd_inverse(wide)
        let result = simd_float3x3(columns: (
            SIMD3<Float>(inverse.columns.0), SIMD3<Float>(inverse.columns.1), SIMD3<Float>(inverse.columns.2)
        ))
        // Collapsed geometry has no representable UV mapping for the GPU or picking.
        return [result.columns.0, result.columns.1, result.columns.2].allSatisfy {
            $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
        } ? result : nil
    }

    private func placementMatrix(_ transform: SceneTransform) -> simd_float3x3 {
        let angle = Float(transform.rotation * .pi / 180)
        let scaleX = Float(transform.scale), scaleY = Float(transform.scaleY ?? transform.scale), aspect = Float(document.aspectRatio)
        let column0 = SIMD3(cos(angle), sin(angle) * aspect, 0) * scaleX
        let column1 = SIMD3(-sin(angle) / aspect, cos(angle), 0) * scaleY
        return simd_float3x3(columns: (column0, column1, SIMD3(
            0.5 + Float(transform.offsetX) - (column0.x + column1.x) * 0.5,
            0.5 + Float(transform.offsetY) - (column0.y + column1.y) * 0.5, 1
        )))
    }

    /// The inverse of the layer's placement in canvas UV. Rotation happens in a space
    /// with the canvas's proportions, so a turned layer is not skewed.
    private func placement(for transform: SceneTransform) -> Placement {
        let aspect = Float(document.aspectRatio)
        let radians = Float(transform.rotation * .pi / 180)
        let c = cos(radians)
        let s = sin(radians)
        let inverseScaleX = 1 / Float(max(abs(transform.scale), 0.0001)) * (transform.scale < 0 ? -1 : 1)
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
    private func depthSteps(shift: SIMD2<Float>, scale: SIMD2<Float>, targetSize: SIMD2<Float>) -> Int32 {
        let pixels = shift / scale * targetSize
        let sweep = 2 * max(abs(pixels.x), abs(pixels.y))
        return Int32(min(max((sweep / 10).rounded(.up), 4), 12))
    }

    private func compositeUniforms(
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
            placement = Placement(column0: SIMD2(inverse.columns.0.x, inverse.columns.0.y),
                                  column1: SIMD2(inverse.columns.1.x, inverse.columns.1.y),
                                  offset: SIMD2(center.x, center.y) - 0.5)
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
        let depthShift = layerDirection(depthView.clamped(lowerBound: SIMD2(repeating: -1), upperBound: SIMD2(repeating: 1))
            * depthTravel(for: layer))

        // Mask distances are measured in units of the canvas's shorter side.
        let maskScale = canvasAspect >= 1 ? SIMD2<Float>(canvasAspect, 1) : SIMD2<Float>(1, 1 / canvasAspect)
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
            hasDepth: layer.hasDepth && layer.depthFile.flatMap({ maskTextures[$0] }) != nil ? 1 : 0,
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
    private func picture(for layer: SceneLayer) -> MTLTexture? {
        if layer.kind == .text { return textTextures[layer.id]?.texture }
        if layer.usesMediaArtwork, let texture = mediaArtworkTextures[layer.id] { return texture }
        return layer.videoFile.flatMap { videoFramesShown[$0]?.texture } ?? textures[layer.imageFile]
    }

    private func prepareMediaArtwork(_ media: SceneMediaState?) throws {
        let id = media?.isAvailable == true ? media!.artworkID : ""
        guard mediaArtworkID != id else { return }
        mediaArtworkTextures = [:]
        mediaArtworkID = ""
        guard !id.isEmpty, let data = media?.artworkData else { return }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
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
    private func placedTransform(_ layer: SceneLayer, _ transform: SceneTransform) -> SceneTransform {
        guard layer.kind == .text, let offset = textTextures[layer.id]?.centerOffset else { return transform }
        // The rotation turns clockwise on the canvas, whose y points down; the offset
        // has y up.
        let radians = -transform.rotation * .pi / 180
        let scaled = SIMD2(offset.x * transform.scale, offset.y * (transform.scaleY ?? transform.scale))
        let turned = SIMD2(scaled.x * cos(radians) - scaled.y * sin(radians), scaled.x * sin(radians) + scaled.y * cos(radians))
        var placed = transform
        placed.offsetX += turned.x / Double(document.canvasWidth)
        placed.offsetY -= turned.y / Double(document.canvasHeight)
        return placed
    }

    private func prepareText(_ layer: SceneLayer) throws {
        guard let text = layer.text else {
            textTextures[layer.id] = nil
            return
        }
        if textTextures[layer.id]?.text == text { return }
        guard let raster = try SceneTextRasterizer.render(text, fontURL: text.fontFile.map(fileURL)) else {
            textTextures[layer.id] = TextTexture(text: text, texture: nil, canvasSize: SIMD2(1, 1), centerOffset: .zero)
            return
        }
        let texture = try Self.makeTexture(
            device: device, pixelFormat: .rgba8Unorm, width: raster.width, height: raster.height, bytes: raster.bytes
        )
        textTextures[layer.id] = TextTexture(
            text: text, texture: texture, canvasSize: raster.canvasSize, centerOffset: raster.centerOffset
        )
    }

    // MARK: - Resources

    private func ensureAccumulation(width: Int, height: Int, format: MTLPixelFormat) throws {
        if let first = accumulation.first, first.width == width, first.height == height, first.pixelFormat == format {
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false
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
        if rigs?.skeletons != document.rigs {
            rigs = try SceneSkeletonRegistry(document.rigs)
            graphRenderers.removeAll()
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
        pendingParticleControls = pendingParticleControls.filter { particleSimulators[$0.key] != nil }
        let spriteFiles = Set(document.layers.compactMap(\.particleSystem).flatMap(\.textureFiles))
        particleTextures = particleTextures.filter { spriteFiles.contains($0.key) }
        let normalFiles = Set(document.layers.compactMap(\.particleSystem).flatMap(\.normalFiles))
        for file in spriteFiles where particleTextures[file] == nil {
            // Normal maps are opaque data; sprites keep their soft edge.
            let alpha: ImageAlpha = normalFiles.contains(file) ? .straightDropped : .straightKept
            let image = try Self.cachedTexture(url: fileURL(file), variant: "rgba-\(alpha)") { url in
                try Self.decodeRGBA(url: url, device: device, alpha: alpha)
            }
            particleTextures[file] = try mipmapped(image)
        }
        let meshMaterials = document.meshMaterials ?? []
        let hasModelLayers = document.layers.contains { $0.model != nil }
        if modelRenderer?.materials != meshMaterials || (modelRenderer == nil && hasModelLayers) {
            modelRenderer = (meshMaterials.isEmpty && !hasModelLayers) ? nil : try SceneModelRenderer(materials: meshMaterials, device: device)
            modelImages = [:]
            for file in modelRenderer?.imageFiles ?? [] {
                // Materials read the alpha of their images as it was saved.
                modelImages[file] = try Self.cachedTexture(url: fileURL(file), variant: "rgba-\(ImageAlpha.straightKept)") { url in
                    try Self.decodeRGBA(url: url, device: device, alpha: .straightKept)
                }
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
        for (id, graph) in graphs where graphRenderers[id]?.graph != graph {
            graphRenderers[id] = try SceneRenderGraphRenderer(graph: graph, device: device, rigs: rigs, pool: graphTexturePool)
        }
        var retainedGraphTextures: [String: MTLTexture] = [:]
        graphResources = [:]
        for (id, graph) in graphs {
            var resources: [String: MTLTexture] = [:]
            // A particle sprite's alpha is its soft edge. Dropping it (as other straight images
            // do) fills the whole quad with opaque black around the glow.
            let spriteFiles = Set(
                graph.passes.compactMap { $0.draw?.dynamic }.flatMap(\.materials.values).flatMap { $0 }
                    .compactMap { graph.images[$0.source] }
            )
            for file in Set(graph.images.values) {
                let straight = graph.straightAlphaImages == true
                let alpha: ImageAlpha = !straight ? .premultiplied : spriteFiles.contains(file) ? .straightKept : .straightDropped
                let key = "\(alpha):\(file)"
                let texture = try graphTextures[key] ?? Self.cachedTexture(url: fileURL(file), variant: "rgba-\(alpha)") { url in
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

        let images = Set(document.layers.filter { $0.kind == .image && !$0.imageFile.isEmpty }.map(\.imageFile))
        textures = textures.filter { images.contains($0.key) }
        for file in images where textures[file] == nil {
            textures[file] = try Self.cachedTexture(url: fileURL(file), variant: "rgba-\(ImageAlpha.premultiplied)") { url in
                try Self.decodeRGBA(url: url, device: device)
            }
        }

        let effects = document.layers.flatMap(\.effects)
        let masks = Set(
            effects.filter { $0.kind != .opacityMask }.compactMap(\.maskFile) + effects.compactMap(\.timeOffsetFile)
                + document.layers.compactMap { $0.particles?.maskFile }
                + document.layers.compactMap(\.depthFile)
        )
        maskTextures = maskTextures.filter { masks.contains($0.key) }
        for file in masks where maskTextures[file] == nil {
            maskTextures[file] = try Self.cachedTexture(url: fileURL(file), variant: "mask") { url in
                try Self.decodeMask(url: url, device: device)
            }
        }
        let flows = Set(
            effects.compactMap(\.flowFile) + effects.compactMap(\.patternFile)
                + effects.filter { $0.kind == .opacityMask }.compactMap(\.maskFile)
        )
        flowTextures = flowTextures.filter { flows.contains($0.key) }
        for file in flows where flowTextures[file] == nil {
            flowTextures[file] = try Self.cachedTexture(url: fileURL(file), variant: "rgba-\(ImageAlpha.straightDropped)") { url in
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
        for layer in modelLayers {
            guard let model = layer.model else { continue }
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
                    guard let base = bytes.baseAddress, bytes.count > 0 else { return nil }
                    return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
                }
                guard let buffer else { throw RendererError.textureAllocationFailed }
                shape.vertexBuffer = buffer
            }
            if let indices = shape.indices, !indices.isEmpty {
                let buffer: (any MTLBuffer)? = indices.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress, bytes.count > 0 else { return nil }
                    return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
                }
                guard let buffer else { throw RendererError.textureAllocationFailed }
                shape.indexBuffer = buffer
            }
            staticShapes[layer.id] = StaticShapeCache(model: model, shape: shape)
        }
    }

    /// Keyed by the file's content, not its name: scenes ship the same image under several
    /// names (and layers and graphs reference it separately), and each copy would otherwise
    /// hold its own decoded texture. The variant is the decode mode, so only textures that
    /// decode identically are shared. Content also covers an imported package replacing a
    /// scene folder with files of the same names.
    private static func cachedTexture(
        url: URL,
        variant: String,
        decode: (URL) throws -> MTLTexture
    ) throws -> MTLTexture {
        let key = try variant + "|" + contentDigest(of: url)
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

    private static let digestLock = NSLock()
    private nonisolated(unsafe) static var digests: [String: String] = [:]

    /// Hashing reads the whole file, so the result is remembered per file identity.
    private static func contentDigest(of url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let identity = [
            url.standardizedFileURL.path,
            String(values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0),
            String(values.fileSize ?? 0)
        ].joined(separator: "|")
        digestLock.lock()
        let known = digests[identity]
        digestLock.unlock()
        if let known {
            return known
        }
        let digest = try SHA256.hash(data: Data(contentsOf: url, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        digestLock.lock()
        digests[identity] = digest
        digestLock.unlock()
        return digest
    }

    private func fileURL(_ name: String) -> URL {
        SceneStore.folderURL(forVideoPath: videoPath).appendingPathComponent(name)
    }

    /// Decodes into sRGB RGBA8 so the shader knows exactly what it samples, whatever
    /// the file's color space or alpha layout. Flow maps are data: an sRGB file read
    /// into an sRGB context comes back unchanged, and they are never premultiplied.
    private enum ImageAlpha { case premultiplied, straightDropped, straightKept }

    private static func decodeRGBA(url: URL, device: MTLDevice, alpha mode: ImageAlpha = .premultiplied) throws -> MTLTexture {
        let image = try decodeImage(url: url)
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let alpha: CGImageAlphaInfo = mode == .straightDropped ? .noneSkipLast : .premultipliedLast
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
        if mode == .straightKept {
            for pixel in stride(from: 0, to: bytes.count, by: 4) where bytes[pixel + 3] != 0 && bytes[pixel + 3] != 255 {
                let a = Int(bytes[pixel + 3])
                for channel in 0 ..< 3 {
                    bytes[pixel + channel] = UInt8(min(255, (Int(bytes[pixel + channel]) * 255 + a / 2) / a))
                }
            }
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
        var compositeFetchWide: MTLRenderPipelineState?
        if device.supportsFamily(.apple1) {
            let fetchLibrary = try device.makeLibrary(source: fetchShaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = fetchLibrary.makeFunction(name: "scene_vertex")
            descriptor.fragmentFunction = fetchLibrary.makeFunction(name: "scene_composite_fetch")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            compositeFetch = try device.makeRenderPipelineState(descriptor: descriptor)
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float
            compositeFetchWide = try device.makeRenderPipelineState(descriptor: descriptor)
        }
        let pipeline = try Pipeline(
            device: device, queue: queue,
            composite: state(fragment: "scene_composite", format: .bgra8Unorm),
            capture: state(fragment: "scene_capture", format: .rgba8Unorm),
            effect: state(fragment: "scene_effect", format: .rgba8Unorm),
            particlesOver: state(vertex: "particle_vertex", fragment: "particle_fragment", format: .rgba8Unorm, additive: false),
            particlesAdd: state(vertex: "particle_vertex", fragment: "particle_fragment", format: .rgba8Unorm, additive: true),
            particleSystemOver: state(vertex: "particle_system_vertex", fragment: "particle_system_fragment", format: .rgba8Unorm, additive: false),
            particleSystemAdd: state(vertex: "particle_system_vertex", fragment: "particle_system_fragment", format: .rgba8Unorm, additive: true),
            particleSystemOverWide: state(vertex: "particle_system_vertex", fragment: "particle_system_fragment", format: .rgba16Float, additive: false),
            particleSystemAddWide: state(vertex: "particle_system_vertex", fragment: "particle_system_fragment", format: .rgba16Float, additive: true),
            compositeFetch: compositeFetch,
            compositeWide: state(fragment: "scene_composite", format: .rgba16Float),
            compositeFetchWide: compositeFetchWide
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
        return float4(compositeLayer(below.rgb, u.viewOrigin + in.uv * u.viewSize, layer, depth, u), 1.0);
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
        float2 viewOrigin;
        float2 viewSize;
        int hasDepth;
        int depthSteps;
        float opacity;
        float maskRadius;
        float maskSoftness;
        int blendMode;
        int maskMode;
        int hasCursor;
        int hasLayer;
        float brightness;
        float saturation;
        float warmth;
        int hasColor;
        float tintRed;
        float tintGreen;
        float tintBlue;
    };

    float3 rgbToHSL(float3 c) {
        float low = min(min(c.r, c.g), c.b), high = max(max(c.r, c.g), c.b), delta = high - low;
        float3 hsl = float3(0.0, 0.0, (high + low) / 2.0);
        if (delta == 0.0) { return hsl; }
        hsl.y = hsl.z < 0.5 ? delta / (high + low) : delta / (2.0 - high - low);
        float3 d = (((high - c) / 6.0) + (delta / 2.0)) / delta;
        if (c.r == high) { hsl.x = d.b - d.g; }
        else if (c.g == high) { hsl.x = (1.0 / 3.0) + d.r - d.b; }
        else { hsl.x = (2.0 / 3.0) + d.g - d.r; }
        hsl.x = hsl.x < 0.0 ? hsl.x + 1.0 : (hsl.x > 1.0 ? hsl.x - 1.0 : hsl.x);
        return hsl;
    }

    float hueToRGB(float f1, float f2, float hue) {
        hue = hue < 0.0 ? hue + 1.0 : (hue > 1.0 ? hue - 1.0 : hue);
        if (6.0 * hue < 1.0) { return f1 + (f2 - f1) * 6.0 * hue; }
        if (2.0 * hue < 1.0) { return f2; }
        if (3.0 * hue < 2.0) { return f1 + (f2 - f1) * ((2.0 / 3.0) - hue) * 6.0; }
        return f1;
    }

    float3 hslToRGB(float3 hsl) {
        if (hsl.y == 0.0) { return float3(hsl.z); }
        float f2 = hsl.z < 0.5 ? hsl.z * (1.0 + hsl.y) : (hsl.z + hsl.y) - (hsl.y * hsl.z);
        float f1 = 2.0 * hsl.z - f2;
        return float3(hueToRGB(f1, f2, hsl.x + 1.0 / 3.0), hueToRGB(f1, f2, hsl.x), hueToRGB(f1, f2, hsl.x - 1.0 / 3.0));
    }

    float3 overlayBlend(float3 b, float3 s) { return select(1.0 - 2.0 * (1.0 - b) * (1.0 - s), 2.0 * b * s, b < 0.5); }
    float colorDodgeF(float b, float s) { return s == 1.0 ? s : min(b / (1.0 - s), 1.0); }
    float colorBurnF(float b, float s) { return s == 0.0 ? s : max(1.0 - (1.0 - b) / s, 0.0); }
    float vividLightF(float b, float s) { return s < 0.5 ? colorBurnF(b, 2.0 * s) : colorDodgeF(b, 2.0 * (s - 0.5)); }
    float reflectF(float b, float s) { return s == 1.0 ? s : min(b * b / (1.0 - s), 1.0); }
    float3 perChannel(int mode, float3 b, float3 s) {
        float3 r;
        for (int i = 0; i < 3; i++) {
            float x = b[i], y = s[i];
            switch (mode) {
            case 6: r[i] = colorBurnF(x, y); break;
            case 10: r[i] = colorDodgeF(x, y); break;
            case 12: r[i] = y < 0.5 ? 2.0 * x * y + x * x * (1.0 - 2.0 * y) : sqrt(x) * (2.0 * y - 1.0) + 2.0 * x * (1.0 - y); break;
            case 14: r[i] = vividLightF(x, y); break;
            case 15: r[i] = y < 0.5 ? max(x + 2.0 * y - 1.0, 0.0) : x + 2.0 * (y - 0.5); break;
            case 16: r[i] = y < 0.5 ? min(2.0 * y, x) : max(2.0 * (y - 0.5), x); break;
            case 17: r[i] = vividLightF(x, y) < 0.5 ? 0.0 : 1.0; break;
            case 20: r[i] = reflectF(x, y); break;
            default: r[i] = reflectF(y, x); break;
            }
        }
        return r;
    }
    /// The blended colour that the layer's alpha then mixes in, by SceneBlendMode position.
    float3 blend(int mode, float3 b, float3 s) {
        switch (mode) {
        case 1: return b * s;
        case 2: return 1.0 - (1.0 - b) * (1.0 - s);
        case 3: return overlayBlend(b, s);
        case 4: return min(b + s, 1.0);
        case 5: return min(s, b);
        case 7: return max(b + s - 1.0, 0.0);
        case 8: return min(b, s);
        case 9: return max(s, b);
        case 11: return max(b, s);
        case 13: return overlayBlend(s, b);
        case 18: return abs(b - s);
        case 19: return b + s - 2.0 * b * s;
        case 22: return min(b, s) - max(b, s) + 1.0;
        case 23: return (b + s) / 2.0;
        case 24: return 1.0 - abs(1.0 - b - s);
        case 25: { float3 l = rgbToHSL(b); return hslToRGB(float3(rgbToHSL(s).x, l.y, l.z)); }
        case 26: { float3 l = rgbToHSL(b); return hslToRGB(float3(l.x, rgbToHSL(s).y, l.z)); }
        case 27: { float3 l = rgbToHSL(s); return hslToRGB(float3(l.x, l.y, rgbToHSL(b).z)); }
        case 28: { float3 l = rgbToHSL(b); return hslToRGB(float3(l.x, l.y, rgbToHSL(s).z)); }
        case 29: return max(b.x, max(b.y, b.z)) * s;
        case 30: return b + s;
        case 31: return b + b * s;
        case 6: case 10: case 12: case 14: case 15: case 16: case 17: case 20: case 21: return perChannel(mode, b, s);
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
        // minimum and maximum ignore alpha across the picture; elsewhere nothing changes.
        if (u.blendMode == 8 || u.blendMode == 11) {
            bool inside = all(layerUV >= 0.0) && all(layerUV <= 1.0);
            float3 straight = src.a > 0.0 ? src.rgb / src.a : float3(0.0);
            return inside ? blend(u.blendMode, below, straight) : below;
        }
        float alpha = src.a * u.opacity;
        float3 color = src.a > 0.0 ? src.rgb / src.a : float3(0.0);
        // Skipped when unchanged, so layers without links draw exactly as before.
        if (u.hasColor != 0) {
            color *= float3(u.tintRed, u.tintGreen, u.tintBlue);
            float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
            color = mix(float3(luma), color, u.saturation);
            color *= float3(1.0 + 0.2 * u.warmth, 1.0, 1.0 - 0.2 * u.warmth);
            color = clamp(color * (1.0 + u.brightness), 0.0, 1.0);
        }
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

    fragment float4 scene_capture(VertexOut in [[stage_in]],
                                  texture2d<float> base [[texture(0)]],
                                  constant LayerUniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 placed = (in.uv - 0.5 - u.uvOffset) / u.uvScale;
        float det = u.placementColumn0.x * u.placementColumn1.y - u.placementColumn1.x * u.placementColumn0.y;
        if (abs(det) < 1e-8) { return float4(0.0); }
        float2 relative = float2(u.placementColumn1.y * placed.x - u.placementColumn1.x * placed.y,
                                 -u.placementColumn0.y * placed.x + u.placementColumn0.x * placed.y) / det;
        float2 canvasUV = relative + 0.5 + u.placementOffset;
        float2 targetUV = (canvasUV - u.viewOrigin) / u.viewSize;
        return float4(base.sample(s, targetUV).rgb, 1.0);
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
        return float4(compositeLayer(below.rgb, u.viewOrigin + in.uv * u.viewSize, layer, depth, u), 1.0);
    }

    // MARK: effects

    struct EffectUniforms {
        float4 bounds;
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
        int fixedEdge;
        float time;
        int hasTimeOffset;
        int patternClamps;
    };

    constant float TAU = 6.28318530718;

    float2 rotate2(float2 v, float angle) {
        float c = cos(angle), s = sin(angle);
        return float2(v.x * c - v.y * s, v.x * s + v.y * c);
    }

    float4 samplePattern(texture2d<float> pattern, float2 uv, constant EffectUniforms &u) {
        constexpr sampler clamped(filter::linear, address::clamp_to_edge);
        constexpr sampler repeating(filter::linear, address::repeat);
        return u.patternClamps != 0 ? pattern.sample(clamped, uv) : pattern.sample(repeating, uv);
    }

    float layerAspect(float stored, constant EffectUniforms &u) { return stored > 0.0 ? stored : u.aspect; }

    // Flow map (values: rate, strength, feather, phaseScale). Two pairs of copies a
    // quarter cycle apart, each pair crossfading as one copy resets.
    float4 flowMap(texture2d<float> src, texture2d<float> flow, texture2d<float> pattern, sampler s, float2 uv,
                   constant EffectUniforms &u, constant float *v) {
        float t = u.time * v[0];
        float4 cycles = fract(float4(t, t + 0.5, 0.25 + t, 0.75 + t));
        float2 edges = float2(0.5 - v[2], 0.5 + v[2]);
        float blend = smoothstep(edges.x, edges.y, 2.0 * abs(cycles.x - 0.5));
        float blend2 = smoothstep(edges.x, edges.y, 2.0 * abs(cycles.z - 0.5));
        cycles -= 0.5;
        float phase = samplePattern(pattern, uv * v[3], u).r;
        float2 flowVector = (flow.sample(s, uv).rg - float2(0.498)) * 2.0;
        float2 travel = flowVector * v[1] * 0.1;
        float4 a = mix(src.sample(s, uv + travel * cycles.x), src.sample(s, uv + travel * cycles.y), blend);
        float4 b = mix(src.sample(s, uv + travel * cycles.z), src.sample(s, uv + travel * cycles.w), blend2);
        float4 flowing = mix(a, b, smoothstep(0.2, 0.8, phase));
        return mix(src.sample(s, uv), flowing, length(flowVector));
    }

    // Normal ripples (values: animationSpeed, scale, scrollSpeed, scrollAngle, ratio,
    // strength, textureAspect, specular, power, strength, rgb).
    float4 normalRipples(texture2d<float> src, texture2d<float> mask, texture2d<float> pattern, sampler s, float2 uv,
                         constant EffectUniforms &u, constant float *v) {
        float m = u.hasMask != 0 ? mask.sample(s, uv).r : 1.0;
        float2 scroll = float2(-sin(v[3]), cos(v[3])) * v[2] * v[2] * u.time;
        float drift = u.time * v[0] * v[0];
        float4 coords = float4(uv + drift + scroll, uv * 1.333 - drift + scroll) * v[1];
        float aspect = layerAspect(v[6], u);
        coords.xz *= aspect;
        coords.yw *= v[4];
        float3 n1 = samplePattern(pattern, coords.xy, u).xyz * 2.0 - 1.0;
        float3 n2 = samplePattern(pattern, coords.zw, u).xyz * 2.0 - 1.0;
        float3 normal = normalize(float3(n1.xy + n2.xy, n1.z));
        float4 result = src.sample(s, uv + normal.xy * v[5] * v[5] * m);
        if (v[7] != 0.0) {
            float2 toward = normalize(float2(0.5, 0.0) - uv);
            float light = max(0.0, dot(normal.xy, toward)) * max(0.0, dot(toward, float2(0.0, -1.0)));
            result.rgb += pow(light, v[8]) * v[9] * float3(v[10], v[11], v[12]) * result.a;
        }
        return result;
    }

    // Noise drift (values: rate, scale, scaleX, amount, angle, textureAspect).
    float4 noiseDrift(texture2d<float> src, texture2d<float> mask, texture2d<float> pattern, sampler s, float2 uv,
                      constant EffectUniforms &u, constant float *v) {
        float m = u.hasMask != 0 ? mask.sample(s, uv).r : 1.0;
        float2 noiseUV = uv;
        noiseUV.x *= layerAspect(v[5], u);
        noiseUV *= v[1];
        noiseUV.x *= v[2];
        noiseUV.x += u.time * v[0];
        float noise = samplePattern(pattern, noiseUV, u).x;
        float2 offset = rotate2(float2((noise * 2.0 - 1.0) * v[3] * m, 0.0), v[4] + 1.57079632679);
        float2 moved = uv + offset;
        if (u.hasMask != 0) {
            moved = mix(uv, moved, mask.sample(s, uv + offset).r);
        }
        return src.sample(s, moved);
    }

    // Noise sway (values: eight sine speeds, strength, phase, power, noiseScale,
    // ratio, angle).
    float4 noiseSway(texture2d<float> src, texture2d<float> mask, texture2d<float> pattern, sampler s, float2 uv,
                     constant EffectUniforms &u, constant float *v) {
        float stretch = u.aspect * v[12];
        float2 axes = rotate2(float2(1.0 / stretch, stretch), v[13]);
        float2 turned = rotate2(uv, v[13]);
        float amplitude = v[8] * v[8] * 0.005 * (u.hasMask != 0 ? mask.sample(s, uv).r : 1.0);
        float3 noise = samplePattern(pattern, uv * v[11], u).rgb;
        float phase = (noise.g * 3.14159265359 * 2.0 + turned.x * 10.0 + turned.y * 5.0) * v[9];
        float4 sines = sin(phase + u.time * float4(v[0], v[1], v[2], v[3]));
        float4 cosines = sin(0.4 + phase + u.time * float4(v[4], v[5], v[6], v[7]));
        sines = pow(abs(sines), float4(v[10])) * sign(sines);
        cosines = pow(abs(cosines), float4(v[10])) * sign(cosines);
        float2 offset = float2(axes.x * dot(sines, float4(amplitude)), axes.y * dot(cosines, float4(amplitude)));
        return src.sample(s, uv + offset);
    }

    float overlayChannel(float a, float b) { return a < 0.5 ? 2.0 * a * b : 1.0 - 2.0 * (1.0 - a) * (1.0 - b); }
    float softLightChannel(float a, float b) {
        return b < 0.5 ? 2.0 * a * b + a * a * (1.0 - 2.0 * b) : sqrt(a) * (2.0 * b - 1.0) + 2.0 * a * (1.0 - b);
    }
    float dodgeChannel(float a, float b) { return b == 1.0 ? b : min(a / (1.0 - b), 1.0); }
    float burnChannel(float a, float b) { return b == 0.0 ? b : max(1.0 - (1.0 - a) / b, 0.0); }
    float vividChannel(float a, float b) { return b < 0.5 ? burnChannel(a, 2.0 * b) : dodgeChannel(a, 2.0 * (b - 0.5)); }
    float linearLightChannel(float a, float b) {
        return b < 0.5 ? max(a + 2.0 * b - 1.0, 0.0) : a + 2.0 * (b - 0.5);
    }
    float pinChannel(float a, float b) { return b < 0.5 ? min(a, 2.0 * b) : max(a, 2.0 * (b - 0.5)); }
    float reflectChannel(float a, float b) { return b == 1.0 ? b : min(a * a / (1.0 - b), 1.0); }

    // The usual image blend modes, numbered as the pulse effect stores them; each
    // mixes from A towards the blend by `amount`.
    float3 blendModes(int mode, float3 a, float3 b, float amount) {
        float3 blended;
        switch (mode) {
        case 1: blended = min(a, b); break;
        case 2: blended = a * b; break;
        case 3: blended = float3(burnChannel(a.r, b.r), burnChannel(a.g, b.g), burnChannel(a.b, b.b)); break;
        case 4: case 20: blended = max(a + b - 1.0, 0.0); break;
        case 5: return min(a, b);
        case 6: blended = max(a, b); break;
        case 7: blended = 1.0 - (1.0 - a) * (1.0 - b); break;
        case 8: blended = float3(dodgeChannel(a.r, b.r), dodgeChannel(a.g, b.g), dodgeChannel(a.b, b.b)); break;
        case 9: blended = min(a + b, 1.0); break;
        case 10: return max(a, b);
        case 11: blended = float3(overlayChannel(a.r, b.r), overlayChannel(a.g, b.g), overlayChannel(a.b, b.b)); break;
        case 12: blended = float3(softLightChannel(a.r, b.r), softLightChannel(a.g, b.g), softLightChannel(a.b, b.b)); break;
        case 13: blended = float3(overlayChannel(b.r, a.r), overlayChannel(b.g, a.g), overlayChannel(b.b, a.b)); break;
        case 14: blended = float3(vividChannel(a.r, b.r), vividChannel(a.g, b.g), vividChannel(a.b, b.b)); break;
        case 15: blended = float3(linearLightChannel(a.r, b.r), linearLightChannel(a.g, b.g), linearLightChannel(a.b, b.b)); break;
        case 16: blended = float3(pinChannel(a.r, b.r), pinChannel(a.g, b.g), pinChannel(a.b, b.b)); break;
        case 17: blended = float3(vividChannel(a.r, b.r) < 0.5 ? 0.0 : 1.0, vividChannel(a.g, b.g) < 0.5 ? 0.0 : 1.0,
                                  vividChannel(a.b, b.b) < 0.5 ? 0.0 : 1.0); break;
        case 18: blended = abs(a - b); break;
        case 19: blended = a + b - 2.0 * a * b; break;
        case 21: blended = float3(reflectChannel(a.r, b.r), reflectChannel(a.g, b.g), reflectChannel(a.b, b.b)); break;
        case 22: blended = float3(reflectChannel(b.r, a.r), reflectChannel(b.g, a.g), reflectChannel(b.b, a.b)); break;
        case 23: blended = min(a, b) - max(a, b) + 1.0; break;
        case 24: blended = (a + b) / 2.0; break;
        case 25: blended = 1.0 - abs(1.0 - a - b); break;
        case 26: { float3 h = rgbToHSL(a); blended = hslToRGB(float3(rgbToHSL(b).x, h.y, h.z)); break; }
        case 27: { float3 h = rgbToHSL(a); blended = hslToRGB(float3(h.x, rgbToHSL(b).y, h.z)); break; }
        case 28: { float3 h = rgbToHSL(b); blended = hslToRGB(float3(h.x, h.y, rgbToHSL(a).z)); break; }
        case 29: { float3 h = rgbToHSL(a); blended = hslToRGB(float3(h.x, h.y, rgbToHSL(b).z)); break; }
        case 30: blended = float3(max(a.x, max(a.y, a.z))) * b; break;
        case 31: return a + b * amount;
        case 32: blended = a + a * b; break;
        default: blended = b; break;
        }
        return mix(a, blended, amount);
    }

    // Pulse (values: speed, phase, amount, boundsMin, boundsMax, noiseSpeed,
    // noiseAmount, power, low rgb, high rgb, blendMode, pulsesColor, pulsesOpacity).
    float4 pulseBlend(texture2d<float> src, texture2d<float> mask, texture2d<float> pattern, sampler s, float2 uv,
                      constant EffectUniforms &u, constant float *v) {
        float4 sampled = src.sample(s, uv);
        // Blends work on the colour itself, not on colour × opacity.
        float4 colour = sampled.a > 0.0 ? float4(sampled.rgb / sampled.a, sampled.a) : sampled;
        float pulse = smoothstep(v[3], v[4], sin(u.time * v[0] + (v[1] - 1.57079632679)) * 0.5 + 0.5) * v[2];
        pulse += samplePattern(pattern, float2(u.time * 0.08333333, u.time * 0.02777777) * v[5], u).r * v[6];
        pulse = pow(pulse, v[7]);
        float4 result = colour;
        if (v[15] != 0.0) {
            result.rgb = blendModes(int(v[14]), colour.rgb * float3(v[8], v[9], v[10]), colour.rgb * float3(v[11], v[12], v[13]), pulse);
        }
        if (v[16] != 0.0) {
            result.a *= pulse;
        }
        if (u.hasMask != 0) {
            result = mix(colour, result, mask.sample(s, uv).r);
        }
        return float4(max(result.rgb, 0.0) * result.a, result.a);
    }

    // UV scroll (values: speedX, speedY per second, repeatX, repeatY).
    float4 uvScroll(texture2d<float> src, sampler s, float2 uv, constant EffectUniforms &u, constant float *v) {
        return src.sample(s, fract((uv + float2(v[0], v[1]) * u.time) * float2(v[2], v[3])));
    }

    // Axis swing (values: speed, phase, amount, x0, y0, x1, y1, size, center,
    // feather, doubleSided, noise, noiseSpeed, noiseAmount, textureAspect).
    float4 axisSwing(texture2d<float> src, texture2d<float> mask, texture2d<float> pattern, sampler s, float2 uv,
                     constant EffectUniforms &u, constant float *v) {
        float aspect = layerAspect(v[14], u);
        float swing = sin(u.time * v[0] + v[1] * 6.28318530718) * v[2];
        float2 p0 = float2(v[3] * aspect, v[4]), p1 = float2(v[5] * aspect, v[6]);
        float2 q = float2(uv.x * aspect, uv.y);
        float2 axis = normalize(p1 - p0);
        float2 across = float2(-axis.y, axis.x);
        float2 delta = q - (p0 + (p1 - p0) * v[8]);
        float along = dot(axis, delta), side = dot(across, delta);
        if (v[11] != 0.0) {
            float noise = samplePattern(pattern, float2(u.time * 0.08333333, u.time * 0.02777777) * v[12], u).r * 3.141 * 2.0;
            swing = clamp(swing + sin(noise) * v[13], -1.0, 1.0);
        }
        q += axis * swing * side * along + across * swing * swing * side;
        float feather = max(v[9], 0.00001);
        float weight = smoothstep(feather, 0.0, dot(q - p1, axis)) * smoothstep(-feather, 0.0, dot(q - p0, axis));
        float size = v[7] * (1.0 - abs(swing) * v[2] * 0.5);
        weight *= smoothstep(size + feather, size - feather, side);
        weight *= v[10] != 0.0 ? smoothstep(size + feather, size - feather, -side) : step(0.0, side);
        if (u.hasMask != 0) {
            weight *= mask.sample(s, uv).r;
        }
        q.x /= aspect;
        return src.sample(s, mix(uv, q, weight));
    }

    // Travelling waves (values: speed, scale, amplitude, exponent, angle, dual,
    // speed2, scale2, offset2, exponent2, angle2). The direction turns (0, 1) by the
    // angle; the picture moves across it by sin(phase)^exponent × amplitude², scaled
    // by the mask where the pixel is.
    float4 travelingWaves(texture2d<float> src, texture2d<float> mask, texture2d<float> timeOffset, sampler s,
                          float2 uv, constant EffectUniforms &u, constant float *v) {
        float m = u.hasMask != 0 ? mask.sample(s, uv).r : 1.0;
        float delay = u.hasTimeOffset != 0 ? timeOffset.sample(s, uv).r * TAU : 0.0;
        float2 direction = float2(-sin(v[4]), cos(v[4]));
        float phase = u.time * v[0] + dot(uv, direction) * v[1] + delay;
        float wave = sin(phase);
        float shaped = pow(abs(wave), v[3]) * sign(wave);
        if (v[5] != 0.0) {
            float2 direction2 = float2(-sin(v[10]), cos(v[10]));
            float phase2 = (u.time + v[8]) * v[6] + dot(uv, direction2) * v[7] + delay;
            float wave2 = sin(phase2);
            shaped *= pow(abs(wave2), v[9]) * sign(wave2);
        }
        float2 across = float2(direction.y, -direction.x);
        return src.sample(s, uv + shaped * across * v[2] * v[2] * m);
    }

    // Flow shake (values: speed, amplitude, frictionX, frictionY, boundsMin,
    // boundsMax, side, irregular, then the four speeds of the irregular swing). The
    // flow map holds each pixel's vector around 0.498; the mask is read where the
    // moved pixel comes from.
    float4 flowShake(texture2d<float> src, texture2d<float> mask, texture2d<float> flow, texture2d<float> timeOffset,
                     sampler s, float2 uv, constant EffectUniforms &u, constant float *v) {
        float delay = u.hasTimeOffset != 0 ? timeOffset.sample(s, uv).r * TAU : 0.0;
        float2 flowVector = (flow.sample(s, uv).rg - float2(0.498)) * 2.0;
        float2 friction = float2(v[2], v[3]);
        float offset;
        if (v[7] != 0.0) {
            float4 angles = delay + fract(float4(v[8], v[9], v[10], v[11]) * u.time / TAU) * TAU;
            float4 rising = step(0.0, cos(angles));
            float4 sines = sin(angles) * 0.498 + 0.5;
            sines = mix(1.0 - pow(1.0 - sines, float4(friction.x)), pow(sines, float4(friction.y)), rising);
            offset = dot(float4(0.5), sines);
        } else {
            float angle = v[0] * u.time + delay;
            offset = sin(fract(angle / TAU) * TAU) * 0.498 + 0.5;
            offset = mix(1.0 - pow(1.0 - offset, friction.x), pow(offset, friction.y), step(0.0, cos(angle)));
        }
        offset = saturate((offset - v[4]) / (v[5] - v[4]));
        if (v[6] == 0.0) {
            offset = offset * 2.0 - 1.0;
        } else if (v[6] == 2.0) {
            offset -= 1.0;
        }
        float2 moved = offset * v[1] * v[1] * flowVector;
        float4 result = src.sample(s, uv + moved);
        if (u.hasMask != 0) {
            result = mix(src.sample(s, uv), result, mask.sample(s, uv + moved).r);
        }
        return result;
    }

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

    // A moved pixel that would come from outside the painted area keeps its own
    // colour: otherwise the edge of the area smears what is around it inside.
    float4 sampleMoved(texture2d<float> src, texture2d<float> mask, sampler s, float2 suv, float4 original,
                       constant EffectUniforms &u) {
        float4 moved = src.sample(s, suv);
        return u.hasMask != 0 ? mix(original, moved, mask.sample(s, suv).r) : moved;
    }

    // 0 at the fixed side of the area, rising to 1 at the opposite side.
    float edgeWeight(float2 uv, constant EffectUniforms &u) {
        float4 b = u.bounds;
        float t;
        switch (u.fixedEdge) {
        case 1: t = (uv.y - b.y) / max(b.w - b.y, 1e-4); break;
        case 2: t = (b.w - uv.y) / max(b.w - b.y, 1e-4); break;
        case 3: t = (uv.x - b.x) / max(b.z - b.x, 1e-4); break;
        case 4: t = (b.z - uv.x) / max(b.z - b.x, 1e-4); break;
        default: return 1.0;
        }
        return smoothstep(0.0, 1.0, clamp(t, 0.0, 1.0));
    }

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
                                 texture2d<float> timeOffset [[texture(3)]],
                                 texture2d<float> pattern [[texture(4)]],
                                 constant EffectUniforms &u [[buffer(0)]],
                                 constant float4 *pins [[buffer(1)]],
                                 constant float *realTime [[buffer(2)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        constexpr sampler wrap(filter::linear, address::repeat);
        float2 uv = in.uv;
        float m = (u.hasMask != 0 ? mask.sample(s, uv).r : 1.0) * edgeWeight(uv, u);
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
            result = sampleMoved(src, mask, s, toUV(q - d * m, u.aspect), original, u);
            break;
        }
        case 1: { // sway
            float k = mix(2.0, 24.0, u.scale);
            float2 d = dir * (u.strength * 0.02) * sin(w - k * dot(q, dir));
            result = sampleMoved(src, mask, s, toUV(q - d * m, u.aspect), original, u);
            break;
        }
        case 2: { // swing
            float angle = u.strength * 0.35 * sin(w) * m;
            result = sampleMoved(src, mask, s, toUV(rotateAround(q, c, -angle), u.aspect), original, u);
            break;
        }
        case 3: { // waves
            float k = mix(4.0, 60.0, u.scale);
            float2 d = perp * (u.strength * 0.01) * sin(k * dot(q, dir) - w);
            result = sampleMoved(src, mask, s, toUV(q - d * m, u.aspect), original, u);
            break;
        }
        case 4: { // ripple
            float2 v = q - c;
            float r = length(v);
            float k = mix(10.0, 120.0, u.scale);
            float2 d = r > 1e-4 ? (v / r) * (u.strength * 0.01) * sin(k * r - w) : float2(0.0);
            result = sampleMoved(src, mask, s, toUV(q - d * m, u.aspect), original, u);
            break;
        }
        case 5: { // water flow: two samples half a cycle apart hide each one's reset
            float2 f = (flow.sample(s, uv).rg * 2.0 - 1.0) * (u.strength * 0.08) * m;
            float p0 = fract(float(u.cycles) * u.phase);
            float p1 = fract(p0 + 0.5);
            float4 a = sampleMoved(src, mask, s, toUV(q - f * p0, u.aspect), original, u);
            float4 b = sampleMoved(src, mask, s, toUV(q - f * p1, u.aspect), original, u);
            result = mix(a, b, abs(1.0 - 2.0 * p0));
            break;
        }
        case 12: { // drift: the water flow's two offset copies, one direction everywhere
            float2 f = dir * (u.strength * 0.08) * m;
            float p0 = fract(float(u.cycles) * u.phase);
            float p1 = fract(p0 + 0.5);
            float4 a = sampleMoved(src, mask, s, toUV(q - f * p0, u.aspect), original, u);
            float4 b = sampleMoved(src, mask, s, toUV(q - f * p1, u.aspect), original, u);
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
            result = sampleMoved(src, mask, s, toUV(q - d * m, u.aspect), original, u);
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
            result = sampleMoved(src, mask, s, toUV(rotateAround(q, c, -angle), u.aspect), original, u);
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
            result = sampleMoved(src, mask, s, toUV(q - d * m, u.aspect), original, u);
            break;
        }
        case 10: { // pulse
            float dim = u.strength * (0.5 - 0.5 * cos(w));
            result = float4(original.rgb * (1.0 - dim * m), original.a);
            break;
        }
        case 13: // travelling waves
            result = travelingWaves(src, mask, timeOffset, s, uv, u, realTime);
            break;
        case 14: // flow shake
            result = flowShake(src, mask, flow, timeOffset, s, uv, u, realTime);
            break;
        case 15: // flow map
            result = mix(original, flowMap(src, flow, pattern, s, uv, u, realTime), m);
            break;
        case 16: // normal ripples
            result = normalRipples(src, mask, pattern, s, uv, u, realTime);
            break;
        case 17: // noise drift
            result = noiseDrift(src, mask, pattern, s, uv, u, realTime);
            break;
        case 18: // noise sway
            result = noiseSway(src, mask, pattern, s, uv, u, realTime);
            break;
        case 19: // pulse blend
            result = pulseBlend(src, mask, pattern, s, uv, u, realTime);
            break;
        case 20: // uv scroll
            result = mix(original, uvScroll(src, s, uv, u, realTime), m);
            break;
        case 22:
            result = original * clamp(realTime[0], 0.0, 1.0) * mask.sample(s, uv).r;
            break;
        case 21: // axis swing
            result = axisSwing(src, mask, pattern, s, uv, u, realTime);
            break;
        default:
            break;
        }

        if (u.overlay == 1) {
            result = mix(result, float4(1.0, 0.25, 0.3, 1.0), m * 0.45);
        } else if (u.overlay == 2) {
            float strength = length(flow.sample(s, uv).rg * 2.0 - 1.0);
            result = mix(result, float4(0.2, 0.55, 1.0, 1.0), clamp(strength, 0.0, 1.0) * 0.5);
        } else if (u.overlay == 3) {
            result = mix(result, float4(0.75, 0.35, 1.0, 1.0), timeOffset.sample(s, uv).r * 0.5);
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

    // MARK: simulated particles

    struct ParticleSystemInstance {
        float2 center;
        float2 right;
        float2 up;
        float2 uvOrigin;
        float2 uvSize;
        float4 color;
        float depth;
    };

    struct ParticleSystemUniforms {
        float2 column0;
        float2 column1;
        float2 origin;
        float2 viewOrigin;
        float2 viewSize;
        float2 canvasSize;
        float brightness;
        float refractAmount;
        int blend;
        int refracts;
        int hasNormal;
        int cuts;
        float cutoutStart;
        float cutoutEnd;
        float cutoutOpacity;
        float padding;
    };

    struct ParticleSystemOut {
        float4 position [[position]];
        float2 uv;
        float4 color;
        float2 canvasUV;
        // The sprite's right and up on the canvas (x right, y up), normalized:
        // (right.x, up.x, right.y, up.y) times the refraction amount.
        float4 tangents;
    };

    vertex ParticleSystemOut particle_system_vertex(uint vid [[vertex_id]],
                                                    uint iid [[instance_id]],
                                                    const device ParticleSystemInstance *instances [[buffer(0)]],
                                                    constant ParticleSystemUniforms &u [[buffer(1)]]) {
        ParticleSystemInstance p = instances[iid];
        // The sprite's texture coordinates, v down from its top edge.
        float2 corner = float2((vid & 1u) ? 1.0 : 0.0, (vid & 2u) ? 1.0 : 0.0);
        float2 local = p.center + p.right * (corner.x - 0.5) - p.up * (corner.y - 0.5);
        float2 uv = u.origin + u.column0 * local.x + u.column1 * local.y;
        ParticleSystemOut out;
        out.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
        out.uv = p.uvOrigin + corner * p.uvSize;
        out.color = p.color;
        out.canvasUV = uv;
        float2 pixels = float2(u.canvasSize.x, -u.canvasSize.y);
        float2 right = (u.column0 * p.right.x + u.column1 * p.right.y) * pixels;
        float2 up = (u.column0 * p.up.x + u.column1 * p.up.y) * pixels;
        right = length(right) > 0.0 ? normalize(right) : float2(1.0, 0.0);
        up = length(up) > 0.0 ? normalize(up) : float2(0.0, 1.0);
        out.tangents = float4(right.x, up.x, right.y, up.y) * u.refractAmount;
        return out;
    }

    fragment float4 particle_system_fragment(ParticleSystemOut in [[stage_in]],
                                             constant ParticleSystemUniforms &u [[buffer(1)]],
                                             texture2d<float> sprite [[texture(0)]],
                                             texture2d<float> background [[texture(1)]],
                                             texture2d<float> normals [[texture(2)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float4 color = in.color * sprite.sample(s, in.uv);
        if (u.refracts != 0) {
            float2 offset = float2(0.0);
            if (u.hasNormal != 0) {
                float3 n = normals.sample(s, in.uv).rgb;
                float2 normal = n.xy * 2.0 - 1.0;
                offset = (in.tangents.xy * normal.x + in.tangents.zw * normal.y) * n.z * in.color.a;
            }
            // The offset has y up; canvas UV runs down.
            float2 canvasUV = in.canvasUV + float2(offset.x, -offset.y);
            color.rgb *= background.sample(s, (canvasUV - u.viewOrigin) / u.viewSize).rgb;
        }
        float3 rgb = color.rgb * u.brightness;
        if (u.cuts != 0) {
            color.a = smoothstep(u.cutoutStart, u.cutoutEnd, color.a) * u.cutoutOpacity;
        }
        // Opaque particles cover what is below whatever their alpha.
        if (u.blend == 0) { return float4(rgb, 1.0); }
        float alpha = saturate(color.a);
        return float4(rgb * alpha, alpha);
    }
    """
}

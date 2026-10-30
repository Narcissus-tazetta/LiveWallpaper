import Foundation
import simd

struct SceneScript: Codable, Equatable, Identifiable {
    static let apiVersion = 4
    static func supports(version: Int) -> Bool { (1 ... apiVersion).contains(version) }
    static let maximumCount = 32
    var id = UUID()
    var name = "JavaScript"
    var source: String
    var modules: [String: String]?
    var version = Self.apiVersion
    var isEnabled = true
    var usesTime = true
    var usesTimeOfDay = false
    var usesCursor = false
    /// The track playing in Music or Spotify, which needs their automation permission.
    var usesMedia = false
    var layerIDs: [UUID]
    var targetsAllLayers = false
    var params: [String: Double] = ["amount": 0.05, "cycles": 1]
    // Execution permission belongs to this installation, never to a shared document.
    var isAuthorized = false
    var executionRevision = 0

    enum CodingKeys: String, CodingKey {
        case id, name, source, modules, version, isEnabled, usesTime, usesTimeOfDay, usesCursor, usesMedia, layerIDs, targetsAllLayers, params
    }

    init(source: String, layerIDs: [UUID]) {
        self.source = source
        self.layerIDs = layerIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        source = try c.decode(String.self, forKey: .source)
        modules = try c.decodeIfPresent([String: String].self, forKey: .modules)
        version = try c.decode(Int.self, forKey: .version)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        usesTime = try c.decode(Bool.self, forKey: .usesTime)
        usesTimeOfDay = try c.decode(Bool.self, forKey: .usesTimeOfDay)
        usesCursor = try c.decode(Bool.self, forKey: .usesCursor)
        usesMedia = try c.decodeIfPresent(Bool.self, forKey: .usesMedia) ?? false
        layerIDs = try c.decode([UUID].self, forKey: .layerIDs)
        targetsAllLayers = try c.decodeIfPresent(Bool.self, forKey: .targetsAllLayers) ?? false
        params = try c.decode([String: Double].self, forKey: .params)
        guard (modules?.count ?? 0) <= 2048,
              (modules?.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count } ?? 0) <= 4194304,
              modules?.allSatisfy({ !$0.key.contains("\0") && !$0.value.contains("\0") }) != false,
              source.utf8.count <= 65536, layerIDs.count <= 512, params.count <= 64,
              params.allSatisfy({ $0.key.utf8.count <= 128 && $0.value.isFinite })
        else {
            throw DecodingError.dataCorruptedError(forKey: .source, in: c, debugDescription: "Script input exceeds supported limits")
        }
    }

    var canRun: Bool { isEnabled && isAuthorized && Self.supports(version: version) }

    var requiresLiveInteraction: Bool {
        guard canRun else { return false }
        guard usesCursor || usesMedia || usesTimeOfDay else { return false }
        guard let modules, !modules.isEmpty else { return true }
        let needsCursor = usesCursor && (userCode.contains("cursor") || userCode.contains("pointer") || userCode.contains("mouse"))
        let needsMedia = usesMedia && (userCode.contains("media") || userCode.contains("mediaThumbnail"))
        let needsClock = usesTimeOfDay && userCode.contains("wallClock")
        return needsCursor || needsMedia || needsClock
    }

    /// Registers audio buffers, so it reads the system audio every frame.
    var usesAudio: Bool { canRun && userCode.contains("registerAudioBuffers") }

    /// The script and its modules without the imported runtime bridge, which declares
    /// cursor, media and audio stubs even when the scene's own code uses none of them.
    private var userCode: String {
        let runtimeModules: Set<String> = [
            "scene-bridge", "scene-types", "scene-config", "WEColor", "WEMath", "WEVector"
        ]
        return source + "\n" + (modules ?? [:]).filter { !runtimeModules.contains($0.key) }.values.joined(separator: "\n")
    }

    func targetLayerIDs(in layers: [SceneLayer]) -> [UUID] {
        targetsAllLayers ? layers.map(\.id) : layerIDs
    }
}

struct SceneScriptIssue: Error, LocalizedError, Equatable {
    var scriptID: UUID
    var name: String
    var message: String
    /// Ran out of time, which depends on the machine's load as much as on the script:
    /// live drawing tries it again after a pause.
    var isTemporary = false
    /// Only a part of the script failed; the rest keeps running.
    var isPartial = false
    var errorDescription: String? { "\(name): \(message)" }
}

struct SceneScriptOutput {
    var adjustments: [UUID: SceneScriptAdjustment]
    /// Parts of the script that failed while the rest kept running.
    var warnings: [String]
    var meshes: [SceneMeshFrame] = []
    var models: [SceneModelLayerFrame] = []
    var camera: SceneCameraState?
    var instances: [SceneScriptInstance] = []
    var sounds: [UUID: SceneScriptedSound] = [:]
    var lights: [SceneLightState] = []
}

/// A scripted light as the scripts left it this frame.
struct SceneLightState: Equatable {
    /// The scene object, as `SceneDynamicLight.objectID`.
    var objectID: Int
    var origin: SIMD3<Float>
    var axis: SIMD3<Float>
    /// The colour times the intensity; black while the light is hidden.
    var color: SIMD3<Float>
}

/// A layer a script made from one of the scene's: drawn like `template`, adjusted on
/// its own.
struct SceneScriptInstance {
    var id: UUID
    var template: UUID
    var adjustment: SceneScriptAdjustment
}

/// The camera as scripts left it this frame.
struct SceneCameraState: Equatable {
    var eye: SIMD3<Float>
    var center: SIMD3<Float>
    var up: SIMD3<Float>
    var zoom: Float
    /// Vertical, in degrees.
    var fov: Float
    var nearZ: Float
    var farZ: Float
    /// A script moved the camera; otherwise its place is the scene's own, which a path may move.
    var isPlacedByScript = true
}

struct SceneScriptAdjustment {
    var rigPlayback: [UUID: [Int: SceneScriptPlaybackValues]] = [:]
    var order: Int?
    var values = SceneLinkValues.identity
    var appearance: SceneScriptAppearanceValues?
    var effects: [UUID: SceneScriptEffectValues] = [:]
    var particles: SceneScriptParticleValues?
    var particleControl: SceneParticleSimulator.Control?
    var text: SceneScriptTextValues?
    /// In a scene seen through its camera: the layer's placement now (column-major).
    var world: simd_float4x4?
    var modelValues: [String: Double]?
}

struct SceneScriptEffectValues: Decodable {
    var kind: SceneEffectKind?
    var fixedEdge: SceneFixedEdge?
    var isEnabled: Bool?
    var strength: Double?
    var scale: Double?
    var direction: Double?
    var cycles: Int?
    var centerX: Double?
    var centerY: Double?
    var reversed: Bool?
    var values: [String: Double]?

    func apply(to effect: inout SceneEffect) {
        if let kind { effect.kind = kind }
        if let fixedEdge { effect.fixedEdge = fixedEdge }
        if let isEnabled { effect.isEnabled = isEnabled }
        if let strength { effect.strength = strength }
        if let scale { effect.scale = scale }
        if let direction { effect.direction = direction }
        if let cycles { effect.cycles = cycles }
        if let centerX { effect.centerX = centerX }
        if let centerY { effect.centerY = centerY }
        if let reversed { effect.reversed = reversed }
        if let values {
            for (key, value) in values { effect.values[key] = value }
        }
    }
}

struct SceneScriptParticleValues: Decodable {
    var preset: SceneParticlePreset?
    var cursorMode: SceneParticleCursorMode?
    var seed: Int?
    var count: Int?
    var size: Double?
    var cycles: Int?
    var direction: Double?
    var sway: Double?
    var opacity: Double?
    var color: RGBAColor?

    func apply(to particles: inout SceneParticles) {
        if let preset { particles.preset = preset }
        if let cursorMode { particles.cursorMode = cursorMode }
        if let seed { particles.seed = seed }
        if let count { particles.count = count }
        if let size { particles.size = size }
        if let cycles { particles.cycles = cycles }
        if let direction { particles.direction = direction }
        if let sway { particles.sway = sway }
        if let opacity { particles.opacity = opacity }
        if let color { particles.color = color }
    }
}

struct SceneScriptAppearanceValues: Decodable {
    var isVisible: Bool?
    var tint: RGBAColor?
    var blendMode: SceneBlendMode?
    var parallaxDepth: Double?
    var depthStrength: Double?
    var depthFollowsCursor: Bool?
    var depthAutoMotion: Double?
    var depthAutoCycles: Int?
    var clearCursorMask: Bool?
    var cursorMask: SceneScriptCursorMaskValues?

    func apply(to layer: inout SceneLayer) {
        if let isVisible { layer.isVisible = isVisible }
        if let tint { layer.tint = tint }
        if let blendMode { layer.blendMode = blendMode }
        if let parallaxDepth { layer.parallaxDepth = parallaxDepth }
        if let depthStrength { layer.depthStrength = depthStrength }
        if let depthFollowsCursor { layer.depthFollowsCursor = depthFollowsCursor }
        if let depthAutoMotion { layer.depthAutoMotion = depthAutoMotion }
        if let depthAutoCycles { layer.depthAutoCycles = depthAutoCycles }
        if clearCursorMask == true { layer.cursorMask = nil }
        if let cursorMask {
            var mask = layer.cursorMask ?? SceneCursorMask()
            if let mode = cursorMask.mode { mask.mode = mode }
            if let radius = cursorMask.radius { mask.radius = radius }
            if let softness = cursorMask.softness { mask.softness = softness }
            layer.cursorMask = mask
        }
    }
}

struct SceneScriptTextValues: Decodable {
    struct Color: Decodable {
        var red: Double
        var green: Double
        var blue: Double
    }

    var string: String?
    var color: Color?

    func apply(to text: inout SceneText) {
        if let string { text.string = string }
        if let color { text.color = RGBAColor(red: color.red, green: color.green, blue: color.blue, alpha: text.color.alpha) }
    }
}

struct SceneScriptCursorMaskValues: Decodable {
    var mode: SceneCursorMaskMode?
    var radius: Double?
    var softness: Double?
}

struct SceneScriptPlaybackValues: Decodable {
    var frame: Double?
    var rate: Double?
    var weight: Float?

    func apply(to playback: inout SceneSkeleton.Playback) {
        if let frame {
            playback.startFrame = frame
            playback.rate = 0
        } else if let rate { playback.rate = rate }
        if let weight { playback.weight = weight }
    }
}

extension SceneLayer {
    var scriptRigIDs: Set<UUID> {
        Set((placement?.steps.compactMap(\.skeletonID) ?? []) + (renderGraph?.passes.compactMap { $0.draw?.skeletonID } ?? [])
            + (model?.skeleton.map { [$0] } ?? []))
    }
}

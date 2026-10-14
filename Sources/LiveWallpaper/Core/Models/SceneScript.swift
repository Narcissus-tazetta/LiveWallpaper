import Foundation

struct SceneScript: Codable, Equatable, Identifiable {
    static let apiVersion = 3
    static func supports(version: Int) -> Bool { (1 ... apiVersion).contains(version) }
    static let maximumCount = 32
    var id = UUID()
    var name = "JavaScript"
    var source: String
    var version = Self.apiVersion
    var isEnabled = true
    var usesTime = true
    var usesTimeOfDay = false
    var usesCursor = false
    var layerIDs: [UUID]
    var targetsAllLayers = false
    var params: [String: Double] = ["amount": 0.05, "cycles": 1]
    // Execution permission belongs to this installation, never to a shared document.
    var isAuthorized = false
    var executionRevision = 0

    enum CodingKeys: String, CodingKey {
        case id, name, source, version, isEnabled, usesTime, usesTimeOfDay, usesCursor, layerIDs, targetsAllLayers, params
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
        version = try c.decode(Int.self, forKey: .version)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        usesTime = try c.decode(Bool.self, forKey: .usesTime)
        usesTimeOfDay = try c.decode(Bool.self, forKey: .usesTimeOfDay)
        usesCursor = try c.decode(Bool.self, forKey: .usesCursor)
        layerIDs = try c.decode([UUID].self, forKey: .layerIDs)
        targetsAllLayers = try c.decodeIfPresent(Bool.self, forKey: .targetsAllLayers) ?? false
        params = try c.decode([String: Double].self, forKey: .params)
        guard source.utf8.count <= 65536, layerIDs.count <= 128, params.count <= 64,
              params.allSatisfy({ $0.key.utf8.count <= 128 && $0.value.isFinite })
        else {
            throw DecodingError.dataCorruptedError(forKey: .source, in: c, debugDescription: "Script input exceeds supported limits")
        }
    }

    var canRun: Bool { isEnabled && isAuthorized && Self.supports(version: version) }

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
    var errorDescription: String? { "\(name): \(message)" }
}

struct SceneScriptAdjustment {
    var values = SceneLinkValues.identity
    var appearance: SceneScriptAppearanceValues?
    var effects: [UUID: SceneScriptEffectValues] = [:]
    var particles: SceneScriptParticleValues?
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

struct SceneScriptCursorMaskValues: Decodable {
    var mode: SceneCursorMaskMode?
    var radius: Double?
    var softness: Double?
}

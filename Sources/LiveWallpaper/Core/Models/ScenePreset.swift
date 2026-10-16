import Foundation

/// A finished look applied to an image layer in one step: it replaces the layer's
/// motion (effects, depth motion, cursor settings) and adds particle layers above it.
/// Placement, keyframes, opacity and blend stay the layer's own.
///
/// Everything positional is in layer UV (effect centres, pins, painted files), so a
/// preset made on one picture lands on the same relative spots of any other picture,
/// whatever its size or shape. Particles are in canvas terms and carry over as they are.
struct ScenePreset: Codable, Equatable, Identifiable {
    enum BuiltIn: String, Codable, CaseIterable {
        case depthFireflies
        case hairSway
        case waterSurface
        case driftingClouds
        case cherryBlossoms
        case fallingSnow
    }

    var id = UUID()
    var name: String
    /// Built-in presets are defined in code; only the user's are stored.
    var builtIn: BuiltIn?
    var effects: [ScenePresetEffect]
    var parallaxDepth: Double = 0
    var cursorMask: SceneCursorMask?
    /// The look needs a depth map, which is made per picture (AI), so it is never
    /// stored; applying it asks for one instead.
    var wantsDepth = false
    var depthStrength = 0.5
    var depthFollowsCursor = true
    var depthAutoMotion: Double = 0
    var depthAutoCycles = 1
    /// Particle layers, bottom to top, put right above the layer.
    var particleLayers: [SceneLayer] = []
    /// Painted masks, flow maps and pins came along (user presets only).
    var includesPaint = false

    init(name: String, builtIn: BuiltIn? = nil, effects: [ScenePresetEffect]) {
        self.name = name
        self.builtIn = builtIn
        self.effects = effects
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        builtIn = try? container.decodeIfPresent(BuiltIn.self, forKey: .builtIn)
        effects = ((try? container.decode([FailableDecodable<ScenePresetEffect>].self, forKey: .effects)) ?? [])
            .compactMap(\.value)
        parallaxDepth = (try? container.decode(Double.self, forKey: .parallaxDepth)) ?? 0
        cursorMask = try? container.decodeIfPresent(SceneCursorMask.self, forKey: .cursorMask)
        wantsDepth = (try? container.decode(Bool.self, forKey: .wantsDepth)) ?? false
        depthStrength = (try? container.decode(Double.self, forKey: .depthStrength)) ?? 0.5
        depthFollowsCursor = (try? container.decode(Bool.self, forKey: .depthFollowsCursor)) ?? true
        depthAutoMotion = (try? container.decode(Double.self, forKey: .depthAutoMotion)) ?? 0
        depthAutoCycles = (try? container.decode(Int.self, forKey: .depthAutoCycles)) ?? 1
        particleLayers = ((try? container.decode([FailableDecodable<SceneLayer>].self, forKey: .particleLayers)) ?? [])
            .compactMap(\.value)
            .filter { $0.kind == .particles && $0.particles != nil }
        includesPaint = (try? container.decode(Bool.self, forKey: .includesPaint)) ?? false
    }

    /// Files a stored preset keeps next to its preset.json.
    var referencedFiles: Set<String> {
        var files = Set<String>()
        for item in effects {
            files.formUnion([item.effect.maskFile, item.effect.flowFile].compactMap { $0 })
        }
        for layer in particleLayers {
            if let maskFile = layer.particles?.maskFile {
                files.insert(maskFile)
            }
        }
        return files
    }
}

struct ScenePresetEffect: Codable, Equatable {
    var effect: SceneEffect
    /// The effect is meant for part of the picture; until a mask is painted it moves
    /// the whole layer, and the guide asks for one.
    var wantsMask: Bool
    /// Once painted, the area should move as a layer of its own (hair, leaves): an
    /// effect bending the area in place keeps its outline still.
    var movesToOwnLayer = false

    init(_ effect: SceneEffect, wantsMask: Bool, movesToOwnLayer: Bool = false) {
        self.effect = effect
        self.wantsMask = wantsMask
        self.movesToOwnLayer = movesToOwnLayer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        effect = try container.decode(SceneEffect.self, forKey: .effect)
        wantsMask = (try? container.decode(Bool.self, forKey: .wantsMask)) ?? false
        movesToOwnLayer = (try? container.decode(Bool.self, forKey: .movesToOwnLayer)) ?? false
    }
}

/// What is left to do after applying a preset, worked out from the scene each time
/// so a step ticks itself off however it gets done (or undone).
enum ScenePresetStep: Equatable, Identifiable {
    case paintMask(effectID: UUID, kind: SceneEffectKind)
    case moveToOwnLayer(effectID: UUID)
    case drawFlow(effectID: UUID)
    case addPins(effectID: UUID)
    case estimateDepth

    var id: String {
        switch self {
        case let .paintMask(effectID, _): "mask-\(effectID)"
        case let .moveToOwnLayer(effectID): "layer-\(effectID)"
        case let .drawFlow(effectID): "flow-\(effectID)"
        case let .addPins(effectID): "pins-\(effectID)"
        case .estimateDepth: "depth"
        }
    }
}

/// The steps a preset left on one layer.
struct ScenePresetGuide: Equatable {
    var presetName: String
    var layerID: UUID
    var steps: [ScenePresetStep]
    /// The effects and layers the preset added; once undo has removed them all, the
    /// guide no longer applies.
    var addedIDs: Set<UUID> = []

    func isActive(in document: SceneDocument) -> Bool {
        guard document.layers.contains(where: { $0.id == layerID }) else {
            return false
        }
        return addedIDs.isEmpty || document.layers.contains { layer in
            addedIDs.contains(layer.id) || layer.effects.contains { addedIDs.contains($0.id) }
        }
    }

    /// The steps still about something in the scene.
    func visibleSteps(in document: SceneDocument) -> [ScenePresetStep] {
        steps.filter { isDone($0, in: document) != nil }
    }

    /// nil when the layer or the step's effect is gone. An effect may have moved to a
    /// layer of its own since (moveScenePaintedAreaToOwnLayer).
    func isDone(_ step: ScenePresetStep, in document: SceneDocument) -> Bool? {
        guard let layer = document.layers.first(where: { $0.id == layerID }) else {
            return nil
        }
        func find(_ effectID: UUID) -> (effect: SceneEffect, movedOff: Bool)? {
            for candidate in document.layers {
                if let effect = candidate.effects.first(where: { $0.id == effectID }) {
                    return (effect, candidate.id != layerID)
                }
            }
            return nil
        }
        switch step {
        case let .paintMask(effectID, _):
            // A moved area was painted first; its mask became the layer's outline.
            return find(effectID).map { $0.movedOff || $0.effect.maskFile != nil }
        case let .moveToOwnLayer(effectID):
            return find(effectID).map(\.movedOff)
        case let .drawFlow(effectID):
            return find(effectID).map { $0.effect.flowFile != nil }
        case let .addPins(effectID):
            return find(effectID).map { !$0.effect.pins.isEmpty }
        case .estimateDepth:
            return layer.depthFile != nil
        }
    }
}

extension ScenePreset {
    /// The scene with the preset applied to the image layer `layerID`, and the steps
    /// it leaves. `fileNames` maps the preset's stored files to their names in the
    /// scene folder (files missing from it are dropped). nil when the layer is not an
    /// image layer.
    func applied(
        to document: SceneDocument,
        layerID: UUID,
        fileNames: [String: String] = [:]
    ) -> (document: SceneDocument, guide: ScenePresetGuide)? {
        guard let index = document.layers.firstIndex(where: { $0.id == layerID }),
              document.layers[index].kind == .image
        else {
            return nil
        }
        var document = document
        var layer = document.layers[index]
        var steps: [ScenePresetStep] = []

        layer.effects = effects.map { item in
            var effect = item.effect
            // Fresh ids: the same preset can be applied to several layers, and the
            // editor finds effects and pins by id.
            effect.id = UUID()
            effect.pins = effect.pins.map { pin in
                var copy = pin
                copy.id = UUID()
                return copy
            }
            effect.maskFile = effect.maskFile.flatMap { fileNames[$0] }
            effect.flowFile = effect.flowFile.flatMap { fileNames[$0] }
            if item.wantsMask, effect.maskFile == nil {
                steps.append(.paintMask(effectID: effect.id, kind: effect.kind))
            }
            if item.movesToOwnLayer {
                steps.append(.moveToOwnLayer(effectID: effect.id))
            }
            if effect.kind == .waterFlow, effect.flowFile == nil {
                steps.append(.drawFlow(effectID: effect.id))
            }
            if effect.kind == .puppet, effect.pins.isEmpty {
                steps.append(.addPins(effectID: effect.id))
            }
            return effect
        }
        layer.parallaxDepth = parallaxDepth
        layer.cursorMask = cursorMask
        layer.depthStrength = depthStrength
        layer.depthFollowsCursor = depthFollowsCursor
        layer.depthAutoMotion = depthAutoMotion
        layer.depthAutoCycles = depthAutoCycles
        if wantsDepth, layer.depthFile == nil {
            steps.append(.estimateDepth)
        }
        document.layers[index] = layer

        let added = particleLayers.map { template in
            var copy = template.duplicated(name: template.name)
            copy.particles?.maskFile = template.particles?.maskFile.flatMap { fileNames[$0] }
            return copy
        }
        document.layers.insert(contentsOf: added, at: index + 1)
        let addedIDs = Set(layer.effects.map(\.id) + added.map(\.id))
        return (document, ScenePresetGuide(presetName: name, layerID: layerID, steps: steps, addedIDs: addedIDs))
    }

    /// A preset of the layer's current look. Without `includingPaint`, painted files
    /// and pins are left out and become steps when the preset is applied.
    static func capture(
        name: String,
        layer: SceneLayer,
        particleLayers: [SceneLayer],
        includingPaint: Bool
    ) -> ScenePreset {
        var preset = ScenePreset(
            name: name,
            effects: layer.effects.map { effect in
                var effect = effect
                let wantsMask = effect.maskFile != nil
                if !includingPaint {
                    effect.maskFile = nil
                    effect.flowFile = nil
                    effect.pins = []
                }
                return ScenePresetEffect(effect, wantsMask: wantsMask)
            }
        )
        preset.parallaxDepth = layer.parallaxDepth
        preset.cursorMask = layer.cursorMask
        preset.wantsDepth = layer.depthFile != nil
        preset.depthStrength = layer.depthStrength
        preset.depthFollowsCursor = layer.depthFollowsCursor
        preset.depthAutoMotion = layer.depthAutoMotion
        preset.depthAutoCycles = layer.depthAutoCycles
        preset.particleLayers = particleLayers.filter { $0.kind == .particles }.map { layer in
            var copy = layer
            copy.isLocked = false
            if !includingPaint {
                copy.particles?.maskFile = nil
            }
            return copy
        }
        preset.includesPaint = includingPaint
        return preset
    }
}

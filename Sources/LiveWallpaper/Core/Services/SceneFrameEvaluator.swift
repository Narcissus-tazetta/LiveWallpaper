import Foundation
import simd

struct SceneEvaluatedFrame {
    /// Layers scripts made from the scene's own, each to its template; they are in
    /// `layers` and `order` under their own IDs.
    var instances: [UUID: UUID] = [:]
    struct Layer {
        var layer: SceneLayer
        var transform: SceneTransform
        var opacity: Double
        var color: SceneLinkValues
        /// In a scene seen through its camera: where scripts placed the layer, when they did.
        var world: simd_float4x4?
    }
    var input: SceneFrameInput
    var layers: [UUID: Layer]
    var issues: [SceneScriptIssue]
    var logs: [UUID: String]
    var rigPlayback: [UUID: [SceneSkeleton.Playback]] = [:]
    var order: [UUID: Int] = [:]
    var meshes: [SceneMeshFrame] = []
    var models: [SceneModelLayerFrame] = []
    var sounds: [UUID: SceneScriptedSound] = [:]
    var camera: SceneCameraState?
    /// What scripts asked of simulated particles this frame; carried out once, when drawn.
    var particleControls: [UUID: SceneParticleSimulator.Control] = [:]
    /// The lights scripts move, by scene object.
    var lights: [Int: SceneLightState] = [:]
}

final class SceneFrameEvaluator {
    /// Wall time for one script and for all scripts of one frame.
    struct Budget {
        var perScript: TimeInterval
        var perFrame: TimeInterval

        /// Drawing on screen has to keep its frame rate.
        static let live = Budget(perScript: 0.008, perFrame: 0.016)
        /// A bake has no deadline, and a frame that ran out of time fails the whole
        /// video, so this only has to stop code that never ends.
        static let offline = Budget(perScript: 0.25, perFrame: 1)
    }

    private let budget: Budget
    /// Seconds before a script that ran out of time runs again.
    private let temporaryStopSeconds: TimeInterval
    private let runtime = SceneScriptRuntime()
    private var stopped: [UUID: SceneScriptIssue] = [:]
    private var resumeTimes: [UUID: TimeInterval] = [:]
    private var previousScripts: [SceneScript] = []
    /// What each script last returned, shown again for a frame it ran out of time in.
    private var lastOutputs: [UUID: SceneScriptOutput] = [:]
    private var consecutiveTimeouts: [UUID: Int] = [:]
    /// How many times its normal time a module bundle gets: one that runs out of time
    /// is given more on the next frame, up to `maximumTimeScale`, so a heavy scene runs
    /// at a lower frame rate instead of never finishing a frame.
    private var timeScales: [UUID: Double] = [:]
    private static let maximumTimeScale = 16.0
    /// Read for every frame, and scanning a large bundle's code for it takes as long as running it.
    private var audioScripts: Set<UUID> = []
    /// A script that keeps running out of time is slower than the frame rate allows;
    /// after this many frames in a row it is stopped, as one that cannot run at all.
    private static let maximumHeldFrames = 30
    private var clockOrigin: Date?
    private struct LayerTemplate {
        /// The target's fields that only change with the document, as object members.
        var base: SceneScriptInput
        var baseCount: Int
        /// Why the fields cannot be given to a script (a value JSON cannot hold).
        var invalid: Error?
        var layerOpacity: Double
    }
    private var cachedLayers: [SceneLayer] = []
    private var cachedRigs: [UUID: SceneSkeleton] = [:]
    private var cachedTemplates: [UUID: LayerTemplate] = [:]
    private var cachedScriptTargets: [UUID: [SceneLayer]] = [:]

    /// Where scripts' localStorage goes; by default nowhere that outlives this evaluator.
    var storage: SceneScriptStorage.Session

    init(budget: Budget = .live, temporaryStopSeconds: TimeInterval = 2, storage: SceneScriptStorage.Session = .scratch()) {
        self.budget = budget
        self.temporaryStopSeconds = temporaryStopSeconds
        self.storage = storage
    }

    private static func apply(_ adjustment: SceneScriptAdjustment, to layer: inout SceneEvaluatedFrame.Layer) {
        layer.transform.offsetX += adjustment.values.offsetX
        layer.transform.offsetY += adjustment.values.offsetY
        layer.transform.rotation += adjustment.values.rotation
        if layer.transform.scaleY != nil || adjustment.values.scaleY != nil {
            layer.transform.scaleY = (layer.transform.scaleY ?? layer.transform.scale) * (adjustment.values.scaleY ?? adjustment.values.scale)
        }
        layer.transform.scale *= adjustment.values.scale
        layer.opacity *= adjustment.values.opacity
        layer.color = layer.color.combined(with: adjustment.values)
        adjustment.appearance?.apply(to: &layer.layer)
        for index in layer.layer.effects.indices {
            adjustment.effects[layer.layer.effects[index].id]?.apply(to: &layer.layer.effects[index])
        }
        if let text = adjustment.text { text.apply(to: &layer.layer.text!) }
        if let world = adjustment.world { layer.world = world }
        if let modelValues = adjustment.modelValues { layer.layer.modelValues = modelValues }
    }

    func evaluate(_ document: SceneDocument, input: SceneFrameInput, timeOfDay: SceneTimeOfDay, failOnError: Bool = true) throws -> SceneEvaluatedFrame {
        if previousScripts != document.scripts {
            stopped = [:]
            resumeTimes = [:]
            lastOutputs = [:]
            consecutiveTimeouts = [:]
            timeScales = [:]
            audioScripts = Set(document.scripts.filter(\.usesAudio).map(\.id))
            cachedScriptTargets.removeAll(keepingCapacity: true)
            previousScripts = document.scripts
            runtime.retainPrograms(for: Set(document.scripts.map(\.id)))
        }
        updateCacheIfNeeded(document: document)
        let now = ProcessInfo.processInfo.systemUptime
        for (id, issue) in stopped where issue.isTemporary && now >= resumeTimes[id] ?? 0 {
            stopped[id] = nil
            resumeTimes[id] = nil
        }
        for script in document.scripts where script.canRun && stopped[script.id] == nil {
            do { try runtime.prepare(script) } catch let issue as SceneScriptIssue {
                stop(issue)
                if failOnError { throw issue }
            }
        }
        let allowance = document.scripts.reduce(0) { $0 + budget.perScript * (timeScales[$1.id] ?? 1) }
        let deadline = ProcessInfo.processInfo.systemUptime + max(budget.perFrame, allowance)
        let phase = (input.time / Double(document.loopSeconds)).truncatingRemainder(dividingBy: 1)
        let normalizedPhase = phase < 0 ? phase + 1 : phase
        var base: [UUID: SceneEvaluatedFrame.Layer] = [:]
        for layer in document.layers {
            let pose = layer.pose(at: normalizedPhase, time: input.time)
            let link = document.linkValues(layerID: layer.id, timeOfDay: timeOfDay,
                                           cursor: SIMD2(Double(input.parallax.x), Double(input.parallax.y)))
            var transform = pose.transform
            transform.offsetX += link.offsetX
            transform.offsetY += link.offsetY
            transform.rotation += link.rotation
            if transform.scaleY != nil || link.scaleY != nil {
                transform.scaleY = (transform.scaleY ?? transform.scale) * (link.scaleY ?? link.scale)
            }
            transform.scale *= link.scale
            base[layer.id] = .init(layer: layer, transform: transform, opacity: pose.opacity * link.opacity, color: link)
        }
        var rigPlayback: [UUID: [SceneSkeleton.Playback]] = [:]
        var order: [UUID: Int] = [:]
        var result = base
        var targetInputs: [UUID: SceneScriptInput] = [:]
        var warnings: [SceneScriptIssue] = []
        var meshes: [SceneMeshFrame] = []
        var models: [SceneModelLayerFrame] = []
        var sounds: [UUID: SceneScriptedSound] = [:]
        var camera: SceneCameraState?
        var instances: [UUID: UUID] = [:]
        var particleControls: [UUID: SceneParticleSimulator.Control] = [:]
        var lights: [Int: SceneLightState] = [:]
        // A converted bundle runs even with no layer of its own to drive: it may draw
        // what it makes.
        for script in document.scripts where script.canRun
            && (script.modules != nil || !script.targetLayerIDs(in: document.layers).isEmpty) {
            if let issue = stopped[script.id] {
                if failOnError { throw issue }
                continue
            }
            do {
                let scriptLayers = try targetLayers(for: script, in: document.layers)
                var context = SceneScriptInput()
                let contextPosition = context.beginObject()
                var contextCount = 0
                func member(_ name: String) {
                    context.key(name)
                    contextCount += 1
                }
                member("targets")
                let targetsPosition = context.beginArray()
                for layer in scriptLayers {
                    if let cached = targetInputs[layer.id] {
                        context.append(cached)
                        continue
                    }
                    let evaluated = base[layer.id]!
                    let template = cachedTemplates[layer.id]!
                    if let invalid = template.invalid { throw invalid }
                    var value = SceneScriptInput()
                    let position = value.beginObject()
                    value.append(template.base)
                    value.key("transform")
                    try Self.transformInput(evaluated.transform, into: &value)
                    value.key("opacity")
                    try value.number(template.layerOpacity * evaluated.opacity)
                    value.key("values")
                    try Self.linkValuesInput(evaluated.color, into: &value)
                    value.end(position, count: template.baseCount + 3)
                    targetInputs[layer.id] = value
                    context.append(value)
                }
                context.end(targetsPosition, count: scriptLayers.count)
                member("params")
                try context.value(script.params)
                member("loopSeconds")
                try context.number(Double(document.loopSeconds))
                member("canvas")
                let canvasPosition = context.beginObject()
                context.key("width")
                try context.number(Double(document.canvasWidth))
                context.key("height")
                try context.number(Double(document.canvasHeight))
                context.key("aspectRatio")
                try context.number(document.aspectRatio)
                context.end(canvasPosition, count: 3)
                member("screen")
                if let screen = input.screenSize {
                    let screenPosition = context.beginObject()
                    context.key("width")
                    try context.number(Double(screen.x))
                    context.key("height")
                    try context.number(Double(screen.y))
                    context.end(screenPosition, count: 2)
                } else { context.null() }
                var missing: [String] = []
                if script.usesTime {
                    member("elapsedTime")
                    try context.number(input.time)
                    member("time")
                    try context.number(normalizedPhase * Double(document.loopSeconds))
                    member("phase")
                    try context.number(normalizedPhase)
                } else { missing += ["time", "phase", "elapsedTime"] }
                if script.usesTimeOfDay {
                    member("timeOfDay")
                    context.string(timeOfDay.rawValue)
                    let now = clock(input)
                    member("wallClock")
                    let position = context.beginObject()
                    context.key("epochMilliseconds")
                    try context.number((now.timeIntervalSince1970 * 1000).rounded())
                    context.key("timeZoneOffsetMinutes")
                    try context.number(Double(TimeZone.current.secondsFromGMT(for: now) / 60))
                    context.end(position, count: 2)
                } else { missing += ["timeOfDay", "wallClock"] }
                if script.usesCursor {
                    member("cursor")
                    try Self.pointInput(input.parallax, into: &context)
                    member("cursorActive")
                    context.bool(input.cursor != nil)
                    member("pointer")
                    if let cursor = input.cursor { try Self.pointInput(cursor, into: &context) } else { context.null() }
                    member("pointerPresses")
                    let pressesPosition = context.beginArray()
                    for press in input.pointerPresses {
                        let position = context.beginObject()
                        context.key("isDown")
                        context.bool(press.isDown)
                        context.key("x")
                        try context.number(press.position.x)
                        context.key("y")
                        try context.number(press.position.y)
                        context.end(position, count: 3)
                    }
                    context.end(pressesPosition, count: input.pointerPresses.count)
                } else { missing += ["cursor", "cursorActive", "pointer", "pointerPresses"] }
                if script.usesMedia {
                    member("media")
                    try context.value(Self.mediaInput(input.media))
                } else { missing.append("media") }
                if audioScripts.contains(script.id) {
                    member("audio")
                    if let audio = input.audio {
                        let position = context.beginObject()
                        for (name, values) in [("left", audio.left), ("right", audio.right)] {
                            context.key(name)
                            let array = context.beginArray()
                            for value in values { try context.number(value) }
                            context.end(array, count: values.count)
                        }
                        context.end(position, count: 2)
                    } else { context.null() }
                } else { missing.append("audio") }
                if let userProps = Self.userProperties(document, input: input) {
                    member("userProperties")
                    let position = context.beginObject()
                    for (k, v) in userProps.sorted(by: { $0.key < $1.key }) {
                        context.key(k)
                        switch v {
                        case let .bool(b): context.bool(b)
                        case let .number(n): try context.number(n)
                        case let .string(s): context.string(s)
                        case .null: context.null()
                        }
                    }
                    context.end(position, count: userProps.count)
                }
                member("_missing")
                try context.value(missing)
                context.end(contextPosition, count: contextCount)
                let output: SceneScriptOutput
                // A held frame repeats the last output, whose particle requests were already carried out.
                var heldOutput = false
                let scale = timeScales[script.id] ?? 1
                let started = ProcessInfo.processInfo.systemUptime
                do {
                    output = try runtime.evaluate(
                        script, input: context, elapsedTime: input.time, layers: document.layers, rigs: document.rigs, storage: storage,
                        perScript: budget.perScript * scale, deadline: deadline
                    )
                    if scale > 1, ProcessInfo.processInfo.systemUptime - started < budget.perScript * scale / 4 {
                        timeScales[script.id] = max(scale / 2, 1)
                    }
                    consecutiveTimeouts[script.id] = nil
                    lastOutputs[script.id] = output
                } catch let issue as SceneScriptIssue where !failOnError && issue.isTemporary && runtime.isLoaded(script.id) {
                    // A slow frame (other work took the CPU) is skipped: the script keeps its
                    // state, so its animations carry on instead of restarting.
                    if script.modules != nil { timeScales[script.id] = min(scale * 2, Self.maximumTimeScale) }
                    let count = (consecutiveTimeouts[script.id] ?? 0) + 1
                    guard count <= Self.maximumHeldFrames else { throw issue }
                    consecutiveTimeouts[script.id] = count
                    guard let held = lastOutputs[script.id] else { continue }
                    output = held
                    heldOutput = true
                }
                warnings += output.warnings.map {
                    SceneScriptIssue(scriptID: script.id, name: script.name, message: $0, isPartial: true)
                }
                meshes += output.meshes
                models += output.models
                sounds.merge(output.sounds) { _, new in new }
                camera = output.camera ?? camera
                for light in output.lights { lights[light.objectID] = light }
                for (id, adjustment) in output.adjustments {
                    if let position = adjustment.order { order[id] = position }
                    for (rigID, changes) in adjustment.rigPlayback {
                        var playback = rigPlayback[rigID] ?? document.rigs[rigID]!.playback
                        for (index, change) in changes { change.apply(to: &playback[index]) }
                        rigPlayback[rigID] = playback
                    }
                    var layer = result[id]!
                    Self.apply(adjustment, to: &layer)
                    if let particles = adjustment.particles { particles.apply(to: &layer.layer.particles!) }
                    if let control = adjustment.particleControl, !heldOutput { particleControls[id, default: .init()].append(control) }
                    result[id] = layer
                }
                // A copy starts from its template as the scene places it, before scripts.
                for instance in output.instances {
                    guard var layer = base[instance.template], layer.layer.particleSystem == nil else { continue }
                    layer.layer.id = instance.id
                    // An effect with a render graph keeps state under its own ID, which a
                    // copy would advance a second time each frame.
                    layer.layer.effects.removeAll { $0.renderGraph != nil }
                    Self.apply(instance.adjustment, to: &layer)
                    result[instance.id] = layer
                    if let position = instance.adjustment.order { order[instance.id] = position }
                    instances[instance.id] = instance.template
                }
            } catch let issue as SceneScriptIssue {
                stop(issue)
                if failOnError { throw issue }
            }
        }
        return SceneEvaluatedFrame(instances: instances, input: input, layers: result, issues: document.scripts.compactMap { stopped[$0.id] } + warnings, logs: runtime.logs, rigPlayback: rigPlayback, order: order, meshes: meshes, models: models, sounds: sounds, camera: camera, particleControls: particleControls, lights: lights)
    }

    /// A hand-made scene reads its properties' defaults until the viewer changes one; an
    /// imported scene gets only what was set, as its scripts expect.
    private static func userProperties(_ document: SceneDocument, input: SceneFrameInput) -> [String: WebPropertyValue]? {
        guard document.authorSourceDirectory == nil, document.scriptOrigin == nil,
              let properties = document.properties, !properties.isEmpty
        else {
            return input.userProperties
        }
        var merged = Dictionary(properties.map { ($0.id, $0.value) }, uniquingKeysWith: { _, last in last })
        merged.merge(input.userProperties ?? [:]) { _, set in set }
        return merged
    }

    /// A live frame shows the real time. A frame drawn ahead of time (a bake) gets
    /// the clock as it will read when that frame plays, counted from the first one.
    private func clock(_ input: SceneFrameInput) -> Date {
        if input.isRealTime { return Date() }
        let origin = clockOrigin ?? Date().addingTimeInterval(-input.time)
        clockOrigin = origin
        return origin.addingTimeInterval(input.time)
    }

    private func stop(_ issue: SceneScriptIssue) {
        stopped[issue.scriptID] = issue
        if issue.isTemporary {
            resumeTimes[issue.scriptID] = ProcessInfo.processInfo.systemUptime + temporaryStopSeconds
        }
    }

    private func updateCacheIfNeeded(document: SceneDocument) {
        if document.layers == cachedLayers && document.rigs == cachedRigs { return }
        cachedLayers = document.layers
        cachedRigs = document.rigs
        cachedTemplates.removeAll(keepingCapacity: true)
        cachedScriptTargets.removeAll(keepingCapacity: true)

        for layer in document.layers {
            let effects: [[String: Any]] = layer.effects.map { effect in
                ["id": effect.id.uuidString, "kind": effect.kind.rawValue, "isEnabled": effect.isEnabled,
                 "strength": effect.strength, "scale": effect.scale, "direction": effect.direction, "cycles": effect.cycles,
                 "centerX": effect.centerX, "centerY": effect.centerY, "reversed": effect.reversed,
                 "fixedEdge": effect.fixedEdge.rawValue, "values": effect.values]
            }
            let particles: Any = layer.particles.map(Self.particleInput) ?? NSNull()
            let text: Any = layer.text.map {
                ["string": $0.string, "color": ["red": $0.color.red, "green": $0.color.green, "blue": $0.color.blue]] as [String: Any]
            } ?? NSNull()
            let rigs: [[String: Any]] = layer.scriptRigIDs.sorted { $0.uuidString < $1.uuidString }.compactMap { id -> [String: Any]? in
                guard let rig = document.rigs[id] else { return nil }
                return ["id": id.uuidString, "playback": rig.playback.enumerated().map { index, playback in
                    let clip = rig.clips[playback.clip]
                    return ["index": index, "name": clip.name, "frameCount": clip.frameCount,
                            "framesPerSecond": clip.framesPerSecond, "startFrame": playback.startFrame,
                            "rate": playback.rate, "weight": playback.weight, "loops": playback.loops] as [String: Any]
                }]
            }
            let appearance: [String: Any] = [
                "isVisible": layer.isVisible,
                "tint": Self.colorInput(layer.tint),
                "blendMode": layer.blendMode.rawValue,
                "parallaxDepth": layer.parallaxDepth,
                "hasDepthMap": layer.depthFile != nil,
                "depthStrength": layer.depthStrength,
                "depthFollowsCursor": layer.depthFollowsCursor,
                "depthAutoMotion": layer.depthAutoMotion,
                "depthAutoCycles": layer.depthAutoCycles,
                "cursorMask": layer.cursorMask.map(Self.cursorMaskInput) ?? NSNull()
            ]
            let fields: [String: Any] = [
                "id": layer.id.uuidString,
                "name": layer.name,
                "kind": layer.kind.rawValue,
                "isLocked": layer.isLocked,
                "effects": effects,
                "particles": particles,
                "text": text,
                "rigs": rigs,
                "appearance": appearance
            ]
            var base = SceneScriptInput()
            var invalid: Error?
            do {
                for (name, value) in fields {
                    base.key(name)
                    try base.value(value)
                }
            } catch {
                invalid = error
            }
            cachedTemplates[layer.id] = LayerTemplate(base: base, baseCount: fields.count, invalid: invalid, layerOpacity: layer.opacity)
        }
    }

    private func targetLayers(for script: SceneScript, in layers: [SceneLayer]) throws -> [SceneLayer] {
        if let cached = cachedScriptTargets[script.id] { return cached }
        let targetIDs = Set(script.targetLayerIDs(in: layers))
        guard targetIDs.count <= 512 else {
            throw SceneScriptIssue(scriptID: script.id, name: script.name, message: "At most 512 target layers are supported")
        }
        let result = layers.filter { targetIDs.contains($0.id) }
        cachedScriptTargets[script.id] = result
        return result
    }

    private static func numbers(_ members: KeyValuePairs<String, Double>, optional: (String, Double?), into input: inout SceneScriptInput) throws {
        let position = input.beginObject()
        for (name, value) in members {
            input.key(name)
            try input.number(value)
        }
        if let value = optional.1 {
            input.key(optional.0)
            try input.number(value)
        }
        input.end(position, count: members.count + (optional.1 == nil ? 0 : 1))
    }

    private static func transformInput(_ transform: SceneTransform, into input: inout SceneScriptInput) throws {
        try numbers(["offsetX": transform.offsetX, "offsetY": transform.offsetY, "scale": transform.scale,
                     "rotation": transform.rotation], optional: ("scaleY", transform.scaleY), into: &input)
    }

    private static func linkValuesInput(_ values: SceneLinkValues, into input: inout SceneScriptInput) throws {
        try numbers(["offsetX": values.offsetX, "offsetY": values.offsetY, "rotation": values.rotation,
                     "scale": values.scale, "opacity": values.opacity, "brightness": values.brightness,
                     "saturation": values.saturation, "warmth": values.warmth],
                    optional: ("scaleY", values.scaleY), into: &input)
    }

    private static func pointInput(_ point: SIMD2<Float>, into input: inout SceneScriptInput) throws {
        let position = input.beginObject()
        input.key("x")
        try input.number(point.x)
        input.key("y")
        try input.number(point.y)
        input.end(position, count: 2)
    }

    private static func colorInput(_ color: RGBAColor) -> [String: Any] {
        ["red": color.red, "green": color.green, "blue": color.blue, "alpha": color.alpha]
    }

    private static func cursorMaskInput(_ mask: SceneCursorMask) -> [String: Any] {
        ["mode": mask.mode.rawValue, "radius": mask.radius, "softness": mask.softness]
    }

    private static func mediaInput(_ media: SceneMediaState?) -> [String: Any] {
        guard let media, media.isAvailable else { return ["isAvailable": false] }
        var value: [String: Any] = [
            "isAvailable": true, "playback": media.playback.rawValue, "title": media.title, "artist": media.artist,
            "album": media.album, "position": media.position, "duration": media.duration, "artworkID": media.artworkID
        ]
        if let palette = media.palette {
            let rgb = { (color: SIMD3<Double>) in [color.x, color.y, color.z] }
            value["palette"] = ["primary": rgb(palette.primary), "secondary": rgb(palette.secondary),
                                "tertiary": rgb(palette.tertiary), "text": rgb(palette.text),
                                "highContrast": rgb(palette.highContrast)]
        }
        return value
    }

    private static func particleInput(_ particles: SceneParticles) -> [String: Any] {
        ["preset": particles.preset.rawValue, "cursorMode": particles.cursorMode.rawValue, "seed": particles.seed,
         "count": particles.count, "size": particles.size, "cycles": particles.cycles,
         "direction": particles.direction, "sway": particles.sway, "opacity": particles.opacity,
         "color": colorInput(particles.color)]
    }
}

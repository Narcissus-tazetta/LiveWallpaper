import Foundation

struct SceneEvaluatedFrame {
    struct Layer {
        var layer: SceneLayer
        var transform: SceneTransform
        var opacity: Double
        var color: SceneLinkValues
    }
    var input: SceneFrameInput
    var layers: [UUID: Layer]
    var issues: [SceneScriptIssue]
    var logs: [UUID: String]
    var rigPlayback: [UUID: [SceneSkeleton.Playback]] = [:]
    var order: [UUID: Int] = [:]
    var meshes: [SceneMeshFrame] = []
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
    private var clockOrigin: Date?

    init(budget: Budget = .live, temporaryStopSeconds: TimeInterval = 2) {
        self.budget = budget
        self.temporaryStopSeconds = temporaryStopSeconds
    }

    func evaluate(_ document: SceneDocument, input: SceneFrameInput, timeOfDay: SceneTimeOfDay, failOnError: Bool = true) throws -> SceneEvaluatedFrame {
        if previousScripts != document.scripts {
            stopped = [:]
            resumeTimes = [:]
            previousScripts = document.scripts
            runtime.retainPrograms(for: Set(document.scripts.map(\.id)))
        }
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
        let deadline = ProcessInfo.processInfo.systemUptime + budget.perFrame
        let phase = (input.time / Double(document.loopSeconds)).truncatingRemainder(dividingBy: 1)
        let normalizedPhase = phase < 0 ? phase + 1 : phase
        var base: [UUID: SceneEvaluatedFrame.Layer] = [:]
        for layer in document.layers {
            let pose = layer.pose(at: normalizedPhase)
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
        var targetInputs: [UUID: [String: Any]] = [:]
        var warnings: [SceneScriptIssue] = []
        var meshes: [SceneMeshFrame] = []
        for script in document.scripts where script.canRun && !script.targetLayerIDs(in: document.layers).isEmpty {
            if let issue = stopped[script.id] {
                if failOnError { throw issue }
                continue
            }
            do {
                let targetIDs = Set(script.targetLayerIDs(in: document.layers))
                guard targetIDs.count <= 512 else { throw SceneScriptIssue(scriptID: script.id, name: script.name, message: "At most 512 target layers are supported") }
                let targets: [[String: Any]] = try document.layers.filter { targetIDs.contains($0.id) }.map { layer in
                    if let cached = targetInputs[layer.id] { return cached }
                    let evaluated = base[layer.id]!
                    let value: [String: Any] = [
                        "id": layer.id.uuidString, "name": layer.name, "kind": layer.kind.rawValue,
                        "isLocked": layer.isLocked, "transform": try Self.json(evaluated.transform),
                        "opacity": layer.opacity * evaluated.opacity, "values": try Self.json(evaluated.color),
                        "effects": layer.effects.map { effect in
                            ["id": effect.id.uuidString, "kind": effect.kind.rawValue, "isEnabled": effect.isEnabled,
                             "strength": effect.strength, "scale": effect.scale, "direction": effect.direction, "cycles": effect.cycles,
                             "centerX": effect.centerX, "centerY": effect.centerY, "reversed": effect.reversed,
                             "fixedEdge": effect.fixedEdge.rawValue, "values": effect.values]
                        },
                        "particles": try layer.particles.map(Self.particleInput) ?? NSNull(),
                        "text": layer.text.map { ["string": $0.string, "color": ["red": $0.color.red, "green": $0.color.green, "blue": $0.color.blue]] as [String: Any] } ?? NSNull(),
                        "rigs": layer.scriptRigIDs.sorted { $0.uuidString < $1.uuidString }.compactMap { id -> [String: Any]? in
                            guard let rig = document.rigs[id] else { return nil }
                            return ["id": id.uuidString, "playback": rig.playback.enumerated().map { index, playback in
                                let clip = rig.clips[playback.clip]
                                return ["index": index, "name": clip.name, "frameCount": clip.frameCount,
                                        "framesPerSecond": clip.framesPerSecond, "startFrame": playback.startFrame,
                                        "rate": playback.rate, "weight": playback.weight, "loops": playback.loops] as [String: Any]
                            }]
                        },
                        "appearance": ["isVisible": layer.isVisible, "tint": try Self.json(layer.tint),
                                       "blendMode": layer.blendMode.rawValue,
                                       "parallaxDepth": layer.parallaxDepth, "hasDepthMap": layer.depthFile != nil,
                                       "depthStrength": layer.depthStrength, "depthFollowsCursor": layer.depthFollowsCursor,
                                       "depthAutoMotion": layer.depthAutoMotion, "depthAutoCycles": layer.depthAutoCycles,
                                       "cursorMask": try layer.cursorMask.map(Self.json) ?? NSNull()]
                    ]
                    targetInputs[layer.id] = value
                    return value
                }
                var context: [String: Any] = [
                    "targets": targets, "params": script.params, "loopSeconds": document.loopSeconds,
                    "canvas": ["width": document.canvasWidth, "height": document.canvasHeight, "aspectRatio": document.aspectRatio]
                ]
                var missing: [String] = []
                if script.usesTime {
                    context["elapsedTime"] = input.time
                    context["time"] = normalizedPhase * Double(document.loopSeconds)
                    context["phase"] = normalizedPhase
                } else { missing += ["time", "phase", "elapsedTime"] }
                if script.usesTimeOfDay {
                    context["timeOfDay"] = timeOfDay.rawValue
                    let now = clock(input)
                    context["wallClock"] = ["epochMilliseconds": (now.timeIntervalSince1970 * 1000).rounded(),
                                            "timeZoneOffsetMinutes": TimeZone.current.secondsFromGMT(for: now) / 60]
                } else { missing += ["timeOfDay", "wallClock"] }
                if script.usesCursor {
                    context["cursor"] = ["x": input.parallax.x, "y": input.parallax.y]
                    context["cursorActive"] = input.cursor != nil
                    context["pointer"] = input.cursor.map { ["x": $0.x, "y": $0.y] } ?? NSNull()
                    context["pointerPresses"] = input.pointerPresses.map {
                        ["isDown": $0.isDown, "x": $0.position.x, "y": $0.position.y] as [String: Any]
                    }
                } else { missing += ["cursor", "cursorActive", "pointer", "pointerPresses"] }
                if script.usesMedia {
                    context["media"] = Self.mediaInput(input.media)
                } else { missing.append("media") }
                context["_missing"] = missing
                let data = try JSONSerialization.data(withJSONObject: context)
                let output = try runtime.evaluate(
                    script, input: data, layers: document.layers, rigs: document.rigs, perScript: budget.perScript, deadline: deadline
                )
                warnings += output.warnings.map {
                    SceneScriptIssue(scriptID: script.id, name: script.name, message: $0, isPartial: true)
                }
                meshes += output.meshes
                for (id, adjustment) in output.adjustments {
                    if let position = adjustment.order { order[id] = position }
                    for (rigID, changes) in adjustment.rigPlayback {
                        var playback = rigPlayback[rigID] ?? document.rigs[rigID]!.playback
                        for (index, change) in changes { change.apply(to: &playback[index]) }
                        rigPlayback[rigID] = playback
                    }
                    var layer = result[id]!
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
                    if let particles = adjustment.particles { particles.apply(to: &layer.layer.particles!) }
                    if let text = adjustment.text { text.apply(to: &layer.layer.text!) }
                    result[id] = layer
                }
            } catch let issue as SceneScriptIssue {
                stop(issue)
                if failOnError { throw issue }
            }
        }
        return SceneEvaluatedFrame(input: input, layers: result, issues: document.scripts.compactMap { stopped[$0.id] } + warnings, logs: runtime.logs, rigPlayback: rigPlayback, order: order, meshes: meshes)
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

    private static func json(_ value: some Encodable) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
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

    private static func particleInput(_ particles: SceneParticles) throws -> Any {
        ["preset": particles.preset.rawValue, "cursorMode": particles.cursorMode.rawValue, "seed": particles.seed,
         "count": particles.count, "size": particles.size, "cycles": particles.cycles,
         "direction": particles.direction, "sway": particles.sway, "opacity": particles.opacity,
         "color": try json(particles.color)] as [String: Any]
    }
}

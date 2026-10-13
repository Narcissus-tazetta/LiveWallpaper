import CoreFoundation
import Foundation
import QuickJS

final class SceneScriptRuntime {
    private struct Program {
        let source: String
        let pointer: OpaquePointer
        var memoryBytes: Int
    }
    static let maximumMemoryBytes = 128 * 1024 * 1024
    /// The messages of running out of time: Bridge.c's for one script, and evaluate's
    /// for the frame.
    private static let timeLimitMessages: Set = ["Execution time limit exceeded", "Frame execution time limit exceeded"]
    private var programs: [UUID: Program] = [:]
    private(set) var logs: [UUID: String] = [:]

    deinit {
        for program in programs.values { lwjs_destroy(program.pointer) }
    }

    func prepare(_ script: SceneScript) throws {
        guard SceneScript.supports(version: script.version) else {
            throw SceneScriptIssue(scriptID: script.id, name: script.name, message: "Unsupported script API version: \(script.version)")
        }
        guard !script.source.contains("\0") else {
            throw SceneScriptIssue(scriptID: script.id, name: script.name, message: "Script source cannot contain NUL")
        }
        if programs[script.id]?.source == script.source { return }
        if let old = programs.removeValue(forKey: script.id) { lwjs_destroy(old.pointer) }
        var error: UnsafeMutablePointer<CChar>?
        let pointer = script.source.withCString { lwjs_compile($0, &error) }
        if let error {
            defer { lwjs_free_string(error) }
            throw issue(String(cString: error), script: script)
        }
        let memory = lwjs_memory_usage(pointer!)
        guard programs.values.reduce(memory, { $0 + $1.memoryBytes }) <= Self.maximumMemoryBytes else {
            lwjs_destroy(pointer!)
            throw SceneScriptIssue(scriptID: script.id, name: script.name, message: "Combined script memory limit exceeded (128 MiB)")
        }
        programs[script.id] = Program(source: script.source, pointer: pointer!, memoryBytes: memory)
    }

    /// Stops the script after `perScript` seconds, or at `deadline` when that comes first.
    func evaluate(
        _ script: SceneScript, input: Data, layers: [SceneLayer], perScript: TimeInterval, deadline: TimeInterval
    ) throws -> [UUID: SceneScriptAdjustment] {
        do {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw failure("Frame execution time limit exceeded") }
            var error: UnsafeMutablePointer<CChar>?
            let otherMemory = programs.filter { $0.key != script.id }.values.reduce(0) { $0 + $1.memoryBytes }
            lwjs_set_memory_limit(programs[script.id]!.pointer, min(16 * 1024 * 1024, Self.maximumMemoryBytes - otherMemory))
            let result = String(decoding: input, as: UTF8.self).withCString {
                lwjs_evaluate(programs[script.id]!.pointer, $0, min(remaining, perScript), &error)
            }
            if let error {
                defer { lwjs_free_string(error) }
                logs[script.id] = String(cString: lwjs_logs(programs[script.id]!.pointer))
                lwjs_destroy(programs.removeValue(forKey: script.id)!.pointer)
                throw failure(String(cString: error))
            }
            defer { lwjs_free_string(result) }
            logs[script.id] = String(cString: lwjs_logs(programs[script.id]!.pointer))
            programs[script.id]!.memoryBytes = lwjs_memory_usage(programs[script.id]!.pointer)
            let data = Data(String(cString: result!).utf8)
            return try Self.readOutput(data, script: script, layers: layers)
        } catch let failure as SceneScriptIssue {
            throw issue(failure.message, script: script)
        } catch {
            throw issue(error.localizedDescription, script: script)
        }
    }

    private func issue(_ message: String, script: SceneScript) -> SceneScriptIssue {
        SceneScriptIssue(scriptID: script.id, name: script.name, message: message,
                         isTemporary: Self.timeLimitMessages.contains(message))
    }

    func retainPrograms(for ids: Set<UUID>) {
        for id in Array(programs.keys) where !ids.contains(id) {
            lwjs_destroy(programs.removeValue(forKey: id)!.pointer)
        }
        logs = logs.filter { ids.contains($0.key) }
    }

    private func failure(_ message: String) -> SceneScriptIssue {
        Self.failure(message)
    }

    private static func failure(_ message: String) -> SceneScriptIssue {
        SceneScriptIssue(scriptID: UUID(), name: "JavaScript", message: message)
    }

    private static func keys(_ object: [String: Any], allowed: Set<String>, path: String) throws {
        if let unknown = Set(object.keys).subtracting(allowed).sorted().first {
            throw failure("\(path).\(unknown): unknown field")
        }
    }

    private static func object(_ value: Any?, path: String) throws -> [String: Any] {
        guard let value = value as? [String: Any] else { throw failure("\(path): expected an object") }
        return value
    }

    private static func numbers(_ object: [String: Any], ranges: [String: ClosedRange<Double>], path: String) throws {
        for (key, range) in ranges where object[key] != nil {
            guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, range.contains(number.doubleValue)
            else { throw failure("\(path).\(key): expected a finite number in \(range)") }
        }
    }

    /// Fields stored as Int: a fraction would only fail later, in JSONDecoder, with a
    /// message that does not name the field.
    private static func integers(_ object: [String: Any], names: [String], path: String) throws {
        for name in names where object[name] != nil {
            guard let number = object[name] as? NSNumber, number.doubleValue.rounded() == number.doubleValue else {
                throw failure("\(path).\(name): expected a whole number")
            }
        }
    }

    private static func booleans(_ object: [String: Any], names: [String], path: String) throws {
        for name in names where object[name] != nil {
            guard let number = object[name] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw failure("\(path).\(name): expected a boolean")
            }
        }
    }

    private static func choices(_ object: [String: Any], values: [String: Set<String>], path: String) throws {
        for (key, allowed) in values where object[key] != nil {
            guard let value = object[key] as? String, allowed.contains(value) else {
                throw failure("\(path).\(key): expected one of \(allowed.sorted().joined(separator: ", "))")
            }
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ value: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }

    static func readOutput(_ data: Data, script: SceneScript, layers: [SceneLayer]) throws -> [UUID: SceneScriptAdjustment] {
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [Any], entries.count <= 128 else {
            throw failure("update(context) must return an array with at most 128 adjustments")
        }
        var result: [UUID: SceneScriptAdjustment] = [:]
        let targets = Set(script.targetLayerIDs(in: layers))
        for entry in entries {
            let item = try object(entry, path: "output")
            try keys(item, allowed: ["id", "values", "appearance", "effects", "particles"], path: "output")
            guard let text = item["id"] as? String, let id = UUID(uuidString: text), targets.contains(id),
                  let layer = layers.first(where: { $0.id == id }), result[id] == nil
            else { throw failure("output.id: expected a unique ID from context.targets") }
            var adjustment = SceneScriptAdjustment()
            if let raw = item["appearance"] {
                let appearance = try object(raw, path: "appearance")
                try keys(appearance, allowed: ["isVisible", "blendMode", "parallaxDepth", "depthStrength", "depthFollowsCursor", "depthAutoMotion", "depthAutoCycles", "cursorMask", "clearCursorMask"], path: "appearance")
                try numbers(appearance, ranges: ["parallaxDepth": 0 ... 1, "depthStrength": 0 ... 1, "depthAutoMotion": 0 ... 1, "depthAutoCycles": 1 ... 12], path: "appearance")
                try integers(appearance, names: ["depthAutoCycles"], path: "appearance")
                try booleans(appearance, names: ["isVisible", "depthFollowsCursor", "clearCursorMask"], path: "appearance")
                try choices(appearance, values: ["blendMode": Set(SceneBlendMode.allCases.map(\.rawValue))], path: "appearance")
                if let rawMask = appearance["cursorMask"] {
                    let mask = try object(rawMask, path: "appearance.cursorMask")
                    try keys(mask, allowed: ["mode", "radius", "softness"], path: "appearance.cursorMask")
                    try numbers(mask, ranges: ["radius": 0.01 ... 1, "softness": 0 ... 1], path: "appearance.cursorMask")
                    try choices(mask, values: ["mode": Set(SceneCursorMaskMode.allCases.map(\.rawValue))], path: "appearance.cursorMask")
                    guard appearance["clearCursorMask"] as? Bool != true else { throw failure("appearance: cannot set and clear cursorMask together") }
                }
                adjustment.appearance = try decode(SceneScriptAppearanceValues.self, appearance)
            }
            if let raw = item["values"] {
                let values = try object(raw, path: "values")
                let ranges: [String: ClosedRange<Double>] = [
                    "offsetX": -4 ... 4, "offsetY": -4 ... 4, "rotation": -3600 ... 3600,
                    "scale": 0.01 ... 16, "opacity": 0 ... 1, "brightness": -1 ... 1,
                    "saturation": 0 ... 4, "warmth": -1 ... 1
                ]
                try keys(values, allowed: Set(ranges.keys), path: "values")
                try numbers(values, ranges: ranges, path: "values")
                adjustment.values = try decode(SceneLinkValues.self, values)
            }
            if let raw = item["effects"] {
                guard let effects = raw as? [Any], effects.count <= 16 else { throw failure("effects: expected at most 16 entries") }
                for rawEffect in effects {
                    var effect = try object(rawEffect, path: "effects")
                    try keys(effect, allowed: ["id", "kind", "fixedEdge", "isEnabled", "strength", "scale", "direction", "cycles", "centerX", "centerY", "reversed"], path: "effects")
                    guard let text = effect.removeValue(forKey: "id") as? String, let effectID = UUID(uuidString: text),
                          layer.effects.contains(where: { $0.id == effectID }), adjustment.effects[effectID] == nil
                    else { throw failure("effects.id: expected a unique effect ID from this target") }
                    try numbers(effect, ranges: ["strength": 0 ... 1, "scale": 0 ... 1, "direction": -3600 ... 3600,
                                                 "cycles": 1 ... 12, "centerX": 0 ... 1, "centerY": 0 ... 1], path: "effects")
                    try integers(effect, names: ["cycles"], path: "effects")
                    try booleans(effect, names: ["isEnabled", "reversed"], path: "effects")
                    try choices(effect, values: ["kind": Set(SceneEffectKind.allCases.map(\.rawValue)), "fixedEdge": Set(SceneFixedEdge.allCases.map(\.rawValue))], path: "effects")
                    adjustment.effects[effectID] = try decode(SceneScriptEffectValues.self, effect)
                }
            }
            if let raw = item["particles"] {
                guard layer.particles != nil else { throw failure("particles: target is not a particle layer") }
                let particles = try object(raw, path: "particles")
                try choices(particles, values: ["preset": Set(SceneParticlePreset.allCases.map(\.rawValue)), "cursorMode": Set(SceneParticleCursorMode.allCases.map(\.rawValue))], path: "particles")
                try keys(particles, allowed: ["preset", "cursorMode", "seed", "count", "size", "cycles", "direction", "sway", "opacity", "color"], path: "particles")
                try numbers(particles, ranges: ["count": 5 ... 2000, "size": 0 ... 1, "cycles": 1 ... 12,
                                                "direction": -3600 ... 3600, "sway": 0 ... 1, "opacity": 0 ... 1, "seed": 0 ... 2147483647], path: "particles")
                try integers(particles, names: ["count", "cycles", "seed"], path: "particles")
                if let rawColor = particles["color"] {
                    let color = try object(rawColor, path: "particles.color")
                    try keys(color, allowed: ["red", "green", "blue", "alpha"], path: "particles.color")
                    try numbers(color, ranges: ["red": 0 ... 1, "green": 0 ... 1, "blue": 0 ... 1, "alpha": 0 ... 1], path: "particles.color")
                }
                adjustment.particles = try decode(SceneScriptParticleValues.self, particles)
            }
            var drawable = layer
            adjustment.appearance?.apply(to: &drawable)
            for index in drawable.effects.indices {
                adjustment.effects[drawable.effects[index].id]?.apply(to: &drawable.effects[index])
            }
            if let particles = adjustment.particles { particles.apply(to: &drawable.particles!) }
            guard !drawable.usesCursor || layer.usesCursor || script.usesCursor else {
                throw failure("Enable the cursor input dependency to activate cursor rendering")
            }
            guard !drawable.isAnimated || layer.isAnimated || script.usesTime else {
                throw failure("Enable the loop time input dependency to activate animation")
            }
            result[id] = adjustment
        }
        return result
    }
}

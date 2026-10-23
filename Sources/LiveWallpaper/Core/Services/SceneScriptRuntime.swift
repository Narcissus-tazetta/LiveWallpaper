import CoreFoundation
import Foundation
import QuickJS
import OSLog

final class SceneScriptRuntime {
    private struct Program {
        let script: SceneScript
        var lastTime: Double?
        var hasStarted = false
        let pointer: OpaquePointer
        var memoryBytes: Int
        /// Set after a run instead of measuring: the measurement walks the whole heap
        /// and only matters once another script needs the total.
        var memoryIsStale = false
    }
    static let maximumMemoryBytes = 128 * 1024 * 1024
    /// The first run of a module bundle also loads its modules and runs every init,
    /// once: it gets the time compiling gets instead of one frame's share.
    static let moduleStartSeconds: TimeInterval = 0.1
    /// The messages of running out of time: Bridge.c's for one script, and evaluate's
    /// for the frame.
    private static let timeLimitMessages: Set = ["Execution time limit exceeded", "Frame execution time limit exceeded"]
    private var programs: [UUID: Program] = [:]
    private(set) var logs: [UUID: String] = [:]

    deinit {
        for (id, program) in programs { destroy(program.pointer, id: id, reason: "deinit") }
    }

    /// The crash this traces aborts inside lwjs_destroy's final GC; the line goes out
    /// first so the log shows which destroy it was and what led to it.
    private func destroy(_ pointer: OpaquePointer, id: UUID, reason: String, detail: String = "") {
        AppLog.sceneScript.info("destroy begin script=\(id.uuidString, privacy: .public) reason=\(reason, privacy: .public) memory=\(lwjs_memory_usage(pointer)) \(detail, privacy: .public)")
        lwjs_destroy(pointer)
        AppLog.sceneScript.info("destroy end script=\(id.uuidString, privacy: .public)")
    }

    func prepare(_ script: SceneScript) throws {
        guard SceneScript.supports(version: script.version) else {
            throw SceneScriptIssue(scriptID: script.id, name: script.name, message: "Unsupported script API version: \(script.version)")
        }
        // Cached programs have already passed bundle validation; rescanning large
        // module sources on every frame costs more than running their JavaScript.
        if programs[script.id]?.script == script { return }
        guard !script.source.contains("\0") else {
            throw SceneScriptIssue(scriptID: script.id, name: script.name, message: "Script source cannot contain NUL")
        }
        guard script.source.utf8.count <= 65536,
              (script.modules?.count ?? 0) <= 256,
              (script.modules?.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count } ?? 0) <= 1048576,
              script.modules?.allSatisfy({ !$0.key.contains("\0") && !$0.value.contains("\0") }) != false
        else { throw issue("Script bundle exceeds supported limits", script: script) }
        if let old = programs.removeValue(forKey: script.id) { destroy(old.pointer, id: script.id, reason: "source changed") }
        var error: UnsafeMutablePointer<CChar>?
        let pointer: OpaquePointer?
        if let modules = script.modules {
            let data = try JSONSerialization.data(withJSONObject: modules, options: [.sortedKeys])
            pointer = script.source.withCString { source in
                String(decoding: data, as: UTF8.self).withCString { lwjs_compile_modules(source, $0, &error) }
            }
        } else {
            pointer = script.source.withCString { lwjs_compile($0, &error) }
        }
        if let error {
            defer { lwjs_free_string(error) }
            throw issue(String(cString: error), script: script)
        }
        let memory = lwjs_memory_usage(pointer!)
        guard programs.keys.reduce(memory, { $0 + memoryBytes(of: $1) }) <= Self.maximumMemoryBytes else {
            destroy(pointer!, id: script.id, reason: "memory limit")
            throw SceneScriptIssue(scriptID: script.id, name: script.name, message: "Combined script memory limit exceeded (128 MiB)")
        }
        programs[script.id] = Program(script: script, pointer: pointer!, memoryBytes: memory)
    }

    /// Reached from Bridge.c's storage(), on the thread running the script.
    private static let storageHandler: lwjs_storage_handler = { opaque, operation, global, key, keyLength, value, valueLength, result, resultLength in
        let session = Unmanaged<SceneScriptStorage.Session>.fromOpaque(opaque!).takeUnretainedValue()
        let name = key.map { Data(bytes: $0, count: keyLength) } ?? Data()
        let area = session.area(global: global != 0)
        switch operation {
        case 0:
            guard let found = session.store.get(name, in: area) else { return -1 }
            let buffer = malloc(max(found.count, 1))!
            found.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: found.count)
            result!.pointee = buffer.assumingMemoryBound(to: CChar.self)
            resultLength!.pointee = found.count
            return -1
        case 1:
            return session.store.set(name, Data(bytes: value!, count: valueLength), in: area) ? 1 : 0
        case 2:
            return session.store.delete(name, in: area) ? 1 : 0
        default:
            session.store.clear(global == 2 ? [session.area(global: true), session.area(global: false)] : [area])
            return 1
        }
    }

    /// Stops the script after `perScript` seconds, or at `deadline` when that comes first.
    func evaluate(
        _ script: SceneScript, input: SceneScriptInput, elapsedTime: Double, layers: [SceneLayer], rigs: [UUID: SceneSkeleton] = [:],
        storage: SceneScriptStorage.Session, perScript: TimeInterval, deadline: TimeInterval
    ) throws -> SceneScriptOutput {
        do {
            if script.modules != nil {
                if let previous = programs[script.id]?.lastTime, elapsedTime < previous {
                    destroy(programs.removeValue(forKey: script.id)!.pointer, id: script.id,
                            reason: "time went backwards", detail: "previous=\(previous) now=\(elapsedTime)")
                    try prepare(script)
                }
                programs[script.id]!.lastTime = elapsedTime
            }
            let starting = script.modules != nil && !programs[script.id]!.hasStarted
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 || starting else { throw failure("Frame execution time limit exceeded") }
            let budget = starting ? max(min(remaining, perScript), Self.moduleStartSeconds) : min(remaining, perScript)
            var error: UnsafeMutablePointer<CChar>?
            let otherMemory = programs.keys.filter { $0 != script.id }.reduce(0) { $0 + memoryBytes(of: $1) }
            lwjs_set_memory_limit(programs[script.id]!.pointer, min(16 * 1024 * 1024, Self.maximumMemoryBytes - otherMemory))
            let pointer = programs[script.id]!.pointer
            lwjs_set_storage(pointer, Self.storageHandler, Unmanaged.passUnretained(storage).toOpaque())
            let result = withExtendedLifetime(storage) {
                input.bytes.withUnsafeBufferPointer { lwjs_evaluate(pointer, $0.baseAddress!, budget, &error) }
            }
            lwjs_set_storage(pointer, nil, nil)
            programs[script.id]?.hasStarted = true
            if let error {
                defer { lwjs_free_string(error) }
                logs[script.id] = String(cString: lwjs_logs(programs[script.id]!.pointer))
                let message = String(cString: error)
                // The interrupt is uncatchable and the bundle keeps its animation clocks in
                // JavaScript, so a run cut short mid-frame leaves a usable program; throwing
                // it away would restart every animation from its initial frame. A run cut
                // short while the modules were still initializing is half-built, though.
                if script.modules != nil, !starting, Self.timeLimitMessages.contains(message) {
                    throw failure(message)
                }
                destroy(programs.removeValue(forKey: script.id)!.pointer, id: script.id,
                        reason: Self.timeLimitMessages.contains(message) ? "time limit" : "script error",
                        detail: "budget=\(budget) starting=\(starting) error=\(message.prefix(200))")
                throw failure(message)
            }
            defer { lwjs_free_string(result) }
            logs[script.id] = String(cString: lwjs_logs(programs[script.id]!.pointer))
            programs[script.id]!.memoryIsStale = true
            let outputLength = strlen(result!)
            let outputData = Data(bytesNoCopy: result!, count: outputLength, deallocator: .none)
            var output = try JSONSerialization.jsonObject(with: outputData)
            var warnings: [String] = []
            var meshes: [SceneMeshFrame] = []
            // A module bundle runs several independent scripts; one that failed is
            // reported here while the rest keep running.
            if script.modules != nil, let wrapped = output as? [String: Any] {
                try Self.keys(wrapped, allowed: ["adjustments", "warnings"], path: "output")
                guard let list = wrapped["warnings"] as? [String], list.count <= 16,
                      list.allSatisfy({ $0.utf8.count <= 1024 }) else {
                    throw failure("output.warnings: expected at most 16 messages of at most 1 KiB")
                }
                warnings = list
                var length = 0
                let bytes = lwjs_meshes(programs[script.id]!.pointer, &length)
                meshes = try Self.readMeshes(bytes, length: length)
                output = wrapped["adjustments"] as Any
            }
            return SceneScriptOutput(adjustments: try Self.readOutput(output, script: script, layers: layers, rigs: rigs),
                                     warnings: warnings, meshes: meshes)
        } catch let failure as SceneScriptIssue {
            throw issue(failure.message, script: script)
        } catch {
            throw issue(error.localizedDescription, script: script)
        }
    }

    private func memoryBytes(of id: UUID) -> Int {
        if programs[id]!.memoryIsStale {
            programs[id]!.memoryBytes = lwjs_memory_usage(programs[id]!.pointer)
            programs[id]!.memoryIsStale = false
        }
        return programs[id]!.memoryBytes
    }

    private func issue(_ message: String, script: SceneScript) -> SceneScriptIssue {
        SceneScriptIssue(scriptID: script.id, name: script.name, message: message,
                         isTemporary: Self.timeLimitMessages.contains(message))
    }

    /// Whether the script's program survived its last run, so a run that ran out of
    /// time can be skipped instead of restarted.
    func isLoaded(_ id: UUID) -> Bool {
        programs[id] != nil
    }

    func retainPrograms(for ids: Set<UUID>) {
        for id in Array(programs.keys) where !ids.contains(id) {
            destroy(programs.removeValue(forKey: id)!.pointer, id: id, reason: "retain")
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
        // The first unknown key in sorted order, without building sets for the usual
        // case of none.
        var unknown: String?
        for key in object.keys where !allowed.contains(key) {
            if unknown.map({ key < $0 }) ?? true { unknown = key }
        }
        if let unknown {
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

    /// Built once: readOutput runs for every target of every frame.
    private enum OutputKeys {
        static let item: Set = ["id", "values", "appearance", "effects", "particles", "rigs", "order", "text"]
        static let appearance: Set = ["isVisible", "tint", "blendMode", "parallaxDepth", "depthStrength", "depthFollowsCursor",
                                      "depthAutoMotion", "depthAutoCycles", "cursorMask", "clearCursorMask"]
        static let appearanceRanges: [String: ClosedRange<Double>] = [
            "parallaxDepth": 0 ... 1, "depthStrength": 0 ... 1, "depthAutoMotion": 0 ... 1, "depthAutoCycles": 1 ... 12
        ]
        static let blendModes: [String: Set<String>] = ["blendMode": Set(SceneBlendMode.allCases.map(\.rawValue))]
        static let valueRanges = linkRanges(scale: 0.05 ... 16)
        static let moduleValueRanges = linkRanges(scale: -64 ... 64)
        static let values = Set(valueRanges.keys)

        private static func linkRanges(scale: ClosedRange<Double>) -> [String: ClosedRange<Double>] {
            [
                "offsetX": -4 ... 4, "offsetY": -4 ... 4, "rotation": -3600 ... 3600,
                "scale": scale, "scaleY": scale, "opacity": 0 ... 1, "brightness": -1 ... 1,
                "saturation": 0 ... 4, "warmth": -1 ... 1
            ]
        }
    }

    /// Appearance fields that need no nested decoding, read without the JSON round
    /// trip; tint and cursorMask keep JSONDecoder's handling of missing members.
    private static func appearanceValues(_ appearance: [String: Any]) throws -> SceneScriptAppearanceValues {
        guard appearance["tint"] == nil, appearance["cursorMask"] == nil else {
            return try decode(SceneScriptAppearanceValues.self, appearance)
        }
        func number(_ key: String) -> NSNumber? { appearance[key] as? NSNumber }
        var result = SceneScriptAppearanceValues()
        result.isVisible = number("isVisible")?.boolValue
        result.blendMode = (appearance["blendMode"] as? String).flatMap(SceneBlendMode.init(rawValue:))
        result.parallaxDepth = number("parallaxDepth")?.doubleValue
        result.depthStrength = number("depthStrength")?.doubleValue
        result.depthFollowsCursor = number("depthFollowsCursor")?.boolValue
        result.depthAutoMotion = number("depthAutoMotion")?.doubleValue
        result.depthAutoCycles = number("depthAutoCycles")?.intValue
        result.clearCursorMask = number("clearCursorMask")?.boolValue
        return result
    }

    /// What decode(SceneLinkValues.self, values) gives for values already checked to
    /// be finite numbers, without the JSON round trip: most targets send values every
    /// frame.
    private static func linkValues(_ values: [String: Any]) -> SceneLinkValues {
        func number(_ key: String) -> Double? { (values[key] as? NSNumber)?.doubleValue }
        var result = SceneLinkValues()
        result.offsetX = number("offsetX") ?? 0
        result.offsetY = number("offsetY") ?? 0
        result.rotation = number("rotation") ?? 0
        result.scale = number("scale") ?? 1
        result.scaleY = number("scaleY")
        result.opacity = number("opacity") ?? 1
        result.brightness = number("brightness") ?? 0
        result.saturation = number("saturation") ?? 1
        result.warmth = number("warmth") ?? 0
        return result
    }

    static let maximumMeshFloats = 8_000_000

    /// The meshes the script emitted: per mesh a parent and a material (u32 length, UTF-8)
    /// and u32 count of float32, whole quads of 36.
    private static func readMeshes(_ bytes: UnsafePointer<UInt8>?, length: Int) throws -> [SceneMeshFrame] {
        guard let bytes, length > 0 else { return [] }
        let data = UnsafeRawBufferPointer(start: bytes, count: length)
        var offset = 0
        func readCount() throws -> Int {
            guard offset + 4 <= length else { throw failure("output.meshes: truncated") }
            defer { offset += 4 }
            return Int(data.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
        func readString() throws -> String {
            let size = try readCount()
            guard size <= 4096, offset + size <= length,
                  let text = String(bytes: data[offset ..< offset + size], encoding: .utf8)
            else { throw failure("output.meshes: invalid string") }
            offset += size
            return text
        }
        var meshes: [SceneMeshFrame] = []
        var total = 0
        while offset < length {
            let parent = try readString(), material = try readString()
            let count = try readCount()
            total += count
            guard count % SceneMeshFrame.floatsPerQuad == 0, offset + count * 4 <= length, total <= maximumMeshFloats,
                  meshes.count < 256
            else { throw failure("output.meshes: expected whole quads within the limits") }
            let vertices = [Float](unsafeUninitializedCapacity: count) { buffer, filled in
                if count > 0 { UnsafeMutableRawBufferPointer(buffer).copyMemory(from: UnsafeRawBufferPointer(rebasing: data[offset ..< offset + count * 4])) }
                filled = count
            }
            guard vertices.allSatisfy(\.isFinite) else { throw failure("output.meshes: vertices must be finite") }
            offset += count * 4
            meshes.append(SceneMeshFrame(parent: parent, material: material, vertices: vertices))
        }
        return meshes
    }

    private static func readText(_ raw: Any, layer: SceneLayer) throws -> SceneScriptTextValues {
        guard layer.text != nil else { throw failure("text: target is not a text layer") }
        let text = try object(raw, path: "text")
        try keys(text, allowed: ["string", "color"], path: "text")
        if let string = text["string"] {
            guard let string = string as? String, string.count <= SceneText.maximumLength else {
                throw failure("text.string: expected a string of at most \(SceneText.maximumLength) characters")
            }
        }
        if let rawColor = text["color"] {
            let color = try object(rawColor, path: "text.color")
            try keys(color, allowed: ["red", "green", "blue"], path: "text.color")
            try numbers(color, ranges: ["red": 0 ... 1, "green": 0 ... 1, "blue": 0 ... 1], path: "text.color")
        }
        return try decode(SceneScriptTextValues.self, text)
    }

    static func readOutput(_ output: Any, script: SceneScript, layers: [SceneLayer], rigs: [UUID: SceneSkeleton] = [:]) throws -> [UUID: SceneScriptAdjustment] {
        guard let entries = output as? [Any], entries.count <= 512 else {
            throw failure("update(context) must return an array with at most 512 adjustments")
        }
        var result: [UUID: SceneScriptAdjustment] = [:]
        let targets = Set(script.targetLayerIDs(in: layers))
        let layersByID = Dictionary(layers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in entries {
            let item = try object(entry, path: "output")
            try keys(item, allowed: OutputKeys.item, path: "output")
            guard let text = item["id"] as? String, let id = UUID(uuidString: text), targets.contains(id),
                  let layer = layersByID[id], result[id] == nil
            else { throw failure("output.id: expected a unique ID from context.targets") }
            var adjustment = SceneScriptAdjustment()
            if item["order"] != nil {
                try numbers(item, ranges: ["order": 0 ... Double(max(layers.count - 1, 0))], path: "output")
                try integers(item, names: ["order"], path: "output")
                adjustment.order = (item["order"] as? NSNumber)?.intValue
            }
            if let raw = item["rigs"] {
                guard let entries = raw as? [Any], entries.count <= layer.scriptRigIDs.count else {
                    throw failure("rigs: expected rigs belonging to this target")
                }
                for rawEntry in entries {
                    let rig = try object(rawEntry, path: "rigs")
                    try keys(rig, allowed: ["id", "playback"], path: "rigs")
                    guard let text = rig["id"] as? String, let id = UUID(uuidString: text),
                          layer.scriptRigIDs.contains(id), let skeleton = rigs[id],
                          adjustment.rigPlayback[id] == nil,
                          let playback = rig["playback"] as? [Any], playback.count <= skeleton.playback.count else {
                        throw failure("rigs: expected a unique rig from this target and valid playback entries")
                    }
                    var changes: [Int: SceneScriptPlaybackValues] = [:]
                    for rawPlayback in playback {
                        var change = try object(rawPlayback, path: "rigs.playback")
                        try keys(change, allowed: ["index", "frame", "rate", "weight"], path: "rigs.playback")
                        try numbers(change, ranges: ["index": 0 ... Double(max(skeleton.playback.count - 1, 0)),
                                                    "frame": -1e9 ... 1e9, "rate": -1000 ... 1000, "weight": 0 ... 1], path: "rigs.playback")
                        try integers(change, names: ["index"], path: "rigs.playback")
                        guard let index = (change.removeValue(forKey: "index") as? NSNumber)?.intValue,
                              skeleton.playback.indices.contains(index), changes[index] == nil,
                              change["frame"] == nil || change["rate"] == nil else {
                            throw failure("rigs.playback: expected a unique playback index and either frame or rate")
                        }
                        changes[index] = try decode(SceneScriptPlaybackValues.self, change)
                    }
                    adjustment.rigPlayback[id] = changes
                }
            }
            if let raw = item["appearance"] {
                let appearance = try object(raw, path: "appearance")
                try keys(appearance, allowed: OutputKeys.appearance, path: "appearance")
                try numbers(appearance, ranges: OutputKeys.appearanceRanges, path: "appearance")
                try integers(appearance, names: ["depthAutoCycles"], path: "appearance")
                try booleans(appearance, names: ["isVisible", "depthFollowsCursor", "clearCursorMask"], path: "appearance")
                try choices(appearance, values: OutputKeys.blendModes, path: "appearance")
                if let rawTint = appearance["tint"] {
                    let tint = try object(rawTint, path: "appearance.tint")
                    try keys(tint, allowed: ["red", "green", "blue", "alpha"], path: "appearance.tint")
                    try numbers(tint, ranges: ["red": 0 ... 1, "green": 0 ... 1, "blue": 0 ... 1, "alpha": 0 ... 1], path: "appearance.tint")
                }
                if let rawMask = appearance["cursorMask"] {
                    let mask = try object(rawMask, path: "appearance.cursorMask")
                    try keys(mask, allowed: ["mode", "radius", "softness"], path: "appearance.cursorMask")
                    try numbers(mask, ranges: ["radius": 0.01 ... 1, "softness": 0 ... 1], path: "appearance.cursorMask")
                    try choices(mask, values: ["mode": Set(SceneCursorMaskMode.allCases.map(\.rawValue))], path: "appearance.cursorMask")
                    guard appearance["clearCursorMask"] as? Bool != true else { throw failure("appearance: cannot set and clear cursorMask together") }
                }
                adjustment.appearance = try appearanceValues(appearance)
            }
            if let raw = item["values"] {
                let values = try object(raw, path: "values")
                let ranges = script.modules != nil ? OutputKeys.moduleValueRanges : OutputKeys.valueRanges
                try keys(values, allowed: OutputKeys.values, path: "values")
                try numbers(values, ranges: ranges, path: "values")
                adjustment.values = linkValues(values)
            }
            if let raw = item["effects"] {
                guard let effects = raw as? [Any], effects.count <= 16 else { throw failure("effects: expected at most 16 entries") }
                for rawEffect in effects {
                    var effect = try object(rawEffect, path: "effects")
                    try keys(effect, allowed: ["id", "kind", "fixedEdge", "isEnabled", "strength", "scale", "direction", "cycles", "centerX", "centerY", "reversed", "values"], path: "effects")
                    guard let text = effect.removeValue(forKey: "id") as? String, let effectID = UUID(uuidString: text),
                          layer.effects.contains(where: { $0.id == effectID }), adjustment.effects[effectID] == nil
                    else { throw failure("effects.id: expected a unique effect ID from this target") }
                    try numbers(effect, ranges: ["strength": 0 ... 1, "scale": 0 ... 1, "direction": -3600 ... 3600,
                                                 "cycles": 1 ... 12, "centerX": 0 ... 1, "centerY": 0 ... 1], path: "effects")
                    try integers(effect, names: ["cycles"], path: "effects")
                    try booleans(effect, names: ["isEnabled", "reversed"], path: "effects")
                    try choices(effect, values: ["kind": Set(SceneEffectKind.allCases.map(\.rawValue)), "fixedEdge": Set(SceneFixedEdge.allCases.map(\.rawValue))], path: "effects")
                    if let rawValues = effect["values"] {
                        let values = try object(rawValues, path: "effects.values")
                        guard values.count <= 64 else { throw failure("effects.values: expected at most 64 entries") }
                        try numbers(values, ranges: Dictionary(uniqueKeysWithValues: values.keys.map { ($0, -1e9 ... 1e9) }), path: "effects.values")
                    }
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
            if let raw = item["text"] { adjustment.text = try readText(raw, layer: layer) }
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

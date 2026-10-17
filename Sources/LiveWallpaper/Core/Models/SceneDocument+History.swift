import Foundation

extension SceneDocument {
    /// The file painted for an effect (or a particle layer's own area, whose effect id
    /// is the layer's). The outer nil means the layer or effect no longer exists.
    func paintFile(layerID: UUID, effectID: UUID, kind: ScenePaintOverride.Target) -> String?? {
        guard let layer = layers.first(where: { $0.id == layerID }) else {
            return nil
        }
        if effectID == layerID, let particles = layer.particles {
            return .some(particles.maskFile)
        }
        guard let effect = layer.effects.first(where: { $0.id == effectID }) else {
            return nil
        }
        return .some(effect.paintFile(kind))
    }

    /// Scripts can read target names and locks, so these affect baking while a script can run.
    func rendersSame(as other: SceneDocument) -> Bool {
        func drawn(_ document: SceneDocument) -> SceneDocument {
            var copy = document
            for index in copy.layers.indices {
                if !copy.scripts.contains(where: \.canRun) {
                    copy.layers[index].name = ""
                    copy.layers[index].isLocked = false
                }
            }
            for index in copy.scripts.indices { copy.scripts[index].name = "" }
            return copy
        }
        return drawn(self) == drawn(other)
    }

    /// Names the fields that differ from `other`, e.g. "layers.1.opacity". A slider
    /// drag keeps producing the same key, which is what lets the history merge it
    /// into one step whichever control produced it.
    func changeKey(from other: SceneDocument) throws -> String {
        var paths: [String] = []
        // Encoding the whole scene on every slider tick cost most of an edit's main
        // thread time with many layers, so only the layers that differ are diffed.
        if layers.count == other.layers.count {
            var withoutLayers = self
            var otherWithoutLayers = other
            withoutLayers.layers = []
            otherWithoutLayers.layers = []
            if withoutLayers != otherWithoutLayers {
                try Self.collectChanges(
                    Self.jsonObject(otherWithoutLayers), Self.jsonObject(withoutLayers), path: "", into: &paths
                )
            }
            for index in layers.indices where layers[index] != other.layers[index] {
                try Self.collectChanges(
                    Self.jsonObject(other.layers[index]), Self.jsonObject(layers[index]),
                    path: "layers.\(index)", into: &paths
                )
            }
        } else {
            try Self.collectChanges(Self.jsonObject(other), Self.jsonObject(self), path: "", into: &paths)
        }
        return paths.sorted().joined(separator: ",")
    }

    private static func jsonObject(_ value: some Encodable) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private static func collectChanges(_ old: Any?, _ new: Any?, path: String, into paths: inout [String]) {
        switch (old, new) {
        case let (old as [String: Any], new as [String: Any]):
            for key in Set(old.keys).union(new.keys) {
                collectChanges(old[key], new[key], path: path.isEmpty ? key : "\(path).\(key)", into: &paths)
            }
        case let (old as [Any], new as [Any]) where old.count == new.count:
            for index in old.indices {
                collectChanges(old[index], new[index], path: "\(path).\(index)", into: &paths)
            }
        case let (old as NSObject, new as NSObject) where old.isEqual(new):
            return
        case (nil, nil):
            return
        default:
            paths.append(path)
        }
    }
}

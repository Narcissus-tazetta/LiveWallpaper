import Foundation

extension ScenePreset {
    /// `localize` turns the Japanese source strings into the app's language.
    static func builtIn(_ kind: BuiltIn, localize: (String) -> String) -> ScenePreset {
        func particles(_ preset: SceneParticlePreset, name: String, _ change: (inout SceneLayer) -> Void = { _ in }) -> SceneLayer {
            var particles = SceneParticles(preset: preset)
            // A fixed pattern, so trying the preset again shows the same picture.
            particles.seed = 4217
            var layer = SceneLayer(name: localize(name), particles: particles)
            change(&layer)
            return layer
        }

        switch kind {
        case .depthFireflies:
            var preset = ScenePreset(name: localize("奥行き＋ホタル"), builtIn: kind, effects: [])
            preset.wantsDepth = true
            preset.depthStrength = 0.5
            preset.depthFollowsCursor = true
            preset.depthAutoMotion = 0.35
            preset.particleLayers = [particles(.fireflies, name: "ホタル")]
            return preset

        case .hairSway:
            var sway = SceneEffect(kind: .sway)
            sway.strength = 0.35
            sway.scale = 0.35
            sway.cycles = 2
            // Hair hangs from its roots: they stay put and the tips move most.
            sway.fixedEdge = .top
            return ScenePreset(
                name: localize("髪の揺れ"), builtIn: kind,
                effects: [ScenePresetEffect(sway, wantsMask: true, movesToOwnLayer: true)]
            )

        case .waterSurface:
            var flow = SceneEffect(kind: .waterFlow)
            flow.strength = 0.5
            // Only where a direction is drawn moves, so drawing is the area too.
            return ScenePreset(name: localize("水面の流れ"), builtIn: kind, effects: [ScenePresetEffect(flow, wantsMask: false)])

        case .driftingClouds:
            var clouds = SceneEffect(kind: .drift)
            clouds.strength = 0.5
            clouds.direction = 0
            return ScenePreset(name: localize("流れる雲"), builtIn: kind, effects: [ScenePresetEffect(clouds, wantsMask: true)])

        case .cherryBlossoms:
            var preset = ScenePreset(name: localize("桜吹雪"), builtIn: kind, effects: [])
            preset.particleLayers = [particles(.petals, name: "花びら") { $0.particles?.cursorMode = .repel }]
            return preset

        case .fallingSnow:
            var preset = ScenePreset(name: localize("降りしきる雪"), builtIn: kind, effects: [])
            preset.particleLayers = [
                particles(.snow, name: "雪(遠く)") { layer in
                    layer.particles?.count = 260
                    layer.particles?.size = 0.2
                    layer.particles?.opacity = 0.7
                },
                particles(.snow, name: "雪(近く)") { layer in
                    layer.particles?.count = 50
                    layer.particles?.size = 0.6
                    layer.particles?.cycles = 2
                    layer.particles?.seed = 977
                    layer.parallaxDepth = 0.6
                }
            ]
            return preset
        }
    }

    /// One line on what the preset does and what it suits.
    static func summary(of kind: BuiltIn) -> String {
        switch kind {
        case .depthFireflies:
            "奥行きを推定して手前と奥を別々に動かし、上にホタルを飛ばします。"
        case .hairSway:
            "塗った範囲を別のレイヤーにして、根元を残したまま風になびかせます。髪や草木に向いています。"
        case .waterSurface:
            "向きを描いた所を、その向きに流します。川や滝に向いています。"
        case .driftingClouds:
            "塗った範囲を、雲のように一方向へゆっくり流します。空に向いています。"
        case .cherryBlossoms:
            "花びらを舞わせます。花びらはカーソルを避けます。"
        case .fallingSnow:
            "遠くの細かい雪と近くの大きな雪を重ねます。近くの雪はカーソルに合わせて動きます。"
        }
    }
}

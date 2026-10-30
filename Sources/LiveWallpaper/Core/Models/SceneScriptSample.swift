import Foundation

enum SceneScriptSample: String, CaseIterable, Identifiable {
    case blank, master, motion, orbit, figureEight, breathing, stagger, bounce, noiseDrift, spin, curveMotion, crossfade
    case cursor, cursorTilt, cursorDistance, cursorMask
    case timeOfDay, dayVisibility, dayParticles
    case effects, effectOrbit, effectKinds, particles, palette, particleWind, particleCursor, depthPulse, blendCycle
    case audioPulse, audioColor
    var id: String { rawValue }
    var usesTime: Bool { ![.blank, .audioPulse, .audioColor, .cursor, .cursorTilt, .cursorDistance, .cursorMask, .timeOfDay, .dayVisibility, .dayParticles, .particleCursor].contains(self) }
    var usesCursor: Bool { [.master, .cursor, .cursorTilt, .cursorDistance, .cursorMask, .particleCursor].contains(self) }
    var readsAudio: Bool { [.audioPulse, .audioColor].contains(self) }
    var usesTimeOfDay: Bool { [.master, .timeOfDay, .dayVisibility, .dayParticles].contains(self) }
    var title: String {
        switch self {
        case .blank: "空白のスクリプト"
        case .master: "1本で全体を管理"
        case .motion: "周期運動"
        case .orbit: "円・楕円の軌道"
        case .figureEight: "八の字の軌道"
        case .breathing: "呼吸する拡大縮小"
        case .stagger: "順番に揺れるレイヤー"
        case .bounce: "弾む動き"
        case .noiseDrift: "ノイズで漂う動き"
        case .spin: "一周する回転"
        case .curveMotion: "コードのキーフレーム"
        case .crossfade: "レイヤーのクロスフェード"
        case .cursor: "カーソルで連動"
        case .cursorTilt: "カーソルで傾ける"
        case .cursorDistance: "カーソルとの距離で拡大"
        case .cursorMask: "カーソルの周りを透かす"
        case .timeOfDay: "時間帯で色を変更"
        case .dayVisibility: "夜だけ表示"
        case .dayParticles: "時間帯で粒子を変更"
        case .effects: "エフェクトを切り替え"
        case .effectOrbit: "エフェクトの中心を動かす"
        case .effectKinds: "エフェクトの種類を切り替え"
        case .particles: "粒子の色と動き"
        case .palette: "粒子のグラデーション"
        case .particleWind: "粒子に風を吹かせる"
        case .particleCursor: "粒子をカーソルに集める"
        case .depthPulse: "立体感をゆっくり変える"
        case .blendCycle: "合成モードを切り替え"
        case .audioPulse: "音に合わせて拡大"
        case .audioColor: "音に合わせて粒子の色を変更"
        }
    }
    var source: String {
        switch self {
        case .master:
            """
            function update(ctx) {
              const night = ctx.timeOfDay === 'night';
              return ctx.targets.map((layer, i) => {
                const result = {
                  id: layer.id,
                  values: {
                    offsetY: wave(ctx.phase, 1, i * 0.1) * ctx.params.amount,
                    offsetX: ctx.cursor.x * ctx.params.amount,
                    warmth: night ? -0.1 : 0.1
                  },
                  effects: layer.effects.map(effect => ({
                    id: effect.id,
                    strength: (wave(ctx.phase) + 1) * 0.25
                  }))
                };
                if (layer.particles) {
                  result.particles = {
                    color: color.hsv(ctx.phase, 0.5, 1),
                    opacity: night ? 0.8 : 0.5,
                    cursorMode: ctx.cursorActive ? 'attract' : 'none'
                  };
                }
                return result;
              });
            }
            """
        case .blank:
            """
            function update(ctx) {
              return [];
            }
            """
        case .orbit:
            mapped("const p = path.ellipse(ctx.phase, ctx.params.amount, ctx.params.amount * 0.6);", "values: { offsetX: p.x, offsetY: p.y }")
        case .figureEight:
            mapped("const p = vec.mul(path.lissajous(ctx.phase, 1, 2, 0), ctx.params.amount);", "values: { offsetX: p.x, offsetY: p.y }")
        case .breathing:
            mapped("const t = (wave(ctx.phase) + 1) / 2;", "values: { scale: 1 + ease(t, 'inOutSine') * ctx.params.amount }")
        case .stagger:
            mapped("", "values: { offsetY: wave(ctx.phase, 1, i * 0.1) * ctx.params.amount }")
        case .bounce:
            mapped("const t = ease(pingPong(ctx.phase * 2), 'outBounce');", "values: { offsetY: -t * ctx.params.amount }")
        case .noiseDrift:
            mapped("const p = path.circle(ctx.phase);", "values: { offsetX: (fbm2(p.x, p.y, hash(layer.id)) - 0.5) * ctx.params.amount }")
        case .spin:
            mapped("", "values: { rotation: ctx.phase * 360 }")
        case .curveMotion:
            mapped("const t = curve(ctx.phase, [{time:0,value:0,ease:'inOutCubic'}, {time:0.5,value:1,ease:'smooth'}, {time:1,value:0}]);", "values: { offsetX: t * ctx.params.amount }")
        case .crossfade:
            mapped("", "values: { opacity: (wave(ctx.phase, 1, i * 0.5) + 1) / 2 }")
        case .cursorTilt:
            mapped("", "values: { rotation: ctx.cursor.x * 12, offsetY: ctx.cursor.y * ctx.params.amount }")
        case .cursorDistance:
            mapped("const distance = vec.distance(ctx.cursor, vec.of());", "values: { scale: 1 + (1 - clamp(distance, 0, 1)) * ctx.params.amount }")
        case .cursorMask:
            mapped("", "appearance: { cursorMask: { mode: 'hide', radius: 0.15, softness: 0.5 } }")
        case .dayVisibility:
            mapped("", "appearance: { isVisible: ctx.timeOfDay === 'night' }")
        case .dayParticles:
            mapped("const night = ctx.timeOfDay === 'night';", "appearance: { blendMode: night ? 'add' : 'normal' }, particles: { preset: night ? 'stars' : 'snow', opacity: night ? 0.8 : 0.4 }", particlesOnly: true)
        case .effectOrbit:
            mapped("const p = path.circle(ctx.phase, 0.2);", "effects: layer.effects.map(e => ({ id:e.id, centerX:0.5+p.x, centerY:0.5+p.y }))")
        case .effectKinds:
            mapped("const kind = ['waves','ripple','twirl','sway'][Math.floor(ctx.phase * 4)];", "effects: layer.effects.map(e => ({ id:e.id, kind, strength:0.25 }))")
        case .palette:
            mapped("const t = (wave(ctx.phase) + 1) / 2;", "particles: { color: color.mix(color.hex('#FFAA44'), color.hex('#4488FF'), t) }", particlesOnly: true)
        case .particleWind:
            mapped("", "particles: { direction: 270 + wave(ctx.phase) * 45, sway: 0.6, seed: hash(layer.id) % 10000 }", particlesOnly: true)
        case .particleCursor:
            mapped("", "particles: { cursorMode: 'attract' }", particlesOnly: true)
        case .depthPulse:
            """
            function update(ctx) {
              return ctx.targets.filter(layer => layer.appearance.hasDepthMap).map(layer => ({
                id: layer.id,
                appearance: { depthStrength: (wave(ctx.phase) + 1) * 0.4, depthAutoMotion: 0.3 }
              }));
            }
            """
        case .audioPulse:
            """
            function update(ctx) {
              // ctx.audio is null while nothing plays or the sound reaction is not allowed.
              const low = ctx.audio ? ctx.audio.left.slice(0, 8).reduce((sum, v) => sum + v, 0) / 8 : 0;
              return ctx.targets.map(layer => ({
                id: layer.id,
                values: { scale: 1 + low * ctx.params.amount * 4 }
              }));
            }
            """
        case .audioColor:
            """
            function update(ctx) {
              const high = ctx.audio ? ctx.audio.left.slice(32, 64).reduce((sum, v) => sum + v, 0) / 32 : 0;
              return ctx.targets.filter(layer => layer.particles).map(layer => ({
                id: layer.id,
                particles: { color: hsv(0.55 + high * 0.4, 0.7, 1), opacity: 0.4 + high * 0.6 }
              }));
            }
            """
        case .blendCycle:
            mapped("const blendMode = ['normal','screen','add'][Math.floor(ctx.phase * 3)];", "appearance: { blendMode }")
        case .motion:
            """
            function update(ctx) {
              return ctx.targets.map((layer, i) => ({
                id: layer.id,
                values: {
                  offsetY: wave(ctx.phase, ctx.params.cycles, i * 0.1) * ctx.params.amount,
                  rotation: wave(ctx.phase) * 5
                }
              }));
            }
            """
        case .cursor:
            """
            function update(ctx) {
              return ctx.targets.map((layer, i) => ({
                id: layer.id,
                values: {
                  offsetX: ctx.cursor.x * ctx.params.amount * (i + 1),
                  offsetY: ctx.cursor.y * ctx.params.amount * (i + 1)
                }
              }));
            }
            """
        case .timeOfDay:
            """
            function update(ctx) {
              const looks = {
                morning: { brightness: 0.1, warmth: 0.2 },
                day: {},
                evening: { brightness: -0.1, warmth: 0.5 },
                night: { brightness: -0.4, warmth: -0.3 }
              };
              return ctx.targets.map(layer => ({ id: layer.id, values: looks[ctx.timeOfDay] }));
            }
            """
        case .effects:
            """
            function update(ctx) {
              return ctx.targets.map(layer => ({
                id: layer.id,
                effects: layer.effects.map(effect => ({
                  id: effect.id,
                  isEnabled: ctx.phase < 0.5,
                  strength: (wave(ctx.phase) + 1) * 0.25
                }))
              }));
            }
            """
        case .particles:
            """
            function update(ctx) {
              return ctx.targets.filter(layer => layer.particles).map(layer => ({
                id: layer.id,
                particles: {
                  opacity: 0.6 + wave(ctx.phase) * 0.3,
                  direction: 270 + wave(ctx.phase) * 20,
                  color: { red: 1, green: 0.6 + wave(ctx.phase) * 0.3, blue: 0.4, alpha: 1 }
                }
              }));
            }
            """
        }
    }

    private func mapped(_ setup: String, _ output: String, particlesOnly: Bool = false) -> String {
        """
        function update(ctx) {
          \(setup)
          return ctx.targets\(particlesOnly ? ".filter(layer => layer.particles)" : "").map((layer, i) => ({
            id: layer.id,
            \(output)
          }));
        }
        """
    }
}

import Foundation
import simd

/// The renderer selects the formula by position, so new cases go at the end. The
/// layer's colour blends with what is below, weighted by its alpha, except `minimum`
/// and `maximum`, which take effect over the whole picture, transparent parts included.
enum SceneBlendMode: String, Codable, CaseIterable {
    case normal
    case multiply
    case screen
    case overlay
    case add
    case darken
    case colorBurn
    case subtract
    case minimum
    case lighten
    case colorDodge
    case maximum
    case softLight
    case hardLight
    case vividLight
    case linearLight
    case pinLight
    case hardMix
    case difference
    case exclusion
    case reflect
    case glow
    case phoenix
    case average
    case negation
    case hue
    case saturation
    case color
    case luminosity
    case tint
    /// Below plus the colour times alpha, not clamped.
    case plus
    /// Below plus below times the colour.
    case brighten
}

/// Cuts the layer around the cursor (X-ray): `hide` makes a hole that shows the
/// layers below, `show` draws the layer only around the cursor.
enum SceneCursorMaskMode: String, Codable, CaseIterable {
    case hide
    case show
}

struct SceneCursorMask: Codable, Equatable {
    var mode: SceneCursorMaskMode = .hide
    /// Fraction of the canvas's shorter side.
    var radius: Double = 0.15
    /// Fraction of the radius that fades out.
    var softness: Double = 0.4

    init() {}

    // Each field falls back on its own, so a scene saved by a later version still
    // opens: scenes will travel in packages.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SceneCursorMask()
        mode = (try? container.decode(SceneCursorMaskMode.self, forKey: .mode)) ?? defaults.mode
        radius = (try? container.decode(Double.self, forKey: .radius)) ?? defaults.radius
        softness = (try? container.decode(Double.self, forKey: .softness)) ?? defaults.softness
    }
}

enum SceneEffectKind: String, Codable, CaseIterable {
    case shake
    case sway
    case swing
    case waves
    case ripple
    case waterFlow
    case scroll
    case cloudMotion
    case spin
    case twirl
    case pulse
    case puppet
    /// Moves the picture one way and fades between two offset copies, like the water
    /// flow with one direction everywhere: clouds drifting, mist.
    case drift
    /// Waves travelling across the picture at a real speed, set in physical units
    /// (`SceneEffect.values`, keys in SceneEffect.WaveKey).
    case travelingWaves
    /// Each pixel swings back and forth along its own vector of a flow map, at a
    /// real speed (`SceneEffect.values`, keys in SceneEffect.FlowShakeKey).
    case flowShake
    /// The picture streams along a flow map, two staggered pairs of copies hiding
    /// each reset, with a pattern image deciding which pair shows where
    /// (SceneEffect.FlowMapKey).
    case flowMap
    /// Two scrolling copies of a tiling normal map bend the picture like a water
    /// surface (SceneEffect.RipplesKey).
    case normalRipples
    /// A tiling noise image drifting sideways pushes the picture one way and back
    /// (SceneEffect.NoiseDriftKey).
    case noiseDrift
    /// Sums of slow sines, offset per pixel by a tiling noise image, sway the
    /// picture like foliage (SceneEffect.NoiseSwayKey).
    case noiseSway
    /// The picture pulses between two tints, mixed by a blend mode, optionally its
    /// opacity too (SceneEffect.PulseKey).
    case pulseBlend
    /// Scrolls the picture, wrapping, at a set speed per axis (SceneEffect.ScrollKey).
    case uvScroll
    /// Bends the part of the picture beside an axis back and forth, like a flag on
    /// a pole (SceneEffect.AxisSwingKey).
    case axisSwing
    case opacityMask
    case shader

    /// Runs on seconds rather than whole repeats per loop: drawn live it keeps its
    /// own speed, and only a baked video rounds the speed to fit the loop.
    var runsOnRealTime: Bool {
        [.travelingWaves, .flowShake, .flowMap, .normalRipples, .noiseDrift, .noiseSway, .pulseBlend, .uvScroll, .axisSwing, .shader]
            .contains(self)
    }

    /// Uses `centerX`/`centerY` (picked on the preview).
    var usesCenter: Bool {
        [.swing, .ripple, .spin, .twirl].contains(self)
    }

    var usesDirection: Bool {
        [.shake, .sway, .waves, .scroll, .drift].contains(self)
    }

    /// Its speed is a whole number of repeats per loop (`cycles`).
    var usesCycles: Bool {
        !runsOnRealTime && self != .opacityMask
    }

    /// Can hold one side still and move more toward the other (hair, leaves, cloth).
    var usesFixedEdge: Bool {
        [.shake, .sway, .waves, .cloudMotion].contains(self)
    }

    /// Moves the picture, so moving a painted area of it as its own layer lets its
    /// outline move instead of only what is inside.
    var canMoveOnItsOwnLayer: Bool {
        ![.pulse, .opacityMask, .shader].contains(self)
    }

    /// Uses `scale`: wavelength, noise size or radius depending on the effect.
    var usesScale: Bool {
        [.sway, .waves, .ripple, .cloudMotion, .twirl, .puppet].contains(self)
    }

    var usesStrength: Bool {
        ![.scroll, .spin, .puppet, .opacityMask].contains(self) && !runsOnRealTime
    }
}

/// The side of an effect's area that stays still.
enum SceneFixedEdge: String, Codable, CaseIterable {
    case none
    case top
    case bottom
    case left
    case right
}

/// A rectangle in layer UV (origin top-left).
struct SceneAreaBounds: Codable, Equatable {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double

    static let whole = SceneAreaBounds(minX: 0, minY: 0, maxX: 1, maxY: 1)

    /// The box around the pixels at or above `threshold` in a one-byte-per-pixel
    /// image; nil when there are none.
    static func of(_ bytes: [UInt8], width: Int, height: Int, threshold: UInt8 = 8) -> SceneAreaBounds? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0 ..< height {
            for x in 0 ..< width where bytes[y * width + x] >= threshold {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else {
            return nil
        }
        return SceneAreaBounds(
            minX: Double(minX) / Double(width), minY: Double(minY) / Double(height),
            maxX: Double(maxX + 1) / Double(width), maxY: Double(maxY + 1) / Double(height)
        )
    }
}

/// A pin of the puppet effect. Anchors hold the picture still around them; the
/// others swing it back and forth.
struct ScenePin: Codable, Equatable, Identifiable {
    static let maximumCount = 16

    var id = UUID()
    /// Layer UV (origin top-left).
    var x: Double
    var y: Double
    var isAnchor: Bool
    /// 0...1
    var amount = 0.5
    /// Degrees, 0 = right, counter-clockwise.
    var direction: Double = 0
    /// 0..<1: where in its swing the pin starts, so pins can move out of step.
    var phase: Double = 0

    init(x: Double, y: Double, isAnchor: Bool) {
        self.x = x
        self.y = y
        self.isAnchor = isAnchor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        x = (try? container.decode(Double.self, forKey: .x)) ?? 0.5
        y = (try? container.decode(Double.self, forKey: .y)) ?? 0.5
        isAnchor = (try? container.decode(Bool.self, forKey: .isAnchor)) ?? true
        amount = (try? container.decode(Double.self, forKey: .amount)) ?? 0.5
        direction = (try? container.decode(Double.self, forKey: .direction)) ?? 0
        phase = (try? container.decode(Double.self, forKey: .phase)) ?? 0
    }
}

/// One animated effect on a layer. Every motion repeats a whole number of times
/// (`cycles`) per scene loop, which is what makes the baked video loop seamlessly.
struct SceneEffect: Codable, Equatable, Identifiable {
    static let cyclesRange = 1 ... 12

    var id = UUID()
    var kind: SceneEffectKind
    var renderGraph: SceneRenderGraph?
    var isEnabled = true
    var cycles = 1
    /// 0...1
    var strength = 0.5
    /// 0...1
    var scale = 0.5
    /// Degrees, 0 = right, counter-clockwise.
    var direction: Double = 0
    /// Layer UV (origin top-left).
    var centerX = 0.5
    var centerY = 0.5
    var reversed = false
    /// Grayscale image in the scene folder limiting where the effect applies;
    /// nil applies it to the whole layer.
    var maskFile: String?
    /// Water flow only: direction per pixel, red/green 0.5 meaning still.
    var flowFile: String?
    /// Puppet only.
    var pins: [ScenePin] = []
    /// The settings of effects that run on real time, in their own units.
    var values: [String: Double] = [:]
    /// Grey image in the scene folder delaying each pixel's motion (white = a full
    /// period later); travelling waves and flow shake only.
    var timeOffsetFile: String?
    /// A tiling image in the scene folder some real-time effects read: noise, a
    /// normal map, a flow phase. Read repeating unless `values["patternClamps"]`.
    var patternFile: String?
    var fixedEdge: SceneFixedEdge = .none
    /// Where the effect's area is, for `fixedEdge`: the painted area, or a cut-out's
    /// picture. nil means the whole layer.
    var areaBounds: SceneAreaBounds?

    init(kind: SceneEffectKind) {
        self.kind = kind
        if kind == .waterFlow {
            cycles = 4
        }
        if kind == .puppet {
            scale = 0.3
        }
        if kind == .drift {
            cycles = 2
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(SceneEffectKind.self, forKey: .kind)
        renderGraph = try container.decodeIfPresent(SceneRenderGraph.self, forKey: .renderGraph)
        let defaults = SceneEffect(kind: kind)
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? defaults.isEnabled
        cycles = (try? container.decode(Int.self, forKey: .cycles)) ?? defaults.cycles
        strength = (try? container.decode(Double.self, forKey: .strength)) ?? defaults.strength
        scale = (try? container.decode(Double.self, forKey: .scale)) ?? defaults.scale
        direction = (try? container.decode(Double.self, forKey: .direction)) ?? defaults.direction
        centerX = (try? container.decode(Double.self, forKey: .centerX)) ?? defaults.centerX
        centerY = (try? container.decode(Double.self, forKey: .centerY)) ?? defaults.centerY
        reversed = (try? container.decode(Bool.self, forKey: .reversed)) ?? defaults.reversed
        maskFile = try? container.decodeIfPresent(String.self, forKey: .maskFile)
        flowFile = try? container.decodeIfPresent(String.self, forKey: .flowFile)
        pins = (try? container.decode([ScenePin].self, forKey: .pins)) ?? []
        values = (try? container.decode([String: Double].self, forKey: .values)) ?? [:]
        timeOffsetFile = try? container.decodeIfPresent(String.self, forKey: .timeOffsetFile)
        patternFile = try? container.decodeIfPresent(String.self, forKey: .patternFile)
        fixedEdge = (try? container.decode(SceneFixedEdge.self, forKey: .fixedEdge)) ?? .none
        areaBounds = try? container.decodeIfPresent(SceneAreaBounds.self, forKey: .areaBounds)
    }
}

extension SceneEffect {
    /// Travelling waves: phase = time × speed + (uv · direction) × scale, and the
    /// picture moves sideways by sin(phase)^exponent × amplitude².
    enum WaveKey {
        /// Radians per second.
        static let speed = "speed"
        /// Radians per unit of layer UV along the direction.
        static let scale = "scale"
        static let amplitude = "amplitude"
        static let exponent = "exponent"
        /// Radians turning (0, 1) in layer UV (x right, y down) by the usual 2D
        /// rotation: 0 runs down the picture.
        static let angle = "angle"
        /// 1 multiplies in a second wave with the keys below.
        static let dual = "dual"
        static let speed2 = "speed2"
        static let scale2 = "scale2"
        /// Seconds the second wave runs ahead.
        static let offset2 = "offset2"
        static let exponent2 = "exponent2"
        static let angle2 = "angle2"
    }

    /// Flow shake: offset = sin(time × speed), shaped by friction and bounds, moves
    /// each pixel by offset × amplitude² along its flow vector.
    enum FlowShakeKey {
        /// Radians per second.
        static let speed = "speed"
        static let amplitude = "amplitude"
        /// Exponents easing the swing on its way out (x) and back (y); 1 is a sine.
        static let frictionX = "frictionX"
        static let frictionY = "frictionY"
        /// The part of the swing (0...1) that is used, stretched to the whole range.
        static let boundsMin = "boundsMin"
        static let boundsMax = "boundsMax"
        /// 0 swings both ways, 1 only forward, 2 only back.
        static let side = "side"
        /// 1 sums four sines of unrelated speeds for an irregular swing.
        static let irregular = "irregular"
    }

    /// Flow map: cycle = fract(time × speed); the copies move by (cycle − ½) ×
    /// strength × 0.1 along the flow, crossfaded with `feather`.
    enum FlowMapKey {
        /// Cycles per second.
        static let speed = "speed"
        static let strength = "strength"
        static let feather = "feather"
        /// How many times the pattern repeats across the picture.
        static let phaseScale = "phaseScale"
    }

    /// Normal ripples: the map scrolls at animationSpeed² both ways plus the scroll,
    /// and moves the picture by its normal × strength².
    enum RipplesKey {
        static let animationSpeed = "animationSpeed"
        static let scale = "scale"
        static let scrollSpeed = "scrollSpeed"
        /// Radians turning (0, 1) in layer UV.
        static let scrollAngle = "scrollAngle"
        /// Vertical stretch of the map.
        static let ratio = "ratio"
        static let strength = "strength"
        /// 1 adds a highlight where the surface faces up and toward the top centre.
        static let specular = "specular"
        static let specularPower = "specularPower"
        static let specularStrength = "specularStrength"
        static let specularRed = "specularRed"
        static let specularGreen = "specularGreen"
        static let specularBlue = "specularBlue"
    }

    /// Noise drift: noise(uv × scale, x stretched by scaleX, + time × speed) moves
    /// the picture by (noise × 2 − 1) × amount across `angle`.
    enum NoiseDriftKey {
        /// Pattern widths per second.
        static let speed = "speed"
        static let scale = "scale"
        static let scaleX = "scaleX"
        static let amount = "amount"
        /// Radians; the motion runs across this direction.
        static let angle = "angle"
    }

    /// Noise sway: per-pixel phase from the pattern, four sines on each axis at
    /// fixed multiples of the speed, each sine raised to `power`.
    enum NoiseSwayKey {
        /// Radians per second.
        static let speed = "speed"
        static let strength = "strength"
        static let phase = "phase"
        static let power = "power"
        static let noiseScale = "noiseScale"
        /// Stretch between the axes.
        static let ratio = "ratio"
        static let angle = "angle"
    }

    /// Pulse: pulse = smoothstep(boundsMin, boundsMax, ½ + ½ sin(time × speed + phase
    /// − π/2)) × amount, plus noise, raised to `power`.
    enum PulseKey {
        static let speed = "speed"
        static let phase = "phase"
        static let amount = "amount"
        static let boundsMin = "boundsMin"
        static let boundsMax = "boundsMax"
        static let noiseSpeed = "noiseSpeed"
        static let noiseAmount = "noiseAmount"
        static let power = "power"
        /// Colour multipliers at no pulse and at full pulse.
        static let lowRed = "lowRed", lowGreen = "lowGreen", lowBlue = "lowBlue"
        static let highRed = "highRed", highGreen = "highGreen", highBlue = "highBlue"
        /// 0...32, see SceneRenderer's pulse blending.
        static let blendMode = "blendMode"
        /// 1 pulses the colour (on by default).
        static let pulsesColor = "pulsesColor"
        /// 1 also multiplies the opacity by the pulse.
        static let pulsesOpacity = "pulsesOpacity"
    }

    /// UV scroll: the picture moves by sign(speed) × speed² per second on each axis,
    /// repeated `repeatX` × `repeatY` times.
    enum ScrollKey {
        static let speedX = "speedX"
        static let speedY = "speedY"
        static let repeatX = "repeatX"
        static let repeatY = "repeatY"
    }

    /// Axis swing: the area within `size` of the axis from point 0 to point 1 bends
    /// by sin(time × speed + phase × 2π) × amount.
    enum AxisSwingKey {
        static let speed = "speed"
        static let phase = "phase"
        static let amount = "amount"
        /// Layer UV.
        static let x0 = "x0", y0 = "y0", x1 = "x1", y1 = "y1"
        static let size = "size"
        /// Where along the axis it pivots, 0...1.
        static let center = "center"
        static let feather = "feather"
        /// 1 bends both sides of the axis.
        static let doubleSided = "doubleSided"
        /// 1 adds noise from the pattern to the swing.
        static let noise = "noise"
        static let noiseSpeed = "noiseSpeed"
        static let noiseAmount = "noiseAmount"
    }

    /// Width over height of the picture as stored (with any padding), which some
    /// effects scale by. Defaults to the picture's own.
    static let textureAspectKey = "textureAspect"
    /// 1 reads the pattern clamped instead of repeating.
    static let patternClampsKey = "patternClamps"

    /// The file painted for `target`, if any.
    func paintFile(_ target: ScenePaintOverride.Target) -> String? {
        switch target {
        case .mask: maskFile
        case .flow: flowFile
        case .timeOffset: timeOffsetFile
        }
    }

    /// The value of `key`, or the effect's default for it.
    func value(_ key: String) -> Double {
        values[key] ?? Self.defaultValues(for: kind)[key] ?? 0
    }

    /// What real-time effects use for a value they were not given.
    static func defaultValues(for kind: SceneEffectKind) -> [String: Double] {
        switch kind {
        case .travelingWaves:
            typealias Key = WaveKey
            return [
                Key.speed: 5, Key.scale: 200, Key.amplitude: 0.1, Key.exponent: 1, Key.angle: 0, Key.dual: 0,
                Key.speed2: 3, Key.scale2: 66, Key.offset2: 0, Key.exponent2: 1, Key.angle2: 0
            ]
        case .flowShake:
            typealias Key = FlowShakeKey
            return [
                Key.speed: 1, Key.amplitude: 0.1, Key.frictionX: 1, Key.frictionY: 1, Key.boundsMin: 0, Key.boundsMax: 1,
                Key.side: 0, Key.irregular: 0
            ]
        case .flowMap:
            typealias Key = FlowMapKey
            return [Key.speed: 1, Key.strength: 1, Key.feather: 0.4, Key.phaseScale: 2]
        case .normalRipples:
            typealias Key = RipplesKey
            return [
                Key.animationSpeed: 0.15, Key.scale: 1, Key.scrollSpeed: 0, Key.scrollAngle: 0, Key.ratio: 1, Key.strength: 0.1,
                Key.specular: 0, Key.specularPower: 1, Key.specularStrength: 1, Key.specularRed: 1, Key.specularGreen: 1,
                Key.specularBlue: 1
            ]
        case .noiseDrift:
            typealias Key = NoiseDriftKey
            return [Key.speed: 0.02, Key.scale: 2, Key.scaleX: 0.5, Key.amount: 0.1, Key.angle: .pi / 2]
        case .noiseSway:
            typealias Key = NoiseSwayKey
            return [Key.speed: 5, Key.strength: 0.4, Key.phase: 0.5, Key.power: 1, Key.noiseScale: 0.05, Key.ratio: 0.3, Key.angle: 0]
        case .pulseBlend:
            typealias Key = PulseKey
            return [
                Key.speed: 3, Key.phase: 0, Key.amount: 1, Key.boundsMin: 0, Key.boundsMax: 1, Key.noiseSpeed: 0.5,
                Key.noiseAmount: 0, Key.power: 1, Key.lowRed: 1, Key.lowGreen: 1, Key.lowBlue: 1, Key.highRed: 1,
                Key.highGreen: 1, Key.highBlue: 1, Key.blendMode: 9, Key.pulsesColor: 1, Key.pulsesOpacity: 0
            ]
        case .uvScroll:
            typealias Key = ScrollKey
            return [Key.speedX: 0.2, Key.speedY: 0.2, Key.repeatX: 1, Key.repeatY: 1]
        case .opacityMask:
            return ["alpha": 1]
        case .axisSwing:
            typealias Key = AxisSwingKey
            return [
                Key.speed: 2, Key.phase: 0, Key.amount: 0.2, Key.x0: 0.25, Key.y0: 0.5, Key.x1: 0.75, Key.y1: 0.5,
                Key.size: 0.4, Key.center: 0.5, Key.feather: 0.01, Key.doubleSided: 0, Key.noise: 0, Key.noiseSpeed: 0.15,
                Key.noiseAmount: 0.2
            ]
        default:
            return [:]
        }
    }
}

/// Where a layer sits on the canvas, on top of its aspect-fit placement.
struct SceneTransform: Codable, Equatable {
    static let scaleRange = 0.1 ... 5.0

    /// Fractions of the canvas width/height; +x right, +y down.
    var offsetX: Double = 0
    var offsetY: Double = 0
    var scale: Double = 1
    var scaleY: Double?
    /// Degrees, clockwise.
    var rotation: Double = 0

    static let identity = SceneTransform()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        offsetX = (try? container.decode(Double.self, forKey: .offsetX)) ?? 0
        offsetY = (try? container.decode(Double.self, forKey: .offsetY)) ?? 0
        scale = (try? container.decode(Double.self, forKey: .scale)) ?? 1
        scaleY = try? container.decodeIfPresent(Double.self, forKey: .scaleY)
        rotation = (try? container.decode(Double.self, forKey: .rotation)) ?? 0
    }

    func interpolated(to other: SceneTransform, _ t: Double) -> SceneTransform {
        var result = SceneTransform()
        result.offsetX = offsetX + (other.offsetX - offsetX) * t
        result.offsetY = offsetY + (other.offsetY - offsetY) * t
        // Scale is interpolated in log space so a zoom feels even.
        result.scale = exp(log(max(scale, 0.01)) + (log(max(other.scale, 0.01)) - log(max(scale, 0.01))) * t)
        if scaleY != nil || other.scaleY != nil {
            let sy0 = scaleY ?? scale, sy1 = other.scaleY ?? other.scale
            result.scaleY = exp(log(max(sy0, 0.01)) + (log(max(sy1, 0.01)) - log(max(sy0, 0.01))) * t)
        }
        result.rotation = rotation + (other.rotation - rotation) * t
        return result
    }
}

/// A pose of the layer at a point of the loop. With two or more keyframes the layer
/// moves through them in time order and from the last back to the first, so the
/// motion loops.
struct SceneKeyframe: Codable, Equatable, Identifiable {
    var id = UUID()
    /// 0..<1 of the loop.
    var time: Double
    var transform: SceneTransform
    var opacity: Double = 1

    init(time: Double, transform: SceneTransform, opacity: Double = 1) {
        self.time = time
        self.transform = transform
        self.opacity = opacity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        time = (try? container.decode(Double.self, forKey: .time)) ?? 0
        transform = (try? container.decode(SceneTransform.self, forKey: .transform)) ?? .identity
        opacity = (try? container.decode(Double.self, forKey: .opacity)) ?? 1
    }
}

/// A movement recorded from another format: poses at times since the scene started,
/// followed in straight lines. Past the last pose it plays on from `loopStart`, or
/// rests on the last pose when there is none. It replaces the layer's placement,
/// keyframes and opacity factor.
struct SceneMotion: Codable, Equatable {
    struct Sample: Codable, Equatable {
        /// Seconds since the scene started.
        var time: Double
        var transform: SceneTransform
        var opacity: Double = 1

        init(time: Double, transform: SceneTransform, opacity: Double = 1) {
            self.time = time
            self.transform = transform
            self.opacity = opacity
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            time = try container.decode(Double.self, forKey: .time)
            transform = (try? container.decode(SceneTransform.self, forKey: .transform)) ?? .identity
            opacity = (try? container.decode(Double.self, forKey: .opacity)) ?? 1
        }
    }

    /// In time order.
    var samples: [Sample]
    var loopStart: Double?

    var duration: Double {
        samples.last?.time ?? 0
    }

    func pose(at time: Double) -> (transform: SceneTransform, opacity: Double) {
        guard let first = samples.first, let last = samples.last else {
            return (.identity, 1)
        }
        var t = max(time, 0)
        if t > last.time {
            guard let loopStart, last.time - loopStart > 1e-9 else {
                return (last.transform, last.opacity)
            }
            t = loopStart + (t - loopStart).truncatingRemainder(dividingBy: last.time - loopStart)
        }
        if t <= first.time {
            return (first.transform, first.opacity)
        }
        // The last sample at or before t.
        var low = 0
        var high = samples.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if samples[mid].time <= t { low = mid } else { high = mid - 1 }
        }
        guard low + 1 < samples.count else {
            return (last.transform, last.opacity)
        }
        let a = samples[low], b = samples[low + 1]
        let span = b.time - a.time
        let f = span > 1e-12 ? (t - a.time) / span : 1
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * f }
        var transform = SceneTransform()
        transform.offsetX = mix(a.transform.offsetX, b.transform.offsetX)
        transform.offsetY = mix(a.transform.offsetY, b.transform.offsetY)
        transform.scale = mix(a.transform.scale, b.transform.scale)
        if a.transform.scaleY != nil || b.transform.scaleY != nil {
            transform.scaleY = mix(a.transform.scaleY ?? a.transform.scale, b.transform.scaleY ?? b.transform.scale)
        }
        transform.rotation = mix(a.transform.rotation, b.transform.rotation)
        return (transform, mix(a.opacity, b.opacity))
    }
}

enum SceneLayerKind: String, Codable {
    case image
    case particles
    case text
    /// A solid model the scene places, seen through its camera.
    case model
}

/// A solid model: one shape, drawn with the scene's mesh material at `material`.
struct SceneStaticModel: Codable, Equatable {
    var material: Int
    /// Bit i set when the vertices hold `Semantic.allCases[i]`.
    var components: UInt32
    /// Little-endian 32-bit floats.
    var vertices: Data
    /// Little-endian 32-bit vertex indices, three to a triangle.
    var indices: Data

    private var floatsPerVertex: Int {
        SceneRenderGraph.Attribute.Semantic.allCases.enumerated()
            .reduce(0) { $0 + (components & (1 << UInt32($1.offset)) != 0 ? $1.element.floats : 0) }
    }

    var isValid: Bool {
        let stride = floatsPerVertex
        guard stride > 0, vertices.count % (stride * 4) == 0, indices.count % 12 == 0 else { return false }
        let count = UInt32(vertices.count / (stride * 4))
        return indices.withUnsafeBytes { bytes in
            (0 ..< indices.count / 4).allSatisfy { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self).littleEndian < count }
        }
    }

    var shape: SceneModelLayerFrame.Shape {
        let floats = vertices.withUnsafeBytes { bytes in
            (0 ..< vertices.count / 4).map { Float(bitPattern: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self).littleEndian) }
        }
        let triangles = indices.withUnsafeBytes { bytes in
            (0 ..< indices.count / 4).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self).littleEndian }
        }
        return SceneModelLayerFrame.Shape(material: material, components: components, vertices: floats, indices: triangles)
    }
}

enum SceneParticlePreset: String, Codable, CaseIterable {
    case snow
    case rain
    case petals
    case fireflies
    case dust
    case embers
    case bubbles
    case stars

    /// Glowing particles pile up their light where they overlap; the rest cover
    /// each other.
    var isAdditive: Bool {
        [.fireflies, .dust, .embers, .stars].contains(self)
    }

    /// Stars twinkle in place.
    var travels: Bool {
        self != .stars
    }
}

enum SceneParticleCursorMode: String, Codable, CaseIterable {
    case none
    case repel
    case attract
}

/// A layer of particles. Every particle's position is a function of its index and
/// the loop phase only (no simulation state), so any frame can be drawn on its own
/// and the loop is seamless: each particle crosses the canvas `cycles` times.
struct SceneParticles: Codable, Equatable {
    static let countRange = 5 ... 2000

    var preset: SceneParticlePreset
    var count: Int
    /// 0...1
    var size: Double
    var cycles: Int
    /// Degrees, 0 = right, counter-clockwise (270 falls straight down).
    var direction: Double
    /// 0...1, side-to-side drift.
    var sway: Double
    var color: RGBAColor
    /// 0...1
    var opacity: Double = 1
    var cursorMode: SceneParticleCursorMode = .none
    /// Grayscale image limiting where particles show; nil shows them everywhere.
    var maskFile: String?
    /// Varies the pattern between layers of the same preset.
    var seed = Int.random(in: 0 ..< 10000)

    init(preset: SceneParticlePreset) {
        self.preset = preset
        switch preset {
        case .snow:
            (count, size, cycles, direction, sway) = (220, 0.35, 1, 270, 0.4)
            color = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
        case .rain:
            (count, size, cycles, direction, sway) = (400, 0.3, 8, 260, 0)
            color = RGBAColor(red: 0.8, green: 0.88, blue: 1, alpha: 0.7)
        case .petals:
            (count, size, cycles, direction, sway) = (70, 0.6, 1, 250, 0.6)
            color = RGBAColor(red: 1, green: 0.72, blue: 0.8, alpha: 1)
        case .fireflies:
            (count, size, cycles, direction, sway) = (60, 0.45, 1, 90, 0.8)
            color = RGBAColor(red: 0.85, green: 1, blue: 0.45, alpha: 1)
        case .dust:
            (count, size, cycles, direction, sway) = (180, 0.15, 1, 20, 0.5)
            color = RGBAColor(red: 1, green: 0.95, blue: 0.85, alpha: 0.6)
        case .embers:
            (count, size, cycles, direction, sway) = (90, 0.3, 2, 90, 0.5)
            color = RGBAColor(red: 1, green: 0.55, blue: 0.2, alpha: 1)
        case .bubbles:
            (count, size, cycles, direction, sway) = (50, 0.55, 1, 90, 0.4)
            color = RGBAColor(red: 0.85, green: 0.95, blue: 1, alpha: 0.8)
        case .stars:
            (count, size, cycles, direction, sway) = (150, 0.25, 2, 0, 0)
            color = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let preset = (try? container.decode(SceneParticlePreset.self, forKey: .preset)) ?? .snow
        let defaults = SceneParticles(preset: preset)
        self.preset = preset
        count = (try? container.decode(Int.self, forKey: .count)) ?? defaults.count
        size = (try? container.decode(Double.self, forKey: .size)) ?? defaults.size
        cycles = (try? container.decode(Int.self, forKey: .cycles)) ?? defaults.cycles
        direction = (try? container.decode(Double.self, forKey: .direction)) ?? defaults.direction
        sway = (try? container.decode(Double.self, forKey: .sway)) ?? defaults.sway
        color = (try? container.decode(RGBAColor.self, forKey: .color)) ?? defaults.color
        opacity = (try? container.decode(Double.self, forKey: .opacity)) ?? defaults.opacity
        cursorMode = (try? container.decode(SceneParticleCursorMode.self, forKey: .cursorMode)) ?? .none
        maskFile = try? container.decodeIfPresent(String.self, forKey: .maskFile)
        seed = (try? container.decode(Int.self, forKey: .seed)) ?? 0
    }
}

struct SceneLayer: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var kind: SceneLayerKind = .image
    /// File name inside the scene folder; empty for particle and text layers.
    var imageFile: String
    /// An MP4 in the scene folder that plays in a loop in place of the image; the
    /// image holds its first frame for wherever the video is not ready.
    var videoFile: String?
    var usesMediaArtwork = false
    /// Reads the canvas below as its input instead of an image file.
    var capturesCanvas = false
    var isVisible = true
    /// Editor only: keeps the layer from being picked, moved or changed.
    var isLocked = false
    var opacity: Double = 1
    var tint = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
    var blendMode: SceneBlendMode = .normal
    /// 0 keeps the layer still; 1 moves it the most with the cursor. Imported scenes
    /// may go past 1 or below 0 (moving with the cursor).
    var parallaxDepth: Double = 0
    /// The depth across the y axis when it differs from x.
    var parallaxDepthY: Double?
    var cursorMask: SceneCursorMask?
    /// Applied in order, before the layer is composited.
    var effects: [SceneEffect] = []
    var renderGraph: SceneRenderGraph?
    var placement: SceneLayerPlacement?
    var particles: SceneParticles?
    /// Simulated particles, in place of `particles` on a particle layer.
    var particleSystem: SceneParticleSystem?
    /// In a scene seen through its camera: where the picture stands in it.
    var space: SceneSpace?
    /// What a layer of kind `model` draws.
    var model: SceneStaticModel?
    var text: SceneText?
    /// Grayscale depth map (white = near) in the scene folder; shifts each pixel by
    /// its depth for a 3D look.
    var depthFile: String?
    /// 0...1
    var depthStrength = 0.5
    var depthFollowsCursor = true
    /// 0 is off; otherwise how far the view drifts on its own, 0...1. It moves the
    /// baked video too, so the lock screen gets the 3D look.
    var depthAutoMotion: Double = 0
    var depthAutoCycles = 1
    var transform = SceneTransform()
    var keyframes: [SceneKeyframe] = []
    var motion: SceneMotion?

    init(name: String, imageFile: String) {
        self.name = name
        self.imageFile = imageFile
    }

    /// Glowing presets add their light to what is below.
    init(name: String, particles: SceneParticles) {
        self.name = name
        kind = .particles
        imageFile = ""
        self.particles = particles
        blendMode = particles.preset.isAdditive ? .add : .normal
    }

    /// Additive particles add their light to what is below.
    init(name: String, particleSystem: SceneParticleSystem) {
        self.name = name
        kind = .particles
        imageFile = ""
        self.particleSystem = particleSystem
        blendMode = particleSystem.blend == .add ? .add : .normal
    }

    init(name: String, text: SceneText) {
        self.name = name
        kind = .text
        imageFile = ""
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = (try? container.decode(SceneLayerKind.self, forKey: .kind)) ?? .image
        imageFile = (try? container.decode(String.self, forKey: .imageFile)) ?? ""
        videoFile = try container.decodeIfPresent(String.self, forKey: .videoFile)
        usesMediaArtwork = try container.decodeIfPresent(Bool.self, forKey: .usesMediaArtwork) ?? false
        capturesCanvas = (try? container.decode(Bool.self, forKey: .capturesCanvas)) ?? false
        particles = try? container.decodeIfPresent(SceneParticles.self, forKey: .particles)
        particleSystem = try container.decodeIfPresent(SceneParticleSystem.self, forKey: .particleSystem)
        space = try container.decodeIfPresent(SceneSpace.self, forKey: .space)
        guard space.map({ $0.isValid }) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .space, in: container, debugDescription: "Invalid placement in space")
        }
        model = try container.decodeIfPresent(SceneStaticModel.self, forKey: .model)
        guard model.map({ $0.isValid }) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .model, in: container, debugDescription: "Invalid model")
        }
        text = try container.decodeIfPresent(SceneText.self, forKey: .text)
        renderGraph = try container.decodeIfPresent(SceneRenderGraph.self, forKey: .renderGraph)
        placement = try container.decodeIfPresent(SceneLayerPlacement.self, forKey: .placement)
        depthFile = try? container.decodeIfPresent(String.self, forKey: .depthFile)
        depthStrength = (try? container.decode(Double.self, forKey: .depthStrength)) ?? 0.5
        depthFollowsCursor = (try? container.decode(Bool.self, forKey: .depthFollowsCursor)) ?? true
        depthAutoMotion = (try? container.decode(Double.self, forKey: .depthAutoMotion)) ?? 0
        depthAutoCycles = (try? container.decode(Int.self, forKey: .depthAutoCycles)) ?? 1
        transform = (try? container.decode(SceneTransform.self, forKey: .transform)) ?? .identity
        keyframes = (try? container.decode([SceneKeyframe].self, forKey: .keyframes)) ?? []
        motion = try? container.decodeIfPresent(SceneMotion.self, forKey: .motion)
        isVisible = (try? container.decode(Bool.self, forKey: .isVisible)) ?? true
        isLocked = (try? container.decode(Bool.self, forKey: .isLocked)) ?? false
        opacity = (try? container.decode(Double.self, forKey: .opacity)) ?? 1
        tint = (try? container.decode(RGBAColor.self, forKey: .tint)) ?? RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
        blendMode = (try? container.decode(SceneBlendMode.self, forKey: .blendMode)) ?? .normal
        parallaxDepth = (try? container.decode(Double.self, forKey: .parallaxDepth)) ?? 0
        parallaxDepthY = try? container.decodeIfPresent(Double.self, forKey: .parallaxDepthY)
        cursorMask = try? container.decodeIfPresent(SceneCursorMask.self, forKey: .cursorMask)
        // An effect this version does not know is dropped rather than failing the scene.
        effects = ((try? container.decode([FailableDecodable<SceneEffect>].self, forKey: .effects)) ?? [])
            .compactMap(\.value)
    }

    var activeEffects: [SceneEffect] {
        isVisible ? effects.filter(\.isEnabled) : []
    }

    func separatedForeground(name: String, imageFile: String) -> SceneLayer {
        var foreground = duplicated(name: name)
        foreground.imageFile = imageFile
        return foreground
    }

    /// An independent copy. Painted files are shared by name, which is safe because a
    /// stroke always writes a new file instead of changing one.
    func duplicated(name: String) -> SceneLayer {
        var copy = self
        copy.id = UUID()
        copy.name = name
        copy.isLocked = false
        // Painting and selection identify effects, pins and poses by UUID across
        // the editor, so the two independent layers must not share those IDs.
        copy.effects = effects.map { effect in
            var copy = effect
            copy.id = UUID()
            copy.pins = effect.pins.map { pin in
                var copy = pin
                copy.id = UUID()
                return copy
            }
            return copy
        }
        copy.keyframes = keyframes.map { frame in
            var copy = frame
            copy.id = UUID()
            return copy
        }
        return copy
    }

    /// A particle layer with something to draw.
    var hasParticles: Bool {
        kind == .particles && (particles != nil || particleSystem != nil)
    }

    var hasDepth: Bool {
        depthFile != nil && depthStrength > 0
    }

    var isKeyframed: Bool {
        keyframes.count >= 2
    }

    /// Placement and opacity factor at `phase` (0..<1 of the loop), or for a recorded
    /// motion at `time` seconds since the scene started.
    func pose(at phase: Double, time: Double) -> (transform: SceneTransform, opacity: Double) {
        if let motion, !motion.samples.isEmpty {
            return motion.pose(at: time)
        }
        return pose(at: phase)
    }

    /// Placement and opacity factor at `phase` (0..<1 of the loop), keyframes only.
    func pose(at phase: Double) -> (transform: SceneTransform, opacity: Double) {
        guard isKeyframed else {
            return (transform, 1)
        }
        let sorted = keyframes.sorted { $0.time < $1.time }
        let p = phase - floor(phase)
        // The span that contains p, wrapping from the last keyframe to the first.
        let nextIndex = sorted.firstIndex { $0.time > p } ?? 0
        let previous = sorted[(nextIndex - 1 + sorted.count) % sorted.count]
        let next = sorted[nextIndex]
        var span = next.time - previous.time
        var elapsed = p - previous.time
        if span <= 0 {
            span += 1
        }
        if elapsed < 0 {
            elapsed += 1
        }
        let t = span > 0 ? min(max(elapsed / span, 0), 1) : 0
        // Ease in and out, so the layer settles into each pose.
        let eased = t * t * (3 - 2 * t)
        return (
            previous.transform.interpolated(to: next.transform, eased),
            previous.opacity + (next.opacity - previous.opacity) * eased
        )
    }

    var usesCursor: Bool {
        isVisible && (parallaxDepth > 0 || cursorMask != nil || (particles.map { $0.cursorMode != .none } ?? false)
            || particleSystem?.usesPointer == true
            || (hasDepth && depthFollowsCursor) || renderGraph?.uses(.cursor) == true)
    }

    /// Particles move on their own; an image layer through its effects or the
    /// depth's own drift.
    var isAnimated: Bool {
        !activeEffects.isEmpty || (isVisible && hasParticles)
            || (isVisible && hasDepth && depthAutoMotion > 0) || (isVisible && (isKeyframed || motion != nil))
            || (isVisible && (renderGraph != nil || placement != nil || videoFile != nil))
    }
}

/// A picture standing in a scene seen through its camera: a `width` × `height` plane
/// centred at (`offsetX`, `offsetY`) in the layer's own units (y up), placed by `world`
/// (column-major, scene units).
struct SceneSpace: Codable, Equatable {
    enum Blending: String, Codable { case translucent, additive, normal }
    var world: [Double]
    var width: Double
    var height: Double
    var offsetX: Double
    var offsetY: Double
    var depthTest: Bool
    var depthWrite: Bool
    var blending: Blending
    var cull: SceneRenderGraph.Draw.Cull?

    var isValid: Bool {
        world.count == 16 && world.allSatisfy(\.isFinite) && [width, height, offsetX, offsetY].allSatisfy(\.isFinite)
    }

    var matrix: simd_float4x4 {
        let m = world.map(Float.init)
        return simd_float4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                       SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
    }
}

/// A scene's camera as the scene sets it up.
struct SceneCamera: Codable, Equatable {
    /// Seen through the camera with its field of view, rather than laid out on the canvas.
    var perspective: Bool
    var eye: [Double]
    var center: [Double]
    var up: [Double]
    /// Vertical, in degrees.
    var fov: Double
    var nearZ: Double
    var farZ: Double
    var ambientColor: [Double]
    var skylightColor: [Double]
    /// The lights that cast a shadow, in the order of the shadow maps materials read.
    var shadowLights: [SceneShadowLight]?
    /// Moves the camera on its own from the moment the scene is shown.
    var path: SceneCameraPath?

    var isValid: Bool {
        [eye, center, up, ambientColor, skylightColor].allSatisfy { $0.count == 3 && $0.allSatisfy(\.isFinite) }
            && [fov, nearZ, farZ].allSatisfy(\.isFinite)
            && (shadowLights ?? []).allSatisfy(\.isValid)
            && (path?.isValid ?? true)
    }
}

/// Key points the camera passes through: straight lines between them, held at the last
/// one, and back to the first after `period` (measured on Wallpaper Engine's own scenes).
struct SceneCameraPath: Codable, Equatable {
    struct Transform: Codable, Equatable {
        var timestamp: Double
        var eye: [Double]
        var center: [Double]
        var up: [Double]
    }

    var duration: Double
    /// By timestamp.
    var transforms: [Transform]

    var isValid: Bool {
        duration.isFinite && !transforms.isEmpty
            && transforms.allSatisfy {
                $0.timestamp.isFinite && $0.timestamp >= 0 && [$0.eye, $0.center, $0.up].allSatisfy { $0.count == 3 && $0.allSatisfy(\.isFinite) }
            }
            && zip(transforms, transforms.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp }
            && period > 0
    }

    /// The last key point's time, or the time left of `duration` after it if that is longer.
    var period: Double {
        let last = transforms[transforms.count - 1].timestamp
        return max(last, duration - last)
    }

    /// A cubic curve through the key points whose slope at each is the one between its
    /// neighbours (at the ends, between it and the next), fitted to CP-022 within about
    /// 0.3 px: a half-way mix of a straight line and an ease at both ends. Only two key
    /// points were measured; the slope with more, and uneven times, is the usual spline's.
    func transform(at time: Double) -> (eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) {
        let t = time.truncatingRemainder(dividingBy: period)
        let next = transforms.firstIndex { $0.timestamp > t } ?? transforms.count
        func vector(_ values: [Double]) -> SIMD3<Float> { SIMD3(values.map(Float.init)) }
        guard next > 0, next < transforms.count else {
            let held = transforms[next == 0 ? 0 : transforms.count - 1]
            return (vector(held.eye), vector(held.center), vector(held.up))
        }
        let a = transforms[next - 1], b = transforms[next]
        let span = b.timestamp - a.timestamp
        let u = Float((t - a.timestamp) / span)
        let h00 = 2 * u * u * u - 3 * u * u + 1, h10 = u * u * u - 2 * u * u + u
        let h01 = -2 * u * u * u + 3 * u * u, h11 = u * u * u - u * u
        func point(_ key: KeyPath<Transform, [Double]>) -> SIMD3<Float> {
            func slope(_ index: Int) -> SIMD3<Float> {
                let first = index == 0, last = index == transforms.count - 1
                let before = first ? index : index - 1, after = last ? index : index + 1
                let width = transforms[after].timestamp - transforms[before].timestamp
                let delta = vector(transforms[after][keyPath: key]) - vector(transforms[before][keyPath: key])
                return delta / Float(first || last ? 2 * width : width)
            }
            return h00 * vector(a[keyPath: key]) + h10 * Float(span) * slope(next - 1)
                + h01 * vector(b[keyPath: key]) + h11 * Float(span) * slope(next)
        }
        return (point(\.eye), point(\.center), point(\.up))
    }}

/// A light whose shadow the scene draws.
struct SceneShadowLight: Codable, Equatable {
    enum Kind: String, Codable { case point, spot, directional }
    var kind: Kind
    var origin: [Double]
    /// Where the light shines.
    var axis: [Double]
    /// Half angle of a spot's cone, in degrees.
    var outerCone: Double
    /// How far from the camera a directional light's shadow reaches.
    var cascadeDistance: Double

    var isValid: Bool {
        origin.count == 3 && axis.count == 3 && (origin + axis + [outerCone, cascadeDistance]).allSatisfy(\.isFinite)
            && axis.contains { $0 != 0 } && (0 ..< 90).contains(outerCone)
    }
}

/// A still-image wallpaper built from layers. Lives in a folder next to the video it
/// is baked into (SceneStore); the desktop draws it live, everything else that only
/// plays videos (lock screen, screen saver, thumbnails) uses the baked video.
struct SceneDocument: Codable, Equatable {
    static let loopSecondsChoices = [10, 20, 30, 60]

    var canvasWidth: Int
    var canvasHeight: Int
    /// Bottom to top.
    var layers: [SceneLayer]
    /// Length of one loop of the motion, and of the baked video when anything moves.
    var loopSeconds = 20
    /// When each part of the day starts, one entry per part.
    var timeBands = SceneTimeBand.defaults
    /// Applied in order after placement and keyframes (SceneLink).
    var links: [SceneLink] = []
    var scripts: [SceneScript] = []
    var rigs: [UUID: SceneSkeleton] = [:]
    /// Drawn live on real time on the desktop rather than as the baked loop, so its
    /// real-time effects keep their exact speed. Set by scenes that use them.
    var runsInRealTime = false
    /// The colour under every layer (RGB, 0...1); black when absent.
    var backgroundColor: [Double]?
    /// Layers are blended in half floats, so colours above white survive until the end.
    var highDynamicRange = false
    /// Runs over the finished canvas (`input`) before it is shown, such as a glow.
    var finishing: SceneRenderGraph?
    /// How far a layer of depth 1 moves, as a fraction of the canvas, with the cursor at
    /// an edge; the renderer's own amount when absent.
    var parallaxTravel: Double?
    /// The share of the remaining way the parallax follows the cursor per second
    /// (capped at all of it per frame); the screen's own easing when absent.
    var parallaxResponse: Double?
    var cameraShake: SceneCameraShake?
    /// The materials of the layers scripts make from their own geometry, by the index a
    /// script names; nil where one could not be converted.
    var meshMaterials: [SceneMeshMaterial?]?
    /// Where model layers scripts make are seen from; scripts can move it.
    var camera: SceneCamera?

    init(canvasWidth: Int, canvasHeight: Int, layers: [SceneLayer]) {
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.layers = layers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canvasWidth = try container.decode(Int.self, forKey: .canvasWidth)
        canvasHeight = try container.decode(Int.self, forKey: .canvasHeight)
        layers = try container.decode([SceneLayer].self, forKey: .layers)
        rigs = try container.decodeIfPresent([UUID: SceneSkeleton].self, forKey: .rigs) ?? [:]
        // Packages come from anyone, and the baker writes loopSeconds × 60 frames.
        let decodedLoop = (try? container.decode(Int.self, forKey: .loopSeconds)) ?? 20
        loopSeconds = min(max(decodedLoop, 1), Self.loopSecondsChoices.max()!)
        let bands = (try? container.decode([SceneTimeBand].self, forKey: .timeBands)) ?? []
        // One of each part, within a day; anything else falls back as a whole.
        if Set(bands.map(\.timeOfDay)) == Set(SceneTimeOfDay.allCases), bands.count == SceneTimeOfDay.allCases.count,
           bands.allSatisfy({ (0 ..< 24 * 60).contains($0.startMinute) })
        {
            timeBands = bands
        }
        links = ((try? container.decode([FailableDecodable<SceneLink>].self, forKey: .links)) ?? []).compactMap(\.value)
        runsInRealTime = (try? container.decode(Bool.self, forKey: .runsInRealTime)) ?? false
        backgroundColor = try container.decodeIfPresent([Double].self, forKey: .backgroundColor)
        guard backgroundColor.map({ $0.count == 3 && $0.allSatisfy(\.isFinite) }) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .backgroundColor, in: container, debugDescription: "Background needs three finite components")
        }
        highDynamicRange = try container.decodeIfPresent(Bool.self, forKey: .highDynamicRange) ?? false
        finishing = try container.decodeIfPresent(SceneRenderGraph.self, forKey: .finishing)
        parallaxTravel = try container.decodeIfPresent(Double.self, forKey: .parallaxTravel)
        parallaxResponse = try container.decodeIfPresent(Double.self, forKey: .parallaxResponse)
        cameraShake = try container.decodeIfPresent(SceneCameraShake.self, forKey: .cameraShake)
        meshMaterials = try container.decodeIfPresent([SceneMeshMaterial?].self, forKey: .meshMaterials)
        camera = try container.decodeIfPresent(SceneCamera.self, forKey: .camera)
        guard camera.map({ $0.isValid }) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .camera, in: container, debugDescription: "Invalid camera")
        }
        guard [parallaxTravel, parallaxResponse].allSatisfy({ $0?.isFinite ?? true }) else {
            throw DecodingError.dataCorruptedError(forKey: .parallaxTravel, in: container, debugDescription: "Parallax values must be finite")
        }
        scripts = try container.decodeIfPresent([SceneScript].self, forKey: .scripts) ?? []
        guard scripts.count <= SceneScript.maximumCount, Set(scripts.map(\.id)).count == scripts.count else {
            throw DecodingError.dataCorruptedError(forKey: .scripts, in: container, debugDescription: "Too many scripts or duplicate script IDs")
        }
    }

    var isAnimated: Bool {
        layers.contains(where: \.isAnimated) || scripts.contains { $0.canRun && $0.usesTime } || cameraShake != nil
    }

    var aspectRatio: Double {
        Double(max(canvasWidth, 1)) / Double(max(canvasHeight, 1))
    }

    var usesCursor: Bool {
        layers.contains(where: \.usesCursor) || links.contains { $0.input.usesCursor && $0.hasEffect }
            || scripts.contains { $0.canRun && $0.usesCursor }
    }

    /// Whether the scene has interactive elements (cursor parallax, audio reaction,
    /// or dynamic media artwork) that require drawing live on the desktop rather than
    /// playing the baked 60fps video.
    var hasLiveInteraction: Bool {
        layers.contains(where: \.usesCursor)
            || links.contains { $0.input.usesCursor && $0.hasEffect }
            || usesAudio
            || layers.contains { $0.isVisible && $0.usesMediaArtwork }
            || scripts.contains { $0.requiresLiveInteraction }
    }

    var requiresRealTimePlayback: Bool {
        runsInRealTime || layers.contains { layer in
            layer.activeEffects.contains { $0.kind.runsOnRealTime } || (layer.isVisible && (layer.renderGraph != nil || layer.placement != nil || layer.usesMediaArtwork))
                // A recorded motion keeps its own period, not the loop's.
                || (layer.isVisible && layer.motion != nil)
        }
    }

    var hasUnapprovedScripts: Bool { scripts.contains { $0.isEnabled && !$0.canRun } }
}

/// The whole canvas drifts on a smooth path, as a handheld camera would.
struct SceneCameraShake: Codable, Equatable {
    /// The path runs at speed² radians per second.
    var speed: Double
    /// Pixels of the canvas height per 100, at the path's full reach.
    var amplitude: Double
    /// Bends the path's reach: its length is raised to roughness³.
    var roughness: Double

    /// How far the view moves at `time` seconds, in canvas heights (+y down).
    func offset(at time: Double) -> SIMD2<Double> {
        let t = speed * speed * time
        var x = cos(t), y = sin(1.333 * t)
        let exponent = roughness * roughness * roughness
        let length = (x * x + y * y).squareRoot()
        if exponent > 0.001, exponent != 1, length > 0 {
            let reach = pow(length, exponent) / length
            x *= reach
            y *= reach
        }
        // The view moving up shows the canvas lower on the screen.
        return SIMD2(x, -y) * amplitude * 0.01
    }
}

/// Decodes to nil instead of failing the whole array.
struct FailableDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

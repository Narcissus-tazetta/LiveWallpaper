import Foundation

enum SceneBlendMode: String, Codable, CaseIterable {
    case normal
    case multiply
    case screen
    case overlay
    case add
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

enum SceneLayerKind: String, Codable {
    case image
    case particles
    case text
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
    /// Reads the canvas below as its input instead of an image file.
    var capturesCanvas = false
    var isVisible = true
    /// Editor only: keeps the layer from being picked, moved or changed.
    var isLocked = false
    var opacity: Double = 1
    var tint = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
    var blendMode: SceneBlendMode = .normal
    /// 0 keeps the layer still; 1 moves it the most with the cursor.
    var parallaxDepth: Double = 0
    var cursorMask: SceneCursorMask?
    /// Applied in order, before the layer is composited.
    var effects: [SceneEffect] = []
    var renderGraph: SceneRenderGraph?
    var placement: SceneLayerPlacement?
    var particles: SceneParticles?
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
        capturesCanvas = (try? container.decode(Bool.self, forKey: .capturesCanvas)) ?? false
        particles = try? container.decodeIfPresent(SceneParticles.self, forKey: .particles)
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
        isVisible = (try? container.decode(Bool.self, forKey: .isVisible)) ?? true
        isLocked = (try? container.decode(Bool.self, forKey: .isLocked)) ?? false
        opacity = (try? container.decode(Double.self, forKey: .opacity)) ?? 1
        tint = (try? container.decode(RGBAColor.self, forKey: .tint)) ?? RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
        blendMode = (try? container.decode(SceneBlendMode.self, forKey: .blendMode)) ?? .normal
        parallaxDepth = (try? container.decode(Double.self, forKey: .parallaxDepth)) ?? 0
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

    var hasDepth: Bool {
        depthFile != nil && depthStrength > 0
    }

    var isKeyframed: Bool {
        keyframes.count >= 2
    }

    /// Placement and opacity factor at `phase` (0..<1 of the loop).
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
            || (hasDepth && depthFollowsCursor) || renderGraph?.uses(.cursor) == true)
    }

    /// Particles move on their own; an image layer through its effects or the
    /// depth's own drift.
    var isAnimated: Bool {
        !activeEffects.isEmpty || (isVisible && kind == .particles && particles != nil)
            || (isVisible && hasDepth && depthAutoMotion > 0) || (isVisible && isKeyframed)
            || (isVisible && (renderGraph != nil || placement != nil || videoFile != nil))
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
        scripts = try container.decodeIfPresent([SceneScript].self, forKey: .scripts) ?? []
        guard scripts.count <= SceneScript.maximumCount, Set(scripts.map(\.id)).count == scripts.count else {
            throw DecodingError.dataCorruptedError(forKey: .scripts, in: container, debugDescription: "Too many scripts or duplicate script IDs")
        }
    }

    var isAnimated: Bool {
        layers.contains(where: \.isAnimated) || scripts.contains { $0.canRun && $0.usesTime }
    }

    var aspectRatio: Double {
        Double(max(canvasWidth, 1)) / Double(max(canvasHeight, 1))
    }

    var usesCursor: Bool {
        layers.contains(where: \.usesCursor) || links.contains { $0.input.usesCursor && $0.hasEffect }
            || scripts.contains { $0.canRun && $0.usesCursor }
    }

    var requiresRealTimePlayback: Bool {
        runsInRealTime || layers.contains { layer in
            layer.activeEffects.contains { $0.kind.runsOnRealTime } || (layer.isVisible && (layer.renderGraph != nil || layer.placement != nil))
        }
    }

    var hasUnapprovedScripts: Bool { scripts.contains { $0.isEnabled && !$0.canRun } }
}

/// Decodes to nil instead of failing the whole array.
struct FailableDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

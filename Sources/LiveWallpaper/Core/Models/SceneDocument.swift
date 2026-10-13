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

    /// Uses `centerX`/`centerY` (picked on the preview).
    var usesCenter: Bool {
        [.swing, .ripple, .spin, .twirl].contains(self)
    }

    var usesDirection: Bool {
        [.shake, .sway, .waves, .scroll].contains(self)
    }

    /// Uses `scale`: wavelength, noise size or radius depending on the effect.
    var usesScale: Bool {
        [.sway, .waves, .ripple, .cloudMotion, .twirl, .puppet].contains(self)
    }

    var usesStrength: Bool {
        ![.scroll, .spin, .puppet].contains(self)
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

    init(kind: SceneEffectKind) {
        self.kind = kind
        if kind == .waterFlow {
            cycles = 4
        }
        if kind == .puppet {
            scale = 0.3
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(SceneEffectKind.self, forKey: .kind)
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
    }
}

/// Where a layer sits on the canvas, on top of its aspect-fit placement.
struct SceneTransform: Codable, Equatable {
    /// Fractions of the canvas width/height; +x right, +y down.
    var offsetX: Double = 0
    var offsetY: Double = 0
    var scale: Double = 1
    /// Degrees, clockwise.
    var rotation: Double = 0

    static let identity = SceneTransform()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        offsetX = (try? container.decode(Double.self, forKey: .offsetX)) ?? 0
        offsetY = (try? container.decode(Double.self, forKey: .offsetY)) ?? 0
        scale = (try? container.decode(Double.self, forKey: .scale)) ?? 1
        rotation = (try? container.decode(Double.self, forKey: .rotation)) ?? 0
    }

    func interpolated(to other: SceneTransform, _ t: Double) -> SceneTransform {
        var result = SceneTransform()
        result.offsetX = offsetX + (other.offsetX - offsetX) * t
        result.offsetY = offsetY + (other.offsetY - offsetY) * t
        // Scale is interpolated in log space so a zoom feels even.
        result.scale = exp(log(max(scale, 0.01)) + (log(max(other.scale, 0.01)) - log(max(scale, 0.01))) * t)
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
    /// File name inside the scene folder; empty for particle layers.
    var imageFile: String
    var isVisible = true
    var opacity: Double = 1
    var blendMode: SceneBlendMode = .normal
    /// 0 keeps the layer still; 1 moves it the most with the cursor.
    var parallaxDepth: Double = 0
    var cursorMask: SceneCursorMask?
    /// Applied in order, before the layer is composited.
    var effects: [SceneEffect] = []
    var particles: SceneParticles?
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = (try? container.decode(SceneLayerKind.self, forKey: .kind)) ?? .image
        imageFile = (try? container.decode(String.self, forKey: .imageFile)) ?? ""
        particles = try? container.decodeIfPresent(SceneParticles.self, forKey: .particles)
        depthFile = try? container.decodeIfPresent(String.self, forKey: .depthFile)
        depthStrength = (try? container.decode(Double.self, forKey: .depthStrength)) ?? 0.5
        depthFollowsCursor = (try? container.decode(Bool.self, forKey: .depthFollowsCursor)) ?? true
        depthAutoMotion = (try? container.decode(Double.self, forKey: .depthAutoMotion)) ?? 0
        depthAutoCycles = (try? container.decode(Int.self, forKey: .depthAutoCycles)) ?? 1
        transform = (try? container.decode(SceneTransform.self, forKey: .transform)) ?? .identity
        keyframes = (try? container.decode([SceneKeyframe].self, forKey: .keyframes)) ?? []
        isVisible = (try? container.decode(Bool.self, forKey: .isVisible)) ?? true
        opacity = (try? container.decode(Double.self, forKey: .opacity)) ?? 1
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
        var foreground = self
        foreground.id = UUID()
        foreground.name = name
        foreground.imageFile = imageFile
        // Painting and selection identify effects, pins and poses by UUID across
        // the editor, so the two independent layers must not share those IDs.
        foreground.effects = effects.map { effect in
            var copy = effect
            copy.id = UUID()
            copy.pins = effect.pins.map { pin in
                var copy = pin
                copy.id = UUID()
                return copy
            }
            return copy
        }
        foreground.keyframes = keyframes.map { frame in
            var copy = frame
            copy.id = UUID()
            return copy
        }
        return foreground
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
            || (hasDepth && depthFollowsCursor))
    }

    /// Particles move on their own; an image layer through its effects or the
    /// depth's own drift.
    var isAnimated: Bool {
        !activeEffects.isEmpty || (isVisible && kind == .particles && particles != nil)
            || (isVisible && hasDepth && depthAutoMotion > 0) || (isVisible && isKeyframed)
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
        // Packages come from anyone, and the baker writes loopSeconds × 60 frames.
        let decodedLoop = (try? container.decode(Int.self, forKey: .loopSeconds)) ?? 20
        loopSeconds = min(max(decodedLoop, 1), Self.loopSecondsChoices.max()!)
    }

    var isAnimated: Bool {
        layers.contains(where: \.isAnimated)
    }

    var aspectRatio: Double {
        Double(max(canvasWidth, 1)) / Double(max(canvasHeight, 1))
    }

    var usesCursor: Bool {
        layers.contains(where: \.usesCursor)
    }
}

/// Decodes to nil instead of failing the whole array.
struct FailableDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

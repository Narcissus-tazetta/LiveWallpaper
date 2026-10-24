import Foundation

/// Particles that are born, move and die over time (SceneParticleSimulator), as
/// opposed to SceneParticles, whose positions are a function of the loop phase.
/// Lengths are canvas pixels in the layer's own space, x right and y up; times are
/// seconds; a fraction of a particle's life runs 0...1.
struct SceneParticleSystem: Codable, Equatable {
    enum Blend: String, Codable, CaseIterable {
        /// Covers what is below, ignoring the particle's alpha.
        case opaque
        case alpha
        /// Adds the particle's colour times its alpha.
        case add
    }

    /// A grid of frames in the texture, row by row from the top left.
    struct Sheet: Codable, Equatable {
        enum Mode: String, Codable {
            /// Each particle keeps one frame picked at birth.
            case random
            /// Frames play over the particle's life, `speed` times.
            case sequence
        }

        var columns: Int
        var rows: Int
        var frameCount: Int
        var mode: Mode = .sequence
        var speed: Double = 1
    }

    struct Range: Codable, Equatable {
        var min: Double
        var max: Double
        /// A random u in 0...1 picks min + (max - min) * u^exponent.
        var exponent: Double = 1

        init(_ min: Double, _ max: Double, exponent: Double = 1) {
            self.min = min
            self.max = max
            self.exponent = exponent
        }

        static func fixed(_ value: Double) -> Range {
            Range(value, value)
        }
    }

    struct VectorRange: Codable, Equatable {
        var min: [Double]
        var max: [Double]
        var exponent: Double = 1

        init(_ min: [Double], _ max: [Double], exponent: Double = 1) {
            self.min = min
            self.max = max
            self.exponent = exponent
        }

        static let zero = VectorRange([0, 0, 0], [0, 0, 0])
    }

    struct Emitter: Codable, Equatable {
        enum Shape: String, Codable {
            /// Each axis at a random sign times a random distance between the two
            /// corners' values on that axis.
            case box
            /// Within `distance.max` of the origin; a ring from `distance.min` when it
            /// is above 0.
            case sphere
        }

        var shape: Shape
        var origin: [Double] = [0, 0, 0]
        /// Per axis for a box; the x of each for a sphere's radii.
        var distanceMin: [Double] = [0, 0, 0]
        var distanceMax: [Double] = [0, 0, 0]
        /// Stretches the shape per axis.
        var directions: [Double] = [1, 1, 1]
        /// Per axis: 0 either side, above 0 only positive, below 0 only negative.
        var sign: [Double] = [0, 0, 0]
        /// Particles per second.
        var rate: Double = 0
        /// Particles released at once when the emitter starts.
        var burst: Int = 0
        /// Speed away from the origin, added to the particle's velocity.
        var speed = Range(0, 0)
        /// Seconds before the emitter starts.
        var delay: Double = 0
        /// Seconds the emitter runs; nil runs on.
        var duration: Double?
    }

    struct Initial: Codable, Equatable {
        var lifetime = Range.fixed(1)
        /// Drawn at half this size, as the scenes this follows expect.
        var size = Range.fixed(20)
        /// RGB 0...1, picked between the two at one random point.
        var colorMin: [Double] = [1, 1, 1]
        var colorMax: [Double] = [1, 1, 1]
        /// When not empty, one of these instead of colorMin/colorMax.
        var colorChoices: [[Double]] = []
        var alpha = Range.fixed(1)
        /// Pixels per second, each axis on its own.
        var velocity = VectorRange.zero
        /// Radians; z turns clockwise on screen, x and y tilt the sprite.
        var rotation = VectorRange.zero
        /// Radians per second; only an `angularMovement` behaviour applies it.
        var angularVelocity = VectorRange.zero
    }

    enum Behavior: Codable, Equatable {
        /// Pixels per second squared; drag slows the velocity in proportion to it.
        case movement(gravity: [Double], drag: Double)
        /// Applies the angular velocity, with an angular acceleration and drag.
        case angularMovement(force: [Double], drag: Double)
        /// Fades in until `fadeIn` of the life, fades out from `fadeOut` to the end.
        case alphaFade(fadeIn: Double, fadeOut: Double)
        /// Multiplies, moving from start to end between the two life fractions.
        case sizeChange(Change)
        case alphaChange(Change)
        case colorChange(ColorChange)
        /// Adds amplitude * sin(frequency * age + phase) on the masked axes.
        case oscillatePosition(Oscillation)
        /// Accelerates particles within `threshold` towards a control point, the
        /// harder the nearer (negative `scale` pushes away).
        case attract(controlPoint: Int, scale: Double, threshold: Double)
    }

    struct Change: Codable, Equatable {
        var startTime: Double = 0
        var endTime: Double = 1
        var startValue: Double = 1
        var endValue: Double = 1
    }

    struct ColorChange: Codable, Equatable {
        var startTime: Double = 0
        var endTime: Double = 1
        var startValue: [Double] = [1, 1, 1]
        var endValue: [Double] = [1, 1, 1]
    }

    struct Oscillation: Codable, Equatable {
        /// Radians per second.
        var frequency = Range(0, 10)
        var amplitude = Range(0, 10)
        var phase = Range(0, 0)
        var mask: [Double] = [1, 1, 0]
    }

    enum Renderer: Codable, Equatable {
        case sprite
        /// Stretched along the velocity: its length in sizes is speed * length,
        /// kept between minLength and maxLength.
        case trail(length: Double, minLength: Double, maxLength: Double)
    }

    struct ControlPoint: Codable, Equatable {
        enum Anchor: String, Codable {
            /// At `offset` from the layer's origin.
            case layer
            /// At the pointer; without one the point pulls nothing.
            case pointer
            /// At the canvas's bottom-left corner.
            case canvasCorner
            /// Pulls nothing.
            case none
        }

        var index: Int
        var anchor: Anchor = .layer
        var offset: [Double] = [0, 0, 0]
    }

    struct Child: Codable, Equatable {
        enum Trigger: String, Codable {
            /// Runs on its own from the start.
            case start
            /// Releases its burst where each particle is born.
            case birth
            /// Emits from each particle while it lives; what it emits moves along
            /// with that particle until it dies.
            case follow
            /// Releases its burst where each particle dies.
            case death
        }

        var trigger: Trigger
        var origin: [Double] = [0, 0, 0]
        /// Scales where the child's particles start, their size and their speed.
        var scale: [Double] = [1, 1, 1]
        /// The chance that each trigger releases anything.
        var probability: Double = 1
        var system: Box
    }

    /// Children hold whole systems, which a struct cannot contain directly.
    final class Box: Codable, Equatable {
        let value: SceneParticleSystem

        init(_ value: SceneParticleSystem) {
            self.value = value
        }

        required init(from decoder: Decoder) throws {
            value = try SceneParticleSystem(from: decoder)
        }

        func encode(to encoder: Encoder) throws {
            try value.encode(to: encoder)
        }

        static func == (lhs: Box, rhs: Box) -> Bool {
            lhs === rhs || lhs.value == rhs.value
        }
    }

    /// Multiplies the sprite by the canvas below it, shifted by a normal map: the
    /// particle shows what is behind it, bent.
    struct Refraction: Codable, Equatable {
        /// Red and green the normal's x and y (0...1 for -1...1), blue the mask.
        var normalFile: String?
        /// The shift at full normal, as a fraction of the canvas.
        var amount: Double = 0.05
    }

    var maxCount: Int = 500
    /// Seconds simulated before the first frame.
    var startTime: Double = 0
    /// A straight-alpha image in the scene folder; nil draws white squares.
    var textureFile: String?
    var sheet: Sheet?
    var blend: Blend = .add
    /// Multiplies the colour; can go past white on a wide canvas.
    var brightness: Double = 1
    var refraction: Refraction?
    var emitters: [Emitter] = []
    var initial = Initial()
    var behaviors: [Behavior] = []
    var renderer: Renderer = .sprite
    var controlPoints: [ControlPoint] = []
    var children: [Child] = []

    /// Every image this system and its children draw.
    var textureFiles: [String] {
        [textureFile, refraction?.normalFile].compactMap { $0 } + children.flatMap(\.system.value.textureFiles)
    }

    var normalFiles: [String] {
        [refraction?.normalFile].compactMap { $0 } + children.flatMap(\.system.value.normalFiles)
    }

    var refracts: Bool {
        refraction != nil || children.contains { $0.system.value.refracts }
    }

    /// The longest a particle of this system or its children can live.
    var longestLifetime: Double {
        ([max(initial.lifetime.min, initial.lifetime.max)] + children.map(\.system.value.longestLifetime)).max() ?? 0
    }

    var usesPointer: Bool {
        controlPoints.contains { $0.anchor == .pointer } || children.contains { $0.system.value.usesPointer }
    }
}

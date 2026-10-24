import Foundation
import simd

/// Runs a SceneParticleSystem frame by frame. Positions stay in the layer's own space
/// (pixels, y up); the renderer places them on the canvas.
final class SceneParticleSimulator {
    /// What a script asked of the layer since the last frame, in order.
    struct Control: Equatable {
        enum Event: Equatable {
            case emit(Int)
            /// Removes every particle, children's included.
            case clear
        }

        var events: [Event] = []
        /// False stops the emitters (not the particles already out); nil leaves it.
        var emitting: Bool?

        mutating func append(_ other: Control) {
            events += other.events
            if let emitting = other.emitting { self.emitting = emitting }
        }
    }

    /// Points the control points can follow, in the layer's space.
    struct Surroundings {
        var pointer: SIMD3<Double>?
        var canvasCorner: SIMD3<Double> = .zero
    }

    /// One sprite as the renderer draws it, in the layer's space.
    struct Instance {
        var center: SIMD2<Float>
        /// The sprite's full width and height as vectors.
        var right: SIMD2<Float>
        var up: SIMD2<Float>
        var uvOrigin: SIMD2<Float>
        var uvSize: SIMD2<Float>
        /// Straight alpha.
        var color: SIMD4<Float>
    }

    private struct Particle {
        var position: SIMD3<Double>
        var velocity: SIMD3<Double>
        var rotation: SIMD3<Double>
        var angularVelocity: SIMD3<Double>
        var size: Double
        var color: SIMD3<Double>
        var alpha: Double
        var age: Double = 0
        var lifetime: Double
        /// Unique within the simulator; following children find their parent by it.
        var id: Int = 0
        /// The parent particle a following child's particle moves with.
        var parent: Int?
        var frame: Int
        /// Per oscillation behaviour: frequency, amplitude and phase on each axis.
        var oscillations: [(frequency: SIMD3<Double>, amplitude: SIMD3<Double>, phase: SIMD3<Double>)]
        /// What the oscillations last added to the position.
        var oscillationOffset: SIMD3<Double> = .zero
        /// Particles owed by each following child, carried between frames.
        var followDebts: [Double]
    }

    private final class ChildState {
        let trigger: SceneParticleSystem.Child.Trigger
        let origin: SIMD3<Double>
        let probability: Double
        let simulator: SceneParticleSimulator

        init(_ child: SceneParticleSystem.Child, seed: UInt64) {
            trigger = child.trigger
            origin = SceneParticleSimulator.vector(child.origin)
            probability = child.probability
            simulator = SceneParticleSimulator(system: child.system.value, seed: seed, runsEmitters: child.trigger == .start,
                                               originOffset: child.trigger == .start ? origin : .zero,
                                               scale: SceneParticleSimulator.vector(child.scale, fill: 1))
        }
    }

    let system: SceneParticleSystem
    private var particles: [Particle] = []
    private var children: [ChildState] = []
    private var followChildren: [Int] = []
    /// Seconds since the system started.
    private var clock: Double = 0
    private var debts: [Double]
    private var burstsDone: [Bool]
    private var emitting = true
    private let runsEmitters: Bool
    /// Moves the emitters of a child that runs on its own.
    private let originOffset: SIMD3<Double>
    /// A child's scale: on where its particles start (around the spawn point), their
    /// size and speed.
    private let scale: SIMD3<Double>
    private var nextID = 0
    private var random: SplitMix

    var count: Int {
        particles.count
    }

    init(system: SceneParticleSystem, seed: UInt64, runsEmitters: Bool = true, originOffset: SIMD3<Double> = .zero,
         scale: SIMD3<Double> = .one) {
        self.system = system
        self.runsEmitters = runsEmitters
        self.originOffset = originOffset
        self.scale = scale
        random = SplitMix(seed: seed)
        debts = Array(repeating: 0, count: system.emitters.count)
        burstsDone = Array(repeating: false, count: system.emitters.count)
        children = system.children.enumerated().map { index, child in
            ChildState(child, seed: seed &+ UInt64(index + 1) &* 0x9E37_79B9_7F4A_7C15)
        }
        followChildren = children.indices.filter { children[$0].trigger == .follow }
        particles.reserveCapacity(min(max(system.maxCount, 0), 4096))
        if system.startTime > 0 {
            let step = 1.0 / 30
            var remaining = min(system.startTime, 60)
            while remaining > 0 {
                advance(by: min(step, remaining), surroundings: Surroundings())
                remaining -= step
            }
        }
    }

    func apply(_ control: Control) {
        for event in control.events {
            switch event {
            case let .emit(count):
                spawn(count, emitters: system.emitters.indices, at: nil, parent: nil)
            case .clear:
                clearAll()
            }
        }
        if let emitting = control.emitting { self.emitting = emitting }
    }

    func advance(by dt: Double, surroundings: Surroundings) {
        guard dt > 0 else { return }
        let drag = Self.dragStep(dt)
        var died: [SIMD3<Double>] = []
        var moved: [Int: SIMD3<Double>] = [:]
        // Compacts in place, keeping the birth order, which is the drawing order.
        var kept = 0
        for index in particles.indices {
            var particle = particles[index]
            particle.age += dt
            if particle.age >= particle.lifetime {
                died.append(particle.position)
                continue
            }
            let before = particle.position
            update(&particle, dt: dt, drag: drag, surroundings: surroundings)
            if !followChildren.isEmpty { moved[particle.id] = particle.position - before }
            particles[kept] = particle
            kept += 1
        }
        particles.removeLast(particles.count - kept)
        for child in children {
            child.simulator.advance(by: dt, surroundings: surroundings)
            if child.trigger == .follow { child.simulator.carry(moved) }
        }
        for position in died {
            for child in children where child.trigger == .death && chance(child.probability) {
                child.simulator.burst(at: position + child.origin, parent: nil)
            }
        }
        if !followChildren.isEmpty {
            for index in particles.indices {
                for (slot, childIndex) in followChildren.enumerated() {
                    let child = children[childIndex]
                    particles[index].followDebts[slot] += child.simulator.totalRate * dt
                    let owed = Int(particles[index].followDebts[slot])
                    if owed > 0 {
                        particles[index].followDebts[slot] -= Double(owed)
                        child.simulator.spawn(owed, emitters: child.simulator.system.emitters.indices,
                                              at: particles[index].position + child.origin, parent: particles[index].id)
                    }
                }
            }
        }
        clock += dt
        guard runsEmitters, emitting else { return }
        for (index, emitter) in system.emitters.enumerated() where clock >= emitter.delay {
            if let duration = emitter.duration, clock - emitter.delay > duration { continue }
            if !burstsDone[index] {
                burstsDone[index] = true
                spawn(emitter.burst, emitters: index ..< index + 1, at: nil, parent: nil)
            }
            debts[index] += emitter.rate * dt
            let owed = Int(debts[index])
            if owed > 0 {
                debts[index] -= Double(owed)
                spawn(owed, emitters: index ..< index + 1, at: nil, parent: nil)
            }
        }
    }

    /// The sprites to draw, oldest first. `aspect` is a frame's height over its width.
    func instances(aspect: Double) -> [Instance] {
        var result: [Instance] = []
        result.reserveCapacity(particles.count)
        let sheet = system.sheet
        for particle in particles {
            let fraction = min(max(particle.age / max(particle.lifetime, 1e-9), 0), 1)
            var size = particle.size * 0.5
            var alpha = particle.alpha
            var color = particle.color
            for behavior in system.behaviors {
                switch behavior {
                case let .sizeChange(change):
                    size *= Self.value(of: change, at: fraction)
                case let .alphaChange(change):
                    alpha *= Self.value(of: change, at: fraction)
                case let .colorChange(change):
                    color *= Self.value(of: change, at: fraction)
                case let .alphaFade(fadeIn, fadeOut):
                    alpha *= Self.fade(fadeIn: fadeIn, fadeOut: fadeOut, at: fraction)
                default:
                    break
                }
            }
            guard size > 0 else { continue }
            let right: SIMD2<Double>
            let up: SIMD2<Double>
            switch system.renderer {
            case .sprite:
                let axes = Self.axes(rotation: particle.rotation)
                right = axes.right * size
                up = axes.up * size * aspect
            case let .trail(length, minLength, maxLength):
                let flat = SIMD2(particle.velocity.x, particle.velocity.y)
                let speed = simd_length(flat)
                guard speed > 1e-9 else { continue }
                let direction = flat / speed
                right = SIMD2(direction.y, -direction.x) * size
                up = direction * size * aspect * max(minLength, min(speed * length, maxLength))
            }
            var uvOrigin = SIMD2<Float>(0, 0)
            var uvSize = SIMD2<Float>(1, 1)
            if let sheet, sheet.columns > 0, sheet.rows > 0, sheet.frameCount > 0 {
                let frame: Int
                switch sheet.mode {
                case .random:
                    frame = particle.frame
                case .sequence:
                    let progress = fraction * sheet.speed
                    frame = min(Int((progress - floor(progress)) * Double(sheet.frameCount)), sheet.frameCount - 1)
                }
                uvSize = SIMD2(1 / Float(sheet.columns), 1 / Float(sheet.rows))
                uvOrigin = SIMD2(Float(frame % sheet.columns), Float(frame / sheet.columns)) * uvSize
            }
            result.append(Instance(
                center: SIMD2(Float(particle.position.x), Float(particle.position.y)),
                right: SIMD2<Float>(right), up: SIMD2<Float>(up),
                uvOrigin: uvOrigin, uvSize: uvSize,
                color: SIMD4(Float(color.x), Float(color.y), Float(color.z), Float(min(max(alpha, 0), 1)))
            ))
        }
        return result
    }

    /// This simulator and its children's, parents before children.
    func forEach(_ body: (SceneParticleSimulator) throws -> Void) rethrows {
        try body(self)
        for child in children {
            try child.simulator.forEach(body)
        }
    }

    // MARK: - Steps

    private var totalRate: Double {
        system.emitters.reduce(0) { $0 + $1.rate }
    }

    private func clearAll() {
        particles.removeAll(keepingCapacity: true)
        for child in children {
            child.simulator.clearAll()
        }
    }

    private func burst(at point: SIMD3<Double>, parent: Int?) {
        for index in system.emitters.indices {
            spawn(system.emitters[index].burst, emitters: index ..< index + 1, at: point, parent: parent)
        }
    }

    /// Moves a following child's particles by what their parents moved.
    private func carry(_ moved: [Int: SIMD3<Double>]) {
        guard !moved.isEmpty else { return }
        for index in particles.indices {
            if let parent = particles[index].parent, let offset = moved[parent] {
                particles[index].position += offset
            }
        }
    }

    private func chance(_ probability: Double) -> Bool {
        probability >= 1 || random.unit() < probability
    }

    /// Spawns `count` particles from the emitters in turn, at most up to the limit;
    /// `point` moves the emitters there (children follow their parent's particles).
    private func spawn(_ count: Int, emitters: Range<Int>, at point: SIMD3<Double>?, parent: Int?) {
        guard count > 0 else { return }
        let available = max(system.maxCount - particles.count, 0)
        for number in 0 ..< min(count, available) {
            let emitter = emitters.isEmpty ? nil : system.emitters[emitters.lowerBound + number % emitters.count]
            var particle = makeParticle(emitter: emitter)
            if let point { particle.position += point }
            particle.id = nextID
            particle.parent = parent
            nextID += 1
            particles.append(particle)
            for child in children where (child.trigger == .birth || child.trigger == .follow) && chance(child.probability) {
                child.simulator.burst(at: particle.position + child.origin, parent: child.trigger == .follow ? particle.id : nil)
            }
        }
    }

    private func makeParticle(emitter: SceneParticleSystem.Emitter?) -> Particle {
        let initial = system.initial
        var position = SIMD3<Double>.zero
        var velocity = sample(initial.velocity)
        if let emitter {
            let offset = sampleShape(emitter)
            position = (Self.vector(emitter.origin) + offset) * scale + originOffset
            let speed = sample(emitter.speed)
            if speed != 0, simd_length(offset) > 1e-9 {
                velocity += simd_normalize(offset) * speed
            }
        }
        velocity *= scale
        var color: SIMD3<Double>
        if !initial.colorChoices.isEmpty {
            color = Self.vector(initial.colorChoices[Int(random.unit() * Double(initial.colorChoices.count)) % initial.colorChoices.count])
        } else {
            let low = Self.vector(initial.colorMin)
            let high = Self.vector(initial.colorMax)
            color = low + (high - low) * random.unit()
        }
        let oscillations = system.behaviors.compactMap { behavior -> (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)? in
            guard case let .oscillatePosition(oscillation) = behavior else { return nil }
            func three(_ range: SceneParticleSystem.Range) -> SIMD3<Double> {
                SIMD3(sample(range), sample(range), sample(range))
            }
            return (three(oscillation.frequency), three(oscillation.amplitude) * Self.vector(oscillation.mask), three(oscillation.phase))
        }
        let frameCount = system.sheet?.frameCount ?? 1
        return Particle(
            position: position,
            velocity: velocity,
            rotation: sample(initial.rotation),
            angularVelocity: sample(initial.angularVelocity),
            size: sample(initial.size) * scale.x,
            color: color,
            alpha: sample(initial.alpha),
            lifetime: sample(initial.lifetime),
            frame: min(Int(random.unit() * Double(max(frameCount, 1))), max(frameCount - 1, 0)),
            oscillations: oscillations.map { (frequency: $0.0, amplitude: $0.1, phase: $0.2) },
            followDebts: Array(repeating: 0, count: followChildren.count)
        )
    }

    private func update(_ particle: inout Particle, dt: Double, drag dragStep: Double, surroundings: Surroundings) {
        for behavior in system.behaviors {
            switch behavior {
            case let .movement(gravity, drag):
                // Measured order: gravity reaches the velocity before the position
                // moves, the drag only after, so a drag that stops a particle in one
                // frame still leaves it one frame's travel along.
                particle.velocity += Self.vector(gravity) * dt
                particle.position += particle.velocity * dt
                particle.velocity *= max(1 - drag * dragStep, 0)
            case let .angularMovement(force, drag):
                particle.angularVelocity += Self.vector(force) * dt
                particle.rotation += particle.angularVelocity * dt
                particle.angularVelocity *= max(1 - drag * dragStep, 0)
            case let .attract(index, scale, threshold):
                guard let center = controlPoint(index, surroundings: surroundings) else { continue }
                let toward = center - particle.position
                let distance = simd_length(toward)
                if distance > 1e-9, distance < threshold {
                    // Fitted to the original at 30 fps (within 2 px over 3 s): fading
                    // linearly to nothing at the threshold, at 0.78 of `scale`.
                    particle.velocity += toward / distance * (0.78 * scale * (1 - distance / threshold)) * dt
                }
            default:
                break
            }
        }
        if !particle.oscillations.isEmpty {
            var offset = SIMD3<Double>.zero
            for oscillation in particle.oscillations {
                let angle = oscillation.frequency * particle.age + oscillation.phase
                offset += oscillation.amplitude * SIMD3(sin(angle.x), sin(angle.y), sin(angle.z))
            }
            particle.position += offset - particle.oscillationOffset
            particle.oscillationOffset = offset
        }
    }

    private func controlPoint(_ index: Int, surroundings: Surroundings) -> SIMD3<Double>? {
        guard let point = system.controlPoints.first(where: { $0.index == index }) else {
            return .zero
        }
        switch point.anchor {
        case .layer: return Self.vector(point.offset)
        case .pointer: return surroundings.pointer
        case .canvasCorner: return surroundings.canvasCorner
        case .none: return nil
        }
    }

    // MARK: - Sampling

    private func sample(_ range: SceneParticleSystem.Range) -> Double {
        range.min + (range.max - range.min) * pow(random.unit(), range.exponent)
    }

    private func sample(_ range: SceneParticleSystem.VectorRange) -> SIMD3<Double> {
        let low = Self.vector(range.min)
        let high = Self.vector(range.max)
        let u = SIMD3(random.unit(), random.unit(), random.unit())
        return low + (high - low) * SIMD3(pow(u.x, range.exponent), pow(u.y, range.exponent), pow(u.z, range.exponent))
    }

    private func sampleShape(_ emitter: SceneParticleSystem.Emitter) -> SIMD3<Double> {
        let directions = Self.vector(emitter.directions, fill: 1)
        let signs = Self.vector(emitter.sign)
        func signed(_ value: Double, _ axis: Int) -> Double {
            let sign = signs[axis] > 0 ? 1.0 : signs[axis] < 0 ? -1.0 : (random.unit() < 0.5 ? -1.0 : 1.0)
            return abs(value) * sign
        }
        switch emitter.shape {
        case .box:
            // Measured: a side's two values bound the distance before the random
            // sign, so a negative minimum doubles the density near the centre
            // instead of moving the box.
            let low = Self.vector(emitter.distanceMin)
            let high = Self.vector(emitter.distanceMax)
            var point = SIMD3<Double>.zero
            for axis in 0 ..< 3 {
                point[axis] = signed(low[axis] + (high[axis] - low[axis]) * random.unit(), axis)
            }
            return point * directions
        case .sphere:
            let inner = max(emitter.distanceMin.first ?? 0, 0)
            let outer = max(emitter.distanceMax.first ?? 0, inner)
            var direction: SIMD3<Double>
            repeat {
                direction = SIMD3(random.unit() * 2 - 1, random.unit() * 2 - 1, random.unit() * 2 - 1)
            } while simd_length_squared(direction) > 1 || simd_length_squared(direction) < 1e-12
            // Measured: a full ball flattened by the directions (a 0 there projects
            // it, filling the disc). An inner radius then stretches each point's
            // distance from [0, outer] onto [inner, outer], leaving the middle empty.
            var point = simd_normalize(direction) * outer * cbrt(random.unit()) * directions
            let length = simd_length(point)
            if inner > 0, outer > 0, length > 1e-12 {
                point *= (inner + (outer - inner) * length / outer) / length
            }
            for axis in 0 ..< 3 where signs[axis] != 0 { point[axis] = signed(point[axis], axis) }
            return point
        }
    }

    // MARK: - Formulas

    /// The drag applied in one frame of `dt` seconds is 1 - drag * dragStep(dt).
    /// Fitted to the frame rates measured in the original: about dt itself at 45
    /// and 60 fps, and less than dt below that (0.81 dt at 30 fps, 0.48 dt at 15).
    static func dragStep(_ dt: Double) -> Double {
        let measured: [(dt: Double, factor: Double)] = [(0.0170, 1.02), (0.0226, 1.02), (0.0333, 0.81), (0.0526, 0.60), (0.0714, 0.48)]
        guard dt > measured[0].dt else { return dt * measured[0].factor }
        for (low, high) in zip(measured, measured.dropFirst()) where dt <= high.dt {
            let t = (dt - low.dt) / (high.dt - low.dt)
            return dt * (low.factor + (high.factor - low.factor) * t)
        }
        return dt * measured[measured.count - 1].factor
    }

    static func value(of change: SceneParticleSystem.Change, at fraction: Double) -> Double {
        change.startValue + (change.endValue - change.startValue) * progress(fraction, change.startTime, change.endTime)
    }

    static func value(of change: SceneParticleSystem.ColorChange, at fraction: Double) -> SIMD3<Double> {
        let start = vector(change.startValue, fill: 1)
        return start + (vector(change.endValue, fill: 1) - start) * progress(fraction, change.startTime, change.endTime)
    }

    private static func progress(_ fraction: Double, _ start: Double, _ end: Double) -> Double {
        guard end > start else { return fraction >= end ? 1 : 0 }
        return min(max((fraction - start) / (end - start), 0), 1)
    }

    /// Measured: linear in and out. Where the fade-in has not finished when the
    /// fade-out starts, the higher of the two holds until the fade-in finishes.
    static func fade(fadeIn: Double, fadeOut: Double, at fraction: Double) -> Double {
        let rising = fadeIn > 0 ? min(fraction / fadeIn, 1) : 1
        let falling = fraction > fadeOut ? max(1 - (fraction - fadeOut) / max(1 - fadeOut, 1e-9), 0) : 1
        if fraction < fadeIn, fraction > fadeOut {
            return max(rising, falling)
        }
        return rising * falling
    }

    /// The sprite's right and up directions after its rotation (z turns clockwise
    /// on screen, x and y tilt it away), flattened onto the canvas.
    static func axes(rotation: SIMD3<Double>) -> (right: SIMD2<Double>, up: SIMD2<Double>) {
        let c = SIMD3(cos(rotation.x), cos(rotation.y), cos(rotation.z))
        let s = SIMD3(sin(rotation.x), sin(rotation.y), sin(rotation.z))
        // Rows of Rz * Rx * Ry, row vectors as the original multiplies them.
        let rz = simd_double3x3(rows: [SIMD3(c.z, -s.z, 0), SIMD3(s.z, c.z, 0), SIMD3(0, 0, 1)])
        let rx = simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, c.x, -s.x), SIMD3(0, s.x, c.x)])
        let ry = simd_double3x3(rows: [SIMD3(c.y, 0, s.y), SIMD3(0, 1, 0), SIMD3(-s.y, 0, c.y)])
        let combined = rz * rx * ry
        let right = SIMD3<Double>(1, 0, 0) * combined
        let up = SIMD3<Double>(0, 1, 0) * combined
        return (SIMD2(right.x, right.y), SIMD2(up.x, up.y))
    }

    static func vector(_ values: [Double], fill: Double = 0) -> SIMD3<Double> {
        SIMD3(values.count > 0 ? values[0] : fill, values.count > 1 ? values[1] : fill, values.count > 2 ? values[2] : fill)
    }
}

/// A small fast generator, so a layer draws the same particles from the same seed.
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0..<1
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

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
        /// A script's instance override of the layer, relative to the factors the system was
        /// built with; nil leaves the last one.
        var rateScale: Double?
        var countScale: Double?
        var sizeScale: Double?

        mutating func append(_ other: Control) {
            events += other.events
            if let emitting = other.emitting { self.emitting = emitting }
            if let rateScale = other.rateScale { self.rateScale = rateScale }
            if let countScale = other.countScale { self.countScale = countScale }
            if let sizeScale = other.sizeScale { self.sizeScale = sizeScale }
        }
    }

    /// Points the control points can follow, in the layer's space.
    struct Surroundings {
        var pointer: SIMD3<Double>?
        var canvasCorner: SIMD3<Double> = .zero
        /// The system audio; nil is silence.
        var audio: SceneAudioSpectrum?
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
        /// Distance off the layer's plane (layer pixels); only a scene seen through its camera draws it.
        var depth: Float = 0
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
        /// Per behaviour, what it picked at birth (a frequency or speed, and a phase).
        var picks: [SIMD2<Double>]
        /// Varies noise between particles.
        var seed: Double
        var bornVelocity: SIMD3<Double>
        /// Where a trail has been, newest first, and the time to the next point.
        var history: [SIMD3<Double>] = []
        var historyTimer: Double = 0
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
                                               scale: SceneParticleSimulator.vector(child.scale, fill: 1), turn: child.angleZ)
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
    private var rateScale = 1.0
    private var countScale = 1.0
    private var sizeScale = 1.0
    private let runsEmitters: Bool
    /// Moves the emitters of a child that runs on its own.
    private let originOffset: SIMD3<Double>
    /// The child's angle about z, radians.
    private let turn: Double
    /// A child's scale: on where its particles start (around the spawn point), their
    /// size and speed.
    private let scale: SIMD3<Double>
    private var nextID = 0
    private var random: SplitMix
    private var sequenceIndex = 0
    /// For behaviours drawn after the step (remaps that read a control point).
    private var lastSurroundings = Surroundings()
    /// Per emitter with periodic bursts: on or paused, the time left, and what the
    /// burst has emitted.
    private var periods: [(on: Bool, left: Double, emitted: Int)]

    var count: Int {
        particles.count
    }

    init(system: SceneParticleSystem, seed: UInt64, runsEmitters: Bool = true, originOffset: SIMD3<Double> = .zero,
         scale: SIMD3<Double> = .one, turn: Double = 0) {
        self.system = system
        self.turn = turn
        self.runsEmitters = runsEmitters
        self.originOffset = originOffset
        self.scale = scale
        random = SplitMix(seed: seed)
        debts = Array(repeating: 0, count: system.emitters.count)
        burstsDone = Array(repeating: false, count: system.emitters.count)
        periods = Array(repeating: (true, 0, 0), count: system.emitters.count)
        children = system.children.enumerated().map { index, child in
            ChildState(child, seed: seed &+ UInt64(index + 1) &* 0x9E37_79B9_7F4A_7C15)
        }
        followChildren = children.indices.filter { children[$0].trigger == .follow }
        for index in system.emitters.indices {
            if let periodic = system.emitters[index].periodic { periods[index].left = sample(periodic.duration) }
        }
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
        if let rateScale = control.rateScale { self.rateScale = rateScale }
        if let countScale = control.countScale { self.countScale = countScale }
        if let sizeScale = control.sizeScale { self.sizeScale = sizeScale }
    }

    func advance(by dt: Double, surroundings: Surroundings) {
        guard dt > 0 else { return }
        lastSurroundings = surroundings
        let drag = Self.dragStep(dt)
        var died: [SIMD3<Double>] = []
        var moved: [Int: SIMD3<Double>] = [:]
        let steering = flockSteering()
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
            update(&particle, dt: dt, drag: drag, surroundings: surroundings, steering: steering.isEmpty ? .zero : steering[index])
            if !followChildren.isEmpty { moved[particle.id] = particle.position - before }
            particles[kept] = particle
            kept += 1
        }
        particles.removeLast(particles.count - kept)
        keepDistances(surroundings: surroundings)
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
            var limit = Int.max
            if let periodic = emitter.periodic {
                periods[index].left -= dt
                while periods[index].left <= 0 {
                    periods[index].on.toggle()
                    periods[index].emitted = 0
                    periods[index].left += max(sample(periods[index].on ? periodic.duration : periodic.pause), 1e-3)
                }
                guard periods[index].on else { continue }
                if let most = periodic.maxPerBurst { limit = max(most - periods[index].emitted, 0) }
            }
            let heard = emitter.audio?.response(surroundings.audio) ?? 1
            debts[index] += emitter.rate * heard * rateScale * countScale * dt
            let owed = min(Int(debts[index]), limit)
            if owed > 0 {
                debts[index] -= Double(owed)
                periods[index].emitted += owed
                spawn(owed, emitters: index ..< index + 1, at: nil, parent: nil)
            }
            if limit == 0 { debts[index] = 0 }
        }
    }

    /// The sprites to draw, oldest first. `aspect` is a frame's height over its width.
    func instances(aspect: Double) -> [Instance] {
        var result: [Instance] = []
        result.reserveCapacity(particles.count)
        let sheet = system.sheet
        switch system.renderer {
        case .rope, .ropeTrail:
            return bands()
        default:
            break
        }
        for particle in particles {
            let (fraction, size, alpha, color) = appearance(particle)
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
            case .rope, .ropeTrail:
                continue
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
                color: SIMD4(Float(color.x), Float(color.y), Float(color.z), Float(min(max(alpha, 0), 1))),
                depth: Float(particle.position.z)
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

    /// Size (drawn, half the particle's), alpha and colour as the behaviours leave
    /// them at this point of the particle's life.
    private func appearance(_ particle: Particle) -> (fraction: Double, size: Double, alpha: Double, color: SIMD3<Double>) {
        let fraction = min(max(particle.age / max(particle.lifetime, 1e-9), 0), 1)
        var size = particle.size * 0.5
        var alpha = particle.alpha
        var color = particle.color
        for (index, behavior) in system.behaviors.enumerated() {
            switch behavior {
            case let .sizeChange(change):
                size *= Self.value(of: change, at: fraction)
            case let .alphaChange(change):
                alpha *= Self.value(of: change, at: fraction)
            case let .colorChange(change):
                color *= Self.value(of: change, at: fraction)
            case let .alphaFade(fadeIn, fadeOut):
                alpha *= Self.fade(fadeIn: fadeIn, fadeOut: fadeOut, at: fraction)
            case let .oscillateAlpha(oscillation):
                alpha *= Self.blended(Self.oscillation(oscillation, pick: particle.picks[index], age: particle.age),
                                      oscillation.ramp, fraction)
            case let .oscillateSize(oscillation):
                size *= Self.blended(Self.oscillation(oscillation, pick: particle.picks[index], age: particle.age),
                                     oscillation.ramp, fraction)
            case let .remap(remap) where [.size, .opacity, .color].contains(remap.output):
                let value = remapValue(remap, particle, fraction: fraction, surroundings: lastSurroundings)
                let weight = Self.weight(remap.ramp, fraction)
                switch remap.output {
                case .size: size = Self.mix(size, Self.apply(remap.operation, size, value.x * (remap.operation == .assign || remap.operation == .add || remap.operation == .subtract ? 0.5 : 1)), weight)
                case .opacity: alpha = Self.mix(alpha, Self.apply(remap.operation, alpha, value.x), weight)
                default:
                    color = SIMD3(Self.mix(color.x, Self.apply(remap.operation, color.x, value.x), weight),
                                  Self.mix(color.y, Self.apply(remap.operation, color.y, value.y), weight),
                                  Self.mix(color.z, Self.apply(remap.operation, color.z, value.z), weight))
                }
            default:
                break
            }
        }
        return (fraction, size, alpha, color)
    }

    /// Bands for the rope renderers: one quad per piece, along the piece, as wide
    /// as the particle is drawn.
    private func bands() -> [Instance] {
        var result: [Instance] = []
        func band(from a: SIMD3<Double>, to b: SIMD3<Double>, width: Double, color: SIMD3<Double>, alpha: Double) {
            let along = SIMD2(b.x - a.x, b.y - a.y)
            let length = simd_length(along)
            guard length > 1e-9, width > 0 else { return }
            let across = SIMD2(along.y, -along.x) / length * width
            let middle = (SIMD2(a.x, a.y) + SIMD2(b.x, b.y)) / 2
            result.append(Instance(
                center: SIMD2<Float>(middle), right: SIMD2<Float>(across), up: SIMD2<Float>(along),
                uvOrigin: .zero, uvSize: .one,
                color: SIMD4(Float(color.x), Float(color.y), Float(color.z), Float(min(max(alpha, 0), 1)))
            ))
        }
        switch system.renderer {
        case .rope:
            for (first, second) in zip(particles, particles.dropFirst()) {
                let look = appearance(first)
                band(from: first.position, to: second.position, width: look.size, color: look.color, alpha: look.alpha)
            }
        case let .ropeTrail(_, segments, fadesAlpha):
            for particle in particles {
                let look = appearance(particle)
                let points = [particle.position] + particle.history
                for (index, (a, b)) in zip(points, points.dropFirst()).enumerated() {
                    let fade = fadesAlpha ? 1 - Double(index) / Double(max(segments, 1)) : 1
                    band(from: b, to: a, width: look.size, color: look.color, alpha: look.alpha * fade)
                }
            }
        default:
            break
        }
        return result
    }

    /// Steering for a flock: per particle, the acceleration from its neighbours.
    private func flockSteering() -> [SIMD3<Double>] {
        guard let flock = system.behaviors.lazy.compactMap({ behavior -> SceneParticleSystem.Flock? in
            if case let .flock(flock) = behavior { return flock }
            return nil
        }).first, particles.count > 1, flock.neighborThreshold > 0 else { return [] }
        let cell = flock.neighborThreshold
        var grid: [SIMD2<Int>: [Int]] = [:]
        func key(_ p: SIMD3<Double>) -> SIMD2<Int> { SIMD2(Int(floor(p.x / cell)), Int(floor(p.y / cell))) }
        for index in particles.indices { grid[key(particles[index].position), default: []].append(index) }
        return particles.indices.map { index in
            let me = particles[index]
            let home = key(me.position)
            var center = SIMD3<Double>.zero, heading = SIMD3<Double>.zero, apart = SIMD3<Double>.zero
            var neighbours = 0.0
            for dx in -1 ... 1 {
                for dy in -1 ... 1 {
                    for other in grid[home &+ SIMD2(dx, dy)] ?? [] where other != index {
                        let offset = particles[other].position - me.position
                        let distance = simd_length(offset)
                        guard distance < flock.neighborThreshold else { continue }
                        center += particles[other].position
                        heading += particles[other].velocity
                        neighbours += 1
                        if distance < flock.separationThreshold, distance > 1e-9 {
                            apart -= offset / distance * (1 - distance / flock.separationThreshold)
                        }
                    }
                }
            }
            guard neighbours > 0 else { return .zero }
            return (center / neighbours - me.position) * flock.cohesionFactor * 0.1
                + (heading / neighbours - me.velocity) * flock.alignmentFactor * 0.1
                + apart * flock.separationFactor * 10
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
        let available = max(Int((Double(system.maxCount) * countScale).rounded()) - particles.count, 0)
        for number in 0 ..< min(count, available) {
            let emitter = emitters.isEmpty ? nil : system.emitters[emitters.lowerBound + number % emitters.count]
            var particle = makeParticle(emitter: emitter)
            if let point { particle.position += point }
            if !system.initial.remaps.isEmpty { applyInitialRemaps(&particle) }
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
        let seed = random.unit() * 1000
        if let turbulent = initial.turbulentVelocity {
            let wander = ParticleNoise.value(clock * turbulent.timeScale + sample(turbulent.phase), 0.5, seed * 0.001)
            let angle = (wander + turbulent.offset) * turbulent.scale * .pi
            let forward = Self.vector(turbulent.forward)
            let axis = Self.vector(turbulent.axis, fill: 0)
            velocity += Self.rotate(forward, about: axis, by: angle) * sample(turbulent.speed)
        }
        if let offset = initial.positionOffset {
            let signs = Self.vector(offset.sign)
            var shift = SIMD3<Double>.zero
            for axis in 0 ..< 3 {
                var value = ParticleNoise.fractal(clock * offset.timeScale + Double(axis) * 31.7,
                                                  position.x * offset.scale, position.y * offset.scale)
                if signs[axis] > 0 { value = abs(value) } else if signs[axis] < 0 { value = -abs(value) }
                shift[axis] = value
            }
            position += shift * offset.distance * Self.vector(offset.directions, fill: 1)
        }
        if let sequence = initial.sequence {
            let step = Double(sequenceIndex) / max(sequence.count, 1e-9)
            sequenceIndex += 1
            let raw = sequence.boundsMin + (sequence.boundsMax - sequence.boundsMin) * step
            let along = sequence.mirrors ? 1 - abs((raw.truncatingRemainder(dividingBy: 2)) - 1) : raw - floor(raw)
            switch sequence.path {
            case let .between(start, end, arc, arcDirection):
                let a = controlPoint(start, surroundings: lastSurroundings) ?? .zero
                let b = controlPoint(end, surroundings: lastSurroundings) ?? .zero
                let bend = Self.vector(arcDirection) * arc * simd_length(b - a) * sin(.pi * along)
                position += a + (b - a) * along + bend
            case let .around(index, axis, speedMin, speedMax):
                let center = controlPoint(index, surroundings: lastSurroundings) ?? .zero
                let angle = 2 * .pi * raw
                let turnAxis = Self.vector(axis)
                position = center + Self.rotate(position - center, about: turnAxis, by: angle)
                let low = Self.vector(speedMin), high = Self.vector(speedMax)
                velocity += Self.rotate(low + (high - low) * random.unit(), about: turnAxis, by: angle)
            }
        }
        velocity *= scale
        if turn != 0 {
            func turned(_ vector: SIMD3<Double>) -> SIMD3<Double> {
                SIMD3(vector.x * cos(turn) - vector.y * sin(turn), vector.x * sin(turn) + vector.y * cos(turn), vector.z)
            }
            position = originOffset + turned(position - originOffset)
            velocity = turned(velocity)
        }
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
            size: sample(initial.size) * scale.x * sizeScale,
            color: color,
            alpha: sample(initial.alpha),
            lifetime: sample(initial.lifetime),
            frame: min(Int(random.unit() * Double(max(frameCount, 1))), max(frameCount - 1, 0)),
            oscillations: oscillations.map { (frequency: $0.0, amplitude: $0.1, phase: $0.2) },
            followDebts: Array(repeating: 0, count: followChildren.count),
            picks: system.behaviors.map { behavior in
                switch behavior {
                case let .oscillateAlpha(oscillation), let .oscillateSize(oscillation):
                    return SIMD2(sample(oscillation.frequency), sample(oscillation.phase))
                case let .turbulence(turbulence):
                    return SIMD2(sample(turbulence.speed), sample(turbulence.phase))
                default:
                    return .zero
                }
            },
            seed: seed,
            bornVelocity: velocity
        )
    }

    /// Initial remaps change the values a particle is born with.
    private func applyInitialRemaps(_ particle: inout Particle) {
        for remap in system.initial.remaps {
            let value = remapValue(remap, particle, fraction: 0, surroundings: lastSurroundings)
            func applied(_ base: Double, _ x: Double) -> Double { Self.apply(remap.operation, base, x) }
            switch remap.output {
            case .size: particle.size = applied(particle.size, value.x)
            case .opacity: particle.alpha = applied(particle.alpha, value.x)
            case .color: particle.color = SIMD3(applied(particle.color.x, value.x), applied(particle.color.y, value.y), applied(particle.color.z, value.z))
            case .velocity: particle.velocity = SIMD3(applied(particle.velocity.x, value.x), applied(particle.velocity.y, value.y), applied(particle.velocity.z, value.z))
            case .speed:
                let speed = simd_length(particle.velocity)
                if speed > 1e-9 { particle.velocity *= applied(speed, value.x) / speed }
            case .rotation: particle.rotation.z = applied(particle.rotation.z, value.x)
            case .angularVelocity: particle.angularVelocity.z = applied(particle.angularVelocity.z, value.x)
            }
            particle.bornVelocity = particle.velocity
        }
    }

    private func update(_ particle: inout Particle, dt: Double, drag dragStep: Double, surroundings: Surroundings,
                        steering: SIMD3<Double>) {
        let fraction = min(max(particle.age / max(particle.lifetime, 1e-9), 0), 1)
        for (index, behavior) in system.behaviors.enumerated() {
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
            case let .turbulence(turbulence):
                // A noise acceleration through space and time. The original's noise is
                // not known; the strength and time rate are fitted to the distances its
                // particles travelled (within about 2x), and offset from the lattice,
                // where gradient noise is 0.
                let weight = Self.weight(turbulence.ramp, fraction)
                guard weight > 0 else { continue }
                let time = clock * turbulence.timeScale * 0.001 + particle.picks[index].y + 0.37
                let p = particle.position * turbulence.scale + 0.37
                let push = SIMD3(ParticleNoise.value(p.x, p.y, time),
                                 ParticleNoise.value(p.x + 31.4, p.y - 17.2, time + 5.3),
                                 ParticleNoise.value(p.x - 23.9, p.y + 41.7, time - 8.1))
                particle.velocity += push * Self.vector(turbulence.mask) * particle.picks[index].x * Self.turbulenceStrength * weight * dt
            case let .vortex(vortex):
                let weight = Self.weight(vortex.ramp, fraction)
                guard weight > 0, let point = controlPoint(vortex.controlPoint, surroundings: surroundings) else { continue }
                let axis = simd_length(Self.vector(vortex.axis)) > 1e-9 ? simd_normalize(Self.vector(vortex.axis)) : SIMD3(0, 0, 1)
                var radial = particle.position - (point + Self.vector(vortex.offset))
                radial -= axis * simd_dot(radial, axis)
                let distance = simd_length(radial)
                guard distance > 1e-9 else { continue }
                let span = vortex.distanceOuter - vortex.distanceInner
                let speed = distance <= vortex.distanceInner ? vortex.speedInner : distance >= vortex.distanceOuter || span <= 0
                    ? vortex.speedOuter : vortex.speedInner + (vortex.speedOuter - vortex.speedInner) * (distance - vortex.distanceInner) / span
                // Fitted to the original at 30 fps (within 1 px over 1.5 s): an
                // acceleration round the axis, clockwise about +z, at 0.83 of the speed.
                particle.velocity += simd_normalize(simd_cross(radial, axis)) * 0.83 * speed * weight * dt
            case let .capVelocity(maxSpeed, ramp):
                let weight = Self.weight(ramp, fraction)
                let speed = simd_length(particle.velocity)
                if weight > 0, speed > maxSpeed, speed > 1e-9 {
                    particle.velocity *= 1 - weight + weight * maxSpeed / speed
                }
            case let .reduceMovement(reduce):
                guard let point = controlPoint(reduce.controlPoint, surroundings: surroundings) else { continue }
                let distance = simd_length(particle.position - point)
                let span = reduce.distanceOuter - reduce.distanceInner
                let amount = distance <= reduce.distanceInner ? reduce.reductionInner : distance >= reduce.distanceOuter || span <= 0
                    ? reduce.reductionOuter : reduce.reductionInner + (reduce.reductionOuter - reduce.reductionInner) * (distance - reduce.distanceInner) / span
                particle.velocity *= exp(-amount * dt)
            case let .flock(flock):
                particle.velocity += steering * dt
                if let maxSpeed = flock.maxSpeed, simd_length(particle.velocity) > maxSpeed {
                    particle.velocity = simd_normalize(particle.velocity) * maxSpeed
                }
            case let .remap(remap) where [.velocity, .speed, .rotation, .angularVelocity].contains(remap.output):
                let weight = Self.weight(remap.ramp, fraction)
                guard weight > 0 else { continue }
                let value = remapValue(remap, particle, fraction: fraction, surroundings: surroundings)
                // Each frame from the value at birth, so a multiply does not compound.
                switch remap.output {
                case .velocity:
                    let base = particle.bornVelocity
                    let target = SIMD3(Self.apply(remap.operation, base.x, value.x), Self.apply(remap.operation, base.y, value.y),
                                       Self.apply(remap.operation, base.z, value.z))
                    particle.velocity += (target - particle.velocity) * weight
                case .speed:
                    let speed = simd_length(particle.velocity)
                    let target = Self.apply(remap.operation, simd_length(particle.bornVelocity), value.x)
                    if speed > 1e-9 { particle.velocity *= Self.mix(speed, target, weight) / speed }
                case .rotation:
                    particle.rotation.z = Self.mix(particle.rotation.z, Self.apply(remap.operation, particle.rotation.z, value.x), weight)
                default:
                    particle.angularVelocity.z = Self.mix(particle.angularVelocity.z, Self.apply(remap.operation, particle.angularVelocity.z, value.x), weight)
                }
            default:
                break
            }
        }
        if !particle.oscillations.isEmpty {
            var offset = SIMD3<Double>.zero
            var oscillationIndex = 0
            for behavior in system.behaviors {
                guard case let .oscillatePosition(settings) = behavior else { continue }
                let oscillation = particle.oscillations[oscillationIndex]
                oscillationIndex += 1
                let angle = oscillation.frequency * particle.age + oscillation.phase
                offset += oscillation.amplitude * SIMD3(sin(angle.x), sin(angle.y), sin(angle.z)) * Self.weight(settings.ramp, fraction)
            }
            particle.position += offset - particle.oscillationOffset
            particle.oscillationOffset = offset
        }
        if case let .ropeTrail(length, segments, _) = system.renderer, segments > 0 {
            particle.historyTimer -= dt
            if particle.historyTimer <= 0 {
                particle.history.insert(particle.position, at: 0)
                if particle.history.count > segments { particle.history.removeLast(particle.history.count - segments) }
                particle.historyTimer += length / Double(segments)
            }
        }
    }

    /// Scales the noise in `turbulence` to the original's displacements.
    static let turbulenceStrength = 0.3

    private func remapValue(_ remap: SceneParticleSystem.Remap, _ particle: Particle, fraction: Double,
                            surroundings: Surroundings) -> SIMD3<Double> {
        let input: Double
        switch remap.input {
        case .lifetimeFraction: input = fraction
        case .particleSystemTime, .runtime: input = clock
        case .timeOfDay:
            let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
            let hours = parts.hour ?? 0, minutes = parts.minute ?? 0, seconds = parts.second ?? 0
            input = Double(hours * 3600 + minutes * 60 + seconds) / 86400
        case .speed: input = simd_length(particle.velocity)
        case .distanceToControlPoint:
            input = simd_length(particle.position - (controlPoint(remap.controlPoint, surroundings: surroundings) ?? .zero))
        }
        var x = remap.inputMax != remap.inputMin ? (input - remap.inputMin) / (remap.inputMax - remap.inputMin) : 0
        if remap.clampsInput { x = min(max(x, 0), 1) }
        func shaped(_ offset: Double) -> Double {
            let t = x * remap.transformScale
            switch remap.transform {
            case .none: return x
            case .sine: return 0.5 + 0.5 * sin(t)
            case .square: return sin(t) >= 0 ? 1 : 0
            case .saw: return t / (2 * .pi) - floor(t / (2 * .pi))
            case .triangle: return 1 - abs(2 * (t / (2 * .pi) - floor(t / (2 * .pi))) - 1)
            case .noise: return 0.5 + 0.5 * ParticleNoise.value(t, particle.seed + offset, 0.5)
            case .fractalNoise: return 0.5 + 0.5 * ParticleNoise.fractal(t, particle.seed + offset, 0.5)
            }
        }
        let low = Self.vector(remap.outputMin), high = Self.vector(remap.outputMax)
        return low + (high - low) * SIMD3(shaped(0), shaped(17.3), shaped(41.9))
    }

    /// The two control points of each maintain-distance behavior as of the last frame.
    private var maintained: [Int: (SIMD3<Double>, SIMD3<Double>)] = [:]

    /// Measured on a still particle while the points were moved: the particle keeps its
    /// residual and its share u along the old line is recomputed from where it is now. A new
    /// line of zero length leaves the particles where they were.
    private func keepDistances(surroundings: Surroundings) {
        for (index, behavior) in system.behaviors.enumerated() {
            guard case let .maintainDistance(first, second) = behavior,
                  let start = controlPoint(first, surroundings: surroundings),
                  let end = controlPoint(second, surroundings: surroundings)
            else { continue }
            defer { maintained[index] = (start, end) }
            guard let (oldStart, oldEnd) = maintained[index] else { continue }
            let oldLine = oldEnd - oldStart
            let newLine = end - start
            let length = simd_length_squared(oldLine)
            guard simd_length_squared(newLine) > 1e-12, length > 1e-12 else { continue }
            for slot in particles.indices {
                let u = simd_dot(particles[slot].position - oldStart, oldLine) / length
                particles[slot].position += (start - oldStart) + u * (newLine - oldLine)
            }
        }
    }

    private func controlPoint(_ index: Int, surroundings: Surroundings) -> SIMD3<Double>? {
        guard let point = system.controlPoints.first(where: { $0.index == index }) else {
            return .zero
        }
        switch point.anchor {
        case .layer: return Self.vector(point.offset)
        case .pointer: return surroundings.pointer
        case .canvasCorner: return surroundings.canvasCorner + Self.vector(point.offset)
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
            if let cone = emitter.cone, cone != 0 {
                // Measured (Windows, fixed radius): the cone bounds the direction before the
                // directions are applied, and the result is renormalised, so cone 1 is a
                // point on +X whatever the directions are. Radius is rmin + (rmax - rmin) * cbrt(u).
                let lowX = -cos(Double.pi * min(max(cone, 0), 1))
                let x = lowX + (1 - lowX) * random.unit()
                let ring = (1 - x * x).squareRoot()
                let angle = 2 * Double.pi * random.unit()
                let stretched = SIMD3(x, ring * cos(angle), ring * sin(angle)) * directions
                let length = simd_length(stretched)
                var point = length > 1e-12 ? stretched / length * (inner + (outer - inner) * cbrt(random.unit())) : .zero
                for axis in 0 ..< 3 where signs[axis] != 0 { point[axis] = signed(point[axis], axis) }
                return point
            }
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

    /// How much of a behaviour acts at this point of the life.
    static func weight(_ ramp: SceneParticleSystem.Ramp?, _ fraction: Double) -> Double {
        guard let blend = ramp else { return 1 }
        let rising = fraction < blend.inStart ? 0 : blend.inEnd > blend.inStart ? min((fraction - blend.inStart) / (blend.inEnd - blend.inStart), 1) : 1
        let falling = fraction >= blend.outEnd ? 0 : blend.outEnd > blend.outStart ? min(max((blend.outEnd - fraction) / (blend.outEnd - blend.outStart), 0), 1) : 1
        return rising * falling
    }

    /// A multiplier that acts only as much as the blend allows.
    static func blended(_ value: Double, _ ramp: SceneParticleSystem.Ramp?, _ fraction: Double) -> Double {
        mix(1, value, weight(ramp, fraction))
    }

    static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    static func apply(_ operation: SceneParticleSystem.Remap.Operation, _ base: Double, _ value: Double) -> Double {
        switch operation {
        case .assign: return value
        case .multiply: return base * value
        case .add: return base + value
        case .subtract: return base - value
        }
    }

    /// Between the amplitude's min and max along a sine of the particle's own
    /// frequency (radians per second, as measured for position) and phase.
    static func oscillation(_ oscillation: SceneParticleSystem.Oscillation, pick: SIMD2<Double>, age: Double) -> Double {
        let wave = 0.5 + 0.5 * sin(pick.x * age + pick.y)
        return oscillation.amplitude.min + (oscillation.amplitude.max - oscillation.amplitude.min) * wave
    }

    static func rotate(_ vector: SIMD3<Double>, about axis: SIMD3<Double>, by angle: Double) -> SIMD3<Double> {
        guard simd_length(axis) > 1e-9 else { return vector }
        let k = simd_normalize(axis)
        return vector * cos(angle) + simd_cross(k, vector) * sin(angle) + k * simd_dot(k, vector) * (1 - cos(angle))
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

/// Smooth gradient noise, about -1...1, the same everywhere for the same input.
enum ParticleNoise {
    private static let permutation: [Int] = {
        var random = SplitMix(seed: 0x5EED)
        var values = Array(0 ..< 256)
        for index in stride(from: 255, to: 0, by: -1) {
            values.swapAt(index, Int(random.next() % UInt64(index + 1)))
        }
        return values + values
    }()

    static func value(_ x: Double, _ y: Double, _ z: Double) -> Double {
        let xi = Int(floor(x)) & 255, yi = Int(floor(y)) & 255, zi = Int(floor(z)) & 255
        let xf = x - floor(x), yf = y - floor(y), zf = z - floor(z)
        func fade(_ t: Double) -> Double { t * t * t * (t * (t * 6 - 15) + 10) }
        func gradient(_ hash: Int, _ x: Double, _ y: Double, _ z: Double) -> Double {
            let h = hash & 15
            let u = h < 8 ? x : y
            let v = h < 4 ? y : (h == 12 || h == 14 ? x : z)
            return ((h & 1) == 0 ? u : -u) + ((h & 2) == 0 ? v : -v)
        }
        let p = permutation
        let a = p[xi] + yi, aa = p[a] + zi, ab = p[a + 1] + zi
        let b = p[xi + 1] + yi, ba = p[b] + zi, bb = p[b + 1] + zi
        let u = fade(xf), v = fade(yf), w = fade(zf)
        func lerp(_ t: Double, _ a: Double, _ b: Double) -> Double { a + t * (b - a) }
        return lerp(w,
                    lerp(v, lerp(u, gradient(p[aa], xf, yf, zf), gradient(p[ba], xf - 1, yf, zf)),
                         lerp(u, gradient(p[ab], xf, yf - 1, zf), gradient(p[bb], xf - 1, yf - 1, zf))),
                    lerp(v, lerp(u, gradient(p[aa + 1], xf, yf, zf - 1), gradient(p[ba + 1], xf - 1, yf, zf - 1)),
                         lerp(u, gradient(p[ab + 1], xf, yf - 1, zf - 1), gradient(p[bb + 1], xf - 1, yf - 1, zf - 1))))
    }

    /// Three octaves, halving the amplitude and doubling the frequency each time.
    static func fractal(_ x: Double, _ y: Double, _ z: Double) -> Double {
        var total = 0.0, amplitude = 1.0, frequency = 1.0, norm = 0.0
        for _ in 0 ..< 3 {
            total += value(x * frequency, y * frequency, z * frequency) * amplitude
            norm += amplitude
            amplitude *= 0.5
            frequency *= 2
        }
        return total / norm
    }
}

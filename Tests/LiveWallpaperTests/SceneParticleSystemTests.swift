@testable import LiveWallpaper
import simd
import XCTest

/// The behaviours measured in the scenes this follows, at their 30 updates a second.
final class SceneParticleSystemTests: XCTestCase {
    private let step = 1.0 / 30

    private func system(_ change: (inout SceneParticleSystem) -> Void = { _ in }) -> SceneParticleSystem {
        var system = SceneParticleSystem()
        system.emitters = [.init(shape: .box)]
        system.initial.lifetime = .fixed(100)
        system.initial.size = .fixed(16)
        system.behaviors = [.movement(gravity: [0, 0, 0], drag: 0)]
        change(&system)
        return system
    }

    private func run(_ simulator: SceneParticleSimulator, seconds: Double) {
        for _ in 0 ..< Int((seconds / step).rounded()) {
            simulator.advance(by: step, surroundings: .init())
        }
    }

    func testSphereConeBoundsTheDirectionAroundPlusXBeforeTheDirectionsApply() {
        func born(cone: Double, directions: [Double]) -> [SIMD2<Double>] {
            let simulator = SceneParticleSimulator(system: system {
                $0.emitters = [.init(shape: .sphere)]
                $0.emitters[0].distanceMin = [70, 70, 70]
                $0.emitters[0].distanceMax = [70, 70, 70]
                $0.emitters[0].directions = directions
                $0.emitters[0].cone = cone
                $0.maxCount = 400
            }, seed: 3)
            simulator.apply(.init(events: [.emit(400)]))
            return simulator.instances(aspect: 1).map { SIMD2(Double($0.center.x), Double($0.center.y)) }
        }
        for point in born(cone: 1, directions: [0.1, 0.1, 1]) {
            XCTAssertEqual(point.x, 70, accuracy: 1e-3)
            XCTAssertEqual(point.y, 0, accuracy: 1e-3)
        }
        let half = born(cone: 0.5, directions: [1, 1, 1])
        XCTAssertTrue(half.allSatisfy { $0.x >= -1e-3 })
        XCTAssertTrue(half.contains { $0.x < 5 })
        let quarter = born(cone: 0.25, directions: [1, 1, 0])
        XCTAssertTrue(quarter.allSatisfy { abs(simd_length($0) - 70) < 1e-3 })
        XCTAssertEqual(quarter.map(\.x).min() ?? 0, -70, accuracy: 1)
    }

    func testEmitAddsClearRemovesAndTheLimitHolds() {
        let simulator = SceneParticleSimulator(system: system { $0.maxCount = 8 }, seed: 1)
        simulator.apply(.init(events: [.emit(3)]))
        XCTAssertEqual(simulator.count, 3)
        simulator.apply(.init(events: [.emit(10)]))
        XCTAssertEqual(simulator.count, 8)
        simulator.apply(.init(events: [.clear, .emit(2)]))
        XCTAssertEqual(simulator.count, 2)
    }

    func testStoppedEmittersKeepTheParticlesMovingAndAging() {
        let simulator = SceneParticleSimulator(system: system {
            $0.emitters[0].rate = 30
            $0.initial.lifetime = .fixed(1)
            $0.initial.velocity = .init([20, 0, 0], [20, 0, 0])
        }, seed: 1)
        simulator.apply(.init(emitting: false))
        simulator.apply(.init(events: [.emit(1)]))
        run(simulator, seconds: 0.5)
        XCTAssertEqual(simulator.instances(aspect: 1).first!.center.x, 10, accuracy: 0.5)
        run(simulator, seconds: 0.6)
        XCTAssertEqual(simulator.count, 0)
    }

    func testDragAt30FramesASecondDecaysAtAbout0_82PerSecondPerDrag() {
        let simulator = SceneParticleSimulator(system: system {
            $0.initial.velocity = .init([50, 0, 0], [50, 0, 0])
            $0.behaviors = [.movement(gravity: [0, 0, 0], drag: 1)]
        }, seed: 1)
        simulator.apply(.init(events: [.emit(1)]))
        run(simulator, seconds: 2)
        let k = 0.82
        XCTAssertEqual(Double(simulator.instances(aspect: 1).first!.center.x), 50 / k * (1 - exp(-k * 2)), accuracy: 2)
    }

    func testADragThatStopsAParticleInOneFrameLeavesOneFrameOfTravel() {
        let simulator = SceneParticleSimulator(system: system {
            $0.initial.velocity = .init([600, 0, 0], [600, 0, 0])
            $0.behaviors = [.movement(gravity: [0, 0, 0], drag: 80)]
        }, seed: 1)
        simulator.apply(.init(events: [.emit(1)]))
        run(simulator, seconds: 1)
        XCTAssertEqual(simulator.instances(aspect: 1).first!.center.x, 20, accuracy: 0.01)
    }

    func testSpritesAreDrawnAtHalfTheirSizeTimesTheSizeChange() {
        let simulator = SceneParticleSimulator(system: system {
            $0.initial.size = .fixed(30)
            $0.initial.lifetime = .fixed(2)
            $0.behaviors.append(.sizeChange(.init(startTime: 0, endTime: 0.5, startValue: 1, endValue: 0)))
        }, seed: 1)
        simulator.apply(.init(events: [.emit(1)]))
        XCTAssertEqual(simulator.instances(aspect: 1).first!.right.x, 15, accuracy: 0.01)
        run(simulator, seconds: 0.4)
        XCTAssertEqual(simulator.instances(aspect: 1).first!.right.x, 9, accuracy: 0.01)
        run(simulator, seconds: 0.7)
        XCTAssertTrue(simulator.instances(aspect: 1).isEmpty)
        XCTAssertEqual(simulator.count, 1)
    }

    func testScriptedInstanceFactorsScaleEmissionCapAndSizeFromThenOn() {
        let simulator = SceneParticleSimulator(system: system {
            $0.maxCount = 1000
            $0.emitters[0].rate = 30
            $0.initial.size = .fixed(30)
        }, seed: 1)
        run(simulator, seconds: 1)
        XCTAssertEqual(simulator.count, 30, accuracy: 1)
        simulator.apply(.init(rateScale: 2, sizeScale: 2))
        run(simulator, seconds: 1)
        XCTAssertEqual(simulator.count, 90, accuracy: 2)
        XCTAssertEqual(simulator.instances(aspect: 1).first!.right.x, 15, accuracy: 0.01)
        XCTAssertEqual(simulator.instances(aspect: 1).last!.right.x, 30, accuracy: 0.01)
        simulator.apply(.init(rateScale: 1, countScale: 0.05))
        run(simulator, seconds: 1)
        XCTAssertEqual(simulator.count, 90, accuracy: 0)
    }

    func testAlphaFadeHoldsTheHigherFadeWhereTheyOverlap() {
        XCTAssertEqual(SceneParticleSimulator.fade(fadeIn: 0.5, fadeOut: 0.5, at: 0.25), 0.5, accuracy: 1e-9)
        XCTAssertEqual(SceneParticleSimulator.fade(fadeIn: 0.5, fadeOut: 0.5, at: 0.75), 0.5, accuracy: 1e-9)
        XCTAssertEqual(SceneParticleSimulator.fade(fadeIn: 0, fadeOut: 0, at: 0.25), 0.75, accuracy: 1e-9)
        // fadeIn 0.7, fadeOut 0.3: high in between, then the fade-out line.
        XCTAssertEqual(SceneParticleSimulator.fade(fadeIn: 0.7, fadeOut: 0.3, at: 0.31), 0.986, accuracy: 0.001)
        XCTAssertEqual(SceneParticleSimulator.fade(fadeIn: 0.7, fadeOut: 0.3, at: 0.75), 0.357, accuracy: 0.001)
    }

    func testTrailLengthFollowsTheSpeedWithinItsBounds() {
        let simulator = SceneParticleSimulator(system: system {
            $0.initial.size = .fixed(20)
            $0.initial.velocity = .init([100, 0, 0], [100, 0, 0])
            $0.renderer = .trail(length: 0.02, minLength: 5, maxLength: 100)
        }, seed: 1)
        simulator.apply(.init(events: [.emit(1)]))
        let sprite = simulator.instances(aspect: 1).first!
        XCTAssertEqual(sprite.up.x, 50, accuracy: 0.01)
        XCTAssertEqual(abs(sprite.right.y), 10, accuracy: 0.01)
    }

    func testRotationTurnsClockwise() {
        let axes = SceneParticleSimulator.axes(rotation: [0, 0, .pi / 6])
        XCTAssertEqual(atan2(axes.right.y, axes.right.x), -.pi / 6, accuracy: 1e-9)
    }

    func testFollowingChildrenMoveWithTheirParentWhileItLives() {
        var child = SceneParticleSystem()
        child.emitters = [.init(shape: .box, burst: 1)]
        child.initial.lifetime = .fixed(5)
        child.behaviors = [.movement(gravity: [0, 0, 0], drag: 0)]
        let simulator = SceneParticleSimulator(system: system {
            $0.initial.lifetime = .fixed(1)
            $0.initial.velocity = .init([100, 0, 0], [100, 0, 0])
            $0.children = [.init(trigger: .follow, system: .init(child))]
        }, seed: 1)
        simulator.apply(.init(events: [.emit(1)]))
        run(simulator, seconds: 0.5)
        var sprites: [SceneParticleSimulator.Instance] = []
        simulator.forEach { sprites += $0.instances(aspect: 1) }
        XCTAssertEqual(sprites.count, 2)
        XCTAssertEqual(sprites[0].center.x, sprites[1].center.x, accuracy: 0.01)
    }

    func testVortexTurnsClockwiseAboutPlusZAtTheFittedRate() {
        let simulator = SceneParticleSimulator(system: system {
            $0.emitters = [.init(shape: .box, distanceMin: [40, 0, 0], distanceMax: [40, 0, 0], sign: [1, 0, 0])]
            $0.behaviors.append(.vortex(.init(distanceInner: 0, distanceOuter: 100, speedInner: 100, speedOuter: 100)))
        }, seed: 1)
        simulator.apply(.init(events: [.emit(1)]))
        run(simulator, seconds: 0.5)
        let sprite = simulator.instances(aspect: 1).first!
        // Tangential acceleration 0.83 * 100 from rest: about 0.5 * 83 * 0.5^2 down.
        XCTAssertEqual(Double(sprite.center.y), -0.5 * 83 * 0.25, accuracy: 1.5)
        XCTAssertGreaterThan(sprite.center.x, 38)
    }

    func testRampBringsABehaviourInAndOut() {
        let ramp = SceneParticleSystem.Ramp(inStart: 0.2, inEnd: 0.4, outStart: 0.6, outEnd: 0.8)
        XCTAssertEqual(SceneParticleSimulator.weight(ramp, 0.1), 0)
        XCTAssertEqual(SceneParticleSimulator.weight(ramp, 0.3), 0.5, accuracy: 1e-9)
        XCTAssertEqual(SceneParticleSimulator.weight(ramp, 0.5), 1)
        XCTAssertEqual(SceneParticleSimulator.weight(ramp, 0.7), 0.5, accuracy: 1e-9)
        XCTAssertEqual(SceneParticleSimulator.weight(ramp, 0.9), 0)
        XCTAssertEqual(SceneParticleSimulator.weight(nil, 0.9), 1)
    }

    func testOscillatingAlphaStaysWithinItsBounds() {
        let simulator = SceneParticleSimulator(system: system {
            $0.behaviors.append(.oscillateAlpha(.init(frequency: .init(5, 5), amplitude: .init(0.2, 0.6), phase: .init(0, 6))))
        }, seed: 3)
        simulator.apply(.init(events: [.emit(20)]))
        for _ in 0 ..< 30 {
            run(simulator, seconds: step)
            for sprite in simulator.instances(aspect: 1) {
                XCTAssertGreaterThanOrEqual(sprite.color.w, 0.2 - 1e-5)
                XCTAssertLessThanOrEqual(sprite.color.w, 0.6 + 1e-5)
            }
        }
    }

    func testPeriodicEmittersPauseAndCapEachBurst() {
        let simulator = SceneParticleSimulator(system: system {
            $0.maxCount = 1000
            $0.emitters[0].rate = 100
            $0.emitters[0].periodic = .init(duration: .init(1, 1), pause: .init(1, 1), maxPerBurst: 30)
        }, seed: 1)
        run(simulator, seconds: 1.5)
        XCTAssertEqual(simulator.count, 30)
        run(simulator, seconds: 1.0)
        XCTAssertEqual(simulator.count, 60)
    }

    func testRopeJoinsEachParticleToTheNext() {
        let simulator = SceneParticleSimulator(system: system {
            $0.emitters = [.init(shape: .box, distanceMax: [100, 0, 0])]
            $0.renderer = .rope
        }, seed: 1)
        simulator.apply(.init(events: [.emit(4)]))
        XCTAssertEqual(simulator.instances(aspect: 1).count, 3)
    }

    func testANewLayerFillsTheScreenOnTheFirstFrameAndRises() {
        let simulator = SceneParticleSimulator(
            system: .risingLights(canvasWidth: 1920, canvasHeight: 1080, textureFile: nil), seed: 1
        )
        let first = simulator.instances(aspect: 1)
        XCTAssertGreaterThan(first.count, 150)
        XCTAssertLessThanOrEqual(first.count, 400)
        // Up to 10 s of sideways drift (15 px/s) and sway (16 px) past the edges.
        XCTAssertTrue(first.allSatisfy { abs($0.center.x) <= 960 + 15 * 10 + 16 })
        XCTAssertGreaterThan(first.map { Double($0.center.y) }.max()!, 0, "some have risen past the middle")
        simulator.apply(.init(events: [.clear, .emit(1)], emitting: false))
        let born = simulator.instances(aspect: 1).first!.center.y
        run(simulator, seconds: 1)
        // The slowest rise is 4% of the height a second.
        XCTAssertGreaterThan(Double(simulator.instances(aspect: 1).first!.center.y - born), 1080 * 0.04 - 1)
    }
}

@testable import LiveWallpaper
import XCTest

final class SceneMotionTests: XCTestCase {
    private func sample(_ time: Double, x: Double, opacity: Double = 1) -> SceneMotion.Sample {
        var transform = SceneTransform()
        transform.offsetX = x
        return SceneMotion.Sample(time: time, transform: transform, opacity: opacity)
    }

    func testFollowsSamplesInStraightLinesAndRestsOnTheLast() {
        let motion = SceneMotion(samples: [sample(0, x: 0, opacity: 1), sample(2, x: 0.4, opacity: 0)], loopStart: nil)
        XCTAssertEqual(motion.pose(at: 1).transform.offsetX, 0.2, accuracy: 1e-12)
        XCTAssertEqual(motion.pose(at: 1.5).opacity, 0.25, accuracy: 1e-12)
        XCTAssertEqual(motion.pose(at: 10).transform.offsetX, 0.4)
        XCTAssertEqual(motion.pose(at: -1).transform.offsetX, 0)
    }

    func testRepeatsFromLoopStartAfterAnIntro() {
        let motion = SceneMotion(samples: [sample(0, x: 0), sample(1, x: 1), sample(3, x: -1)], loopStart: 1)
        XCTAssertEqual(motion.pose(at: 4).transform.offsetX, 0, accuracy: 1e-12)
        XCTAssertEqual(motion.pose(at: 0.5).transform.offsetX, 0.5, accuracy: 1e-12)
    }

    func testTwoSamplesAtOneTimeJump() {
        // A loop that reaches 1 and starts over at 0.
        let motion = SceneMotion(samples: [sample(0, x: 0), sample(2, x: 1), sample(2, x: 0), sample(4, x: 1)], loopStart: 0)
        XCTAssertEqual(motion.pose(at: 1.999).transform.offsetX, 0.9995, accuracy: 1e-9)
        XCTAssertEqual(motion.pose(at: 2).transform.offsetX, 0)
        XCTAssertEqual(motion.pose(at: 3).transform.offsetX, 0.5, accuracy: 1e-12)
    }

    func testMotionReplacesKeyframesAndMakesTheSceneRunInRealTime() throws {
        var layer = SceneLayer(name: "a", imageFile: "a.png")
        layer.keyframes = [SceneKeyframe(time: 0, transform: .identity), SceneKeyframe(time: 0.5, transform: .identity)]
        layer.motion = SceneMotion(samples: [sample(0, x: 0), sample(1, x: 0.5)], loopStart: nil)
        XCTAssertEqual(layer.pose(at: 0.25, time: 0.5).transform.offsetX, 0.25, accuracy: 1e-12)
        let document = SceneDocument(canvasWidth: 100, canvasHeight: 100, layers: [layer])
        XCTAssertTrue(document.isAnimated)
        XCTAssertTrue(document.requiresRealTimePlayback)
        let decoded = try JSONDecoder().decode(SceneDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded.layers[0].motion, layer.motion)
    }
}

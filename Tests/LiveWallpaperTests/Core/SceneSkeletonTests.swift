@testable import LiveWallpaper
import simd
import XCTest

final class SceneSkeletonTests: XCTestCase {
    private let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

    func testRestPoseUsesInverseBindAndUnorderedHierarchy() throws {
        var inverse = identity
        inverse[12] = -3
        let skeleton = SceneSkeleton(bones: [
            .init(
                name: "child",
                parent: 1,
                rest: .init(translation: [1, 0, 0]),
                inverseBind: inverse
            ),
            .init(name: "root", rest: .init(translation: [2, 0, 0]), inverseBind: {
                var matrix = identity
                matrix[12] = -2
                return matrix
            }())
        ], clips: [], playback: [], attachments: [
            .init(name: "tip", bone: 0, transform: identity)
        ])
        let pose = try SceneSkeletonEvaluator(skeleton).evaluate(time: 0)
        for matrix in pose.matrices {
            XCTAssertEqual(matrix.columns.3, SIMD4(0, 0, 0, 1))
            XCTAssertEqual(matrix.columns.0, SIMD4(1, 0, 0, 0))
        }
        XCTAssertEqual(pose.attachments["tip"]?.columns.3, SIMD4(3, 0, 0, 1))
    }

    func testInterpolationLoopReverseAndClampedEnd() throws {
        var skeleton = SceneSkeleton(
            bones: [.init(name: "root", rest: .init(), inverseBind: identity)],
            clips: [.init(name: "move", framesPerSecond: 2, frameCount: 1, tracks: [
                .init(
                    bone: 0,
                    transforms: [.init(), .init(translation: [4, 0, 0])],
                    opacity: [1, 0]
                )
            ])], playback: [.init(clip: 0)]
        )
        var evaluator = try SceneSkeletonEvaluator(skeleton)
        XCTAssertEqual(evaluator.evaluate(time: 0.125).matrices[0].columns.3.x, 1)
        XCTAssertEqual(evaluator.evaluate(time: 0.125).opacity[0], 0.75)
        XCTAssertEqual(evaluator.evaluate(time: 0.5).matrices[0].columns.3.x, 0)
        skeleton.playback[0].rate = -1
        evaluator = try SceneSkeletonEvaluator(skeleton)
        XCTAssertEqual(evaluator.evaluate(time: 0.125).matrices[0].columns.3.x, 3)
        skeleton.playback[0].loops = false
        skeleton.playback[0].rate = 1
        evaluator = try SceneSkeletonEvaluator(skeleton)
        XCTAssertEqual(evaluator.evaluate(time: 10).matrices[0].columns.3.x, 4)
        XCTAssertEqual(evaluator.evaluate(time: 10).opacity[0], 0)
        skeleton.playback[0].loops = true
        skeleton.playback[0].mirrors = true
        evaluator = try SceneSkeletonEvaluator(skeleton)
        XCTAssertEqual(evaluator.evaluate(time: 0.5).matrices[0].columns.3.x, 4)
        XCTAssertEqual(evaluator.evaluate(time: 0.625).matrices[0].columns.3.x, 3)
        XCTAssertEqual(evaluator.evaluate(time: 1).matrices[0].columns.3.x, 0)
    }

    func testNormalAndAdditiveClipsAndRotationMoveAttachment() throws {
        let rest = SceneSkeleton.Transform(translation: [2, 0, 0])
        let turn = SceneSkeleton.Transform(translation: [6, 0, 0], rotation: [0, 0, 1, 0])
        var socket = identity
        socket[12] = 1
        let skeleton = SceneSkeleton(
            bones: [.init(name: "root", rest: rest, inverseBind: identity)],
            clips: [
                .init(name: "turn", framesPerSecond: 1, frameCount: 0, tracks: [
                    .init(bone: 0, transforms: [turn], opacity: [0.5])
                ]),
                .init(name: "add", framesPerSecond: 1, frameCount: 0, tracks: [
                    .init(bone: 0, transforms: [.init(translation: [4, 0, 0])])
                ])
            ], playback: [.init(clip: 0, weight: 0.5), .init(clip: 1, weight: 0.5, additive: true)],
            attachments: [.init(name: "socket", bone: 0, transform: socket)]
        )
        let pose = try SceneSkeletonEvaluator(skeleton).evaluate(time: 4)
        XCTAssertEqual(pose.matrices[0].columns.3.x, 5, accuracy: 0.0001)
        let point = try XCTUnwrap(pose.attachments["socket"]).columns.3
        XCTAssertEqual(point.x, 5, accuracy: 0.0001)
        XCTAssertEqual(abs(point.y), 1, accuracy: 0.0001)
        XCTAssertEqual(pose.opacity[0], 0.75)
    }

    func testLayersBlendWithNormalizedLerpAndFlipToTheShortArc() throws {
        func turn(_ angle: Float, sign: Float = 1) -> SceneSkeleton.Transform {
            let q = simd_quatf(angle: angle, axis: [0, 0, 1]).vector * sign
            return .init(rotation: [q.x, q.y, q.z, q.w])
        }
        let skeleton = SceneSkeleton(
            bones: [.init(name: "root", rest: .init(), inverseBind: identity)],
            clips: [
                .init(name: "a", framesPerSecond: 1, frameCount: 1, tracks: [.init(bone: 0, transforms: [turn(0), turn(0)])]),
                // The same quarter-pitch turn stored as the negated quaternion.
                .init(name: "b", framesPerSecond: 1, frameCount: 1, tracks: [.init(bone: 0, transforms: [turn(.pi, sign: -1), turn(.pi, sign: -1)])])
            ],
            playback: [.init(clip: 0), .init(clip: 1, weight: 0.25)]
        )
        let matrix = try SceneSkeletonEvaluator(skeleton).evaluate(time: 0).matrices[0]
        // normalize(0.75 * (0,0,0,1) + 0.25 * (0,0,1,0)) is the angle 2 * atan(1/3), not a quarter of pi.
        let expected = 2 * atan(Float(1) / 3)
        XCTAssertEqual(atan2(matrix.columns.0.y, matrix.columns.0.x), expected, accuracy: 1e-5)
    }

    func testMalformedHierarchyAndTracksAreRejectedBeforePlayback() throws {
        var skeleton = SceneSkeleton(
            bones: [.init(name: "root", parent: 0, rest: .init(), inverseBind: identity)],
            clips: [], playback: []
        )
        XCTAssertThrowsError(try SceneSkeletonEvaluator(skeleton))
        skeleton.bones[0].parent = nil
        skeleton.clips = [.init(name: "broken", framesPerSecond: 1, frameCount: 1, tracks: [
            .init(bone: 0, transforms: [.init()])
        ])]
        XCTAssertThrowsError(try SceneSkeletonEvaluator(skeleton))
    }
}

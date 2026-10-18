import AppKit
import AVFoundation
@testable import LiveWallpaper
import Metal
import XCTest

@MainActor
final class SceneLinkTests: XCTestCase {
    private var directory: URL!
    private var video: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneLinkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        video = directory.appendingPathComponent("scene.mp4")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private func date(_ hour: Int, _ minute: Int, day: Int = 13) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func writeImage() throws -> String {
        var pixels = [UInt8](repeating: 255, count: 64 * 64 * 4)
        for y in 0 ..< 64 {
            for x in 0 ..< 64 {
                pixels[(y * 64 + x) * 4] = UInt8(x * 4)
                pixels[(y * 64 + x) * 4 + 1] = UInt8(y * 4)
                pixels[(y * 64 + x) * 4 + 2] = 120
            }
        }
        let image = CGImage(
            width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )!
        return try SceneStore.writeImage(image, prefix: "layer", videoPath: video.path)
    }

    /// BGRA.
    private func frame(
        _ scene: SceneDocument, timeOfDay: SceneTimeOfDay = .day, parallax: SIMD2<Float> = .zero, time: Double = 0
    ) throws -> [UInt8] {
        let renderer = try SceneRenderer(document: scene, videoPath: video.path)
        renderer.timeOfDay = timeOfDay
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let command = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
        try renderer.encode(into: texture, commandBuffer: command, input: SceneFrameInput(parallax: parallax, time: time))
        command.commit()
        command.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        texture.getBytes(&pixels, bytesPerRow: 256, from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
        return pixels
    }

    private func maxDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    // MARK: - Time of day

    func testPartsOfTheDayChangeAtTheirStartTimes() {
        let scene = SceneDocument(canvasWidth: 8, canvasHeight: 8, layers: [])
        let cases: [(Int, Int, SceneTimeOfDay)] = [
            (0, 0, .night), (5, 59, .night), (6, 0, .morning), (9, 59, .morning), (10, 0, .day),
            (16, 59, .day), (17, 0, .evening), (18, 59, .evening), (19, 0, .night), (23, 59, .night)
        ]
        for (hour, minute, expected) in cases {
            XCTAssertEqual(scene.timeOfDay(at: date(hour, minute), calendar: calendar), expected, "\(hour):\(minute)")
        }
    }

    func testChangedStartTimesAreFollowed() {
        var scene = SceneDocument(canvasWidth: 8, canvasHeight: 8, layers: [])
        scene.timeBands[3].startMinute = 2 * 60 // night from 2:00, after midnight
        XCTAssertEqual(scene.timeOfDay(at: date(23, 0), calendar: calendar), .evening)
        XCTAssertEqual(scene.timeOfDay(at: date(1, 0), calendar: calendar), .evening, "yesterday's evening lasts")
        XCTAssertEqual(scene.timeOfDay(at: date(3, 0), calendar: calendar), .night)
    }

    func testNextChangeIsTheNextStart() {
        let scene = SceneDocument(canvasWidth: 8, canvasHeight: 8, layers: [])
        XCTAssertEqual(scene.nextTimeOfDayChange(after: date(5, 30), calendar: calendar), date(6, 0))
        XCTAssertEqual(scene.nextTimeOfDayChange(after: date(10, 0), calendar: calendar), date(17, 0))
        XCTAssertEqual(scene.nextTimeOfDayChange(after: date(19, 30), calendar: calendar), date(6, 0, day: 14))
    }

    // MARK: - Saving

    func testScenesWithoutLinksOpenWithDefaults() throws {
        let json = #"{"canvasWidth":8,"canvasHeight":8,"layers":[]}"#
        let scene = try JSONDecoder().decode(SceneDocument.self, from: Data(json.utf8))
        XCTAssertEqual(scene.timeBands, SceneTimeBand.defaults)
        XCTAssertEqual(scene.links, [])
    }

    func testBrokenStartTimesFallBackAndLinksSurviveARoundTrip() throws {
        var scene = SceneDocument(canvasWidth: 8, canvasHeight: 8, layers: [])
        scene.timeBands = [SceneTimeBand(timeOfDay: .day, startMinute: 600), SceneTimeBand(timeOfDay: .day, startMinute: 700)]
        var link = SceneLink(input: .timeOfDay, layerIDs: [UUID()])
        link.timeValues[.evening] = { var values = SceneLinkValues(); values.warmth = 0.5; return values }()
        scene.links = [link]

        let data = try SceneStore.encode(scene)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"evening\""), "keyed by name")
        let decoded = try JSONDecoder().decode(SceneDocument.self, from: data)
        XCTAssertEqual(decoded.timeBands, SceneTimeBand.defaults)
        XCTAssertEqual(decoded.links, [link])
    }

    // MARK: - Evaluation

    func testCursorLinksChangeNothingAtTheCentre() {
        var link = SceneLink(input: .cursorX, layerIDs: [UUID()])
        link.start.offsetX = -0.2
        link.end.offsetX = 0.2
        link.end.scale = 4
        XCTAssertEqual(link.values(timeOfDay: .day, cursor: .zero), .identity)
        XCTAssertEqual(link.values(timeOfDay: .day, cursor: SIMD2(-1, 0)).offsetX, -0.2, accuracy: 1e-9)
        let half = link.values(timeOfDay: .day, cursor: SIMD2(0.5, 0))
        XCTAssertEqual(half.offsetX, 0.1, accuracy: 1e-9)
        XCTAssertEqual(half.scale, 2, accuracy: 1e-9, "zoom is even in log space")

        var distance = SceneLink(input: .cursorDistance, layerIDs: [UUID()])
        distance.end.opacity = 0
        XCTAssertEqual(distance.values(timeOfDay: .day, cursor: SIMD2(0.6, 0.8)).opacity, 0, accuracy: 1e-9)
    }

    func testLinksOnOneLayerAddUpAndOneLinkMovesAllItsLayers() {
        let first = UUID()
        let second = UUID()
        var time = SceneLink(input: .timeOfDay, layerIDs: [first, second])
        time.timeValues[.night] = { var values = SceneLinkValues(); values.offsetX = 0.1; values.scale = 2; return values }()
        var cursor = SceneLink(input: .cursorY, layerIDs: [first])
        cursor.end.offsetX = 0.3
        cursor.end.scale = 3
        var scene = SceneDocument(canvasWidth: 8, canvasHeight: 8, layers: [])
        scene.links = [time, cursor]

        let a = scene.linkValues(layerID: first, timeOfDay: .night, cursor: SIMD2(0, 1))
        XCTAssertEqual(a.offsetX, 0.4, accuracy: 1e-9)
        XCTAssertEqual(a.scale, 6, accuracy: 1e-9)
        let b = scene.linkValues(layerID: second, timeOfDay: .night, cursor: SIMD2(0, 1))
        XCTAssertEqual(b.offsetX, 0.1, accuracy: 1e-9)
        XCTAssertEqual(scene.linkValues(layerID: second, timeOfDay: .day, cursor: .zero), .identity)
    }

    func testLinksApplyAfterKeyframesAndUnchangedLayersDrawAsBefore() throws {
        let file = try writeImage()
        var plain = SceneLayer(name: "picture", imageFile: file)
        plain.transform.scale = 0.6
        let before = try frame(SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [plain]))

        // A link that changes nothing draws exactly the same.
        var unchanged = SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [plain])
        unchanged.links = [SceneLink(input: .timeOfDay, layerIDs: [plain.id])]
        XCTAssertEqual(maxDifference(before, try frame(unchanged)), 0)

        // Keyframes at rest, the link moving the whole pose = keyframes already moved.
        var keyframed = plain
        keyframed.keyframes = [
            SceneKeyframe(time: 0, transform: plain.transform), SceneKeyframe(time: 0.5, transform: plain.transform)
        ]
        var linked = SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [keyframed])
        var link = SceneLink(input: .timeOfDay, layerIDs: [keyframed.id])
        link.timeValues[.evening] = { var values = SceneLinkValues(); values.offsetX = 0.15; values.rotation = 20; return values }()
        linked.links = [link]
        var moved = keyframed
        for index in moved.keyframes.indices {
            moved.keyframes[index].transform.offsetX += 0.15
            moved.keyframes[index].transform.rotation += 20
        }
        let expected = try frame(SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [moved]), time: 3)
        XCTAssertLessThanOrEqual(maxDifference(try frame(linked, timeOfDay: .evening, time: 3), expected), 1)
        XCTAssertEqual(maxDifference(try frame(linked, timeOfDay: .day, time: 3), try frame(
            SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [keyframed]), time: 3
        )), 0, "other parts of the day are untouched")
    }

    func testCursorLinkFollowsTheParallaxInputAndRestsAtTheCentre() throws {
        let file = try writeImage()
        var layer = SceneLayer(name: "picture", imageFile: file)
        layer.transform.scale = 0.6
        var scene = SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [layer])
        var link = SceneLink(input: .cursorX, layerIDs: [layer.id])
        link.end.offsetY = 0.2
        scene.links = [link]
        var shifted = layer
        shifted.transform.offsetY = 0.2

        let rest = try frame(SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [layer]))
        XCTAssertEqual(maxDifference(try frame(scene), rest), 0, "the lock screen sees the cursor at the centre")
        let atRight = try frame(scene, parallax: SIMD2(1, 0))
        XCTAssertEqual(maxDifference(atRight, try frame(SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [shifted]))), 0)
        XCTAssertTrue(scene.usesCursor, "the desktop draws it live and tracks the cursor")
    }

    func testColourFollowsThePartOfTheDay() throws {
        let file = try writeImage()
        let layer = SceneLayer(name: "picture", imageFile: file)
        var scene = SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [layer])
        var link = SceneLink(input: .timeOfDay, layerIDs: [layer.id])
        link.timeValues[.night] = { var values = SceneLinkValues(); values.brightness = -1; return values }()
        link.timeValues[.evening] = { var values = SceneLinkValues(); values.saturation = 0; return values }()
        scene.links = [link]

        let night = try frame(scene, timeOfDay: .night)
        var brightest = 0
        for index in stride(from: 0, to: night.count, by: 4) {
            let red = Int(night[index])
            let green = Int(night[index + 1])
            let blue = Int(night[index + 2])
            brightest = max(brightest, red + green + blue)
        }
        XCTAssertEqual(brightest, 0)
        let evening = try frame(scene, timeOfDay: .evening)
        for index in stride(from: 0, to: evening.count, by: 4) {
            XCTAssertLessThanOrEqual(abs(Int(evening[index]) - Int(evening[index + 2])), 1, "grey")
        }
        XCTAssertTrue(scene.usesTimeOfDay)
        XCTAssertFalse(scene.usesCursor)
    }

    func testBakedVideoShowsThePartOfTheDayItWasBakedFor() async throws {
        let file = try writeImage()
        let layer = SceneLayer(name: "picture", imageFile: file)
        var scene = SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [layer])
        var link = SceneLink(input: .timeOfDay, layerIDs: [layer.id])
        link.timeValues[.night] = { var values = SceneLinkValues(); values.brightness = -1; return values }()
        scene.links = [link]

        func brightest(_ timeOfDay: SceneTimeOfDay) async throws -> Int {
            let output = directory.appendingPathComponent("\(timeOfDay.rawValue).mp4")
            try await SceneVideoBaker.bake(document: scene, videoPath: video.path, timeOfDay: timeOfDay, to: output) { _ in }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
            let image = try await generator.image(at: .zero).image
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try XCTUnwrap(CGContext(
                data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return stride(from: 0, to: bytes.count, by: 4).map { max(bytes[$0], bytes[$0 + 1], bytes[$0 + 2]) }.map(Int.init).max() ?? 0
        }
        let night = try await brightest(.night)
        let day = try await brightest(.day)
        XCTAssertLessThan(night, 20)
        XCTAssertGreaterThan(day, 200)
    }

    // MARK: - Model

    func testANewPartOfTheDayRebakesOnlyWhenTheVideoShowsAnother() throws {
        let file = try writeImage()
        let layer = SceneLayer(name: "picture", imageFile: file)
        var scene = SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [layer])
        var link = SceneLink(input: .timeOfDay, layerIDs: [layer.id])
        for (index, timeOfDay) in SceneTimeOfDay.allCases.enumerated() {
            link.timeValues[timeOfDay] = { var values = SceneLinkValues(); values.warmth = Double(index) * 0.2; return values }()
        }
        scene.links = [link]
        try SceneStore.save(scene, videoPath: video.path)
        let model = WallpaperModel()
        model.registerImportedScene(scene, path: video.path)
        defer {
            model.sceneTimeOfDayTimer?.invalidate()
            model.cancelSceneBake(path: video.path)
            model.discardSceneSave(path: video.path)
        }
        let now = scene.timeOfDay(at: Date())

        model.sceneBakedTimesOfDay[video.path] = now
        model.updateSceneTimesOfDay()
        XCTAssertFalse(model.scenesBaking.contains(video.path))
        let fire = try XCTUnwrap(model.sceneTimeOfDayTimer?.fireDate, "waits for the next part of the day")
        let next = try XCTUnwrap(scene.nextTimeOfDayChange(after: Date()))
        XCTAssertEqual(fire.timeIntervalSince(next), 1, accuracy: 1)

        let other = SceneTimeOfDay.allCases.first { $0 != now }
        model.sceneBakedTimesOfDay[video.path] = other
        model.updateSceneTimesOfDay()
        XCTAssertFalse(model.scenesBaking.contains(video.path), "no video wanted: drawn live instead")
        XCTAssertTrue(model.sceneStaleVideoPaths.contains(video.path))

        model.lockScreenVideoPath = video.path
        model.cancelSceneBake(path: video.path)
        model.sceneBakedTimesOfDay[video.path] = other
        model.updateSceneTimesOfDay()
        XCTAssertTrue(model.scenesBakeRunning.contains(video.path), "bakes at once, not after edits pause")
        XCTAssertEqual(model.sceneBakingTimesOfDay[video.path], now)
    }

    func testAPartOfTheDayThatLooksTheSameIsNotRebaked() throws {
        let file = try writeImage()
        let layer = SceneLayer(name: "picture", imageFile: file)
        var scene = SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [layer])
        var link = SceneLink(input: .timeOfDay, layerIDs: [layer.id])
        let now = scene.timeOfDay(at: Date())
        let other = SceneTimeOfDay.allCases.first { $0 != now }!
        let third = SceneTimeOfDay.allCases.first { $0 != now && $0 != other }!
        link.timeValues[third] = { var values = SceneLinkValues(); values.brightness = -0.5; return values }()
        scene.links = [link]
        XCTAssertTrue(scene.looksSame(at: other, as: now))
        XCTAssertFalse(scene.looksSame(at: third, as: now))
        try SceneStore.save(scene, videoPath: video.path)
        let model = WallpaperModel()
        model.registerImportedScene(scene, path: video.path)
        defer {
            model.sceneTimeOfDayTimer?.invalidate()
            model.cancelSceneBake(path: video.path)
            model.discardSceneSave(path: video.path)
        }

        model.sceneBakedTimesOfDay[video.path] = other
        model.updateSceneTimesOfDay()
        XCTAssertFalse(model.scenesBaking.contains(video.path))
        XCTAssertEqual(model.sceneBakedTimesOfDay[video.path], now)
    }

    func testCopiesAndCutOutsJoinTheLinksOfTheirLayer() throws {
        let file = try writeImage()
        let layer = SceneLayer(name: "picture", imageFile: file)
        var scene = SceneDocument(canvasWidth: 64, canvasHeight: 64, layers: [layer])
        scene.links = [SceneLink(input: .cursorX, layerIDs: [layer.id])]
        try SceneStore.save(scene, videoPath: video.path)
        let model = WallpaperModel()
        model.registerImportedScene(scene, path: video.path)
        defer {
            model.cancelSceneBake(path: video.path)
            model.discardSceneSave(path: video.path)
        }
        let copy = try XCTUnwrap(model.duplicateSceneLayer(id: layer.id, path: video.path))
        XCTAssertEqual(model.sceneDocumentsByPath[video.path]?.links.first?.layerIDs, [layer.id, copy])
    }
}

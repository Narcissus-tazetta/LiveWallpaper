import Foundation
@testable import LiveWallpaper
import XCTest

final class StoredFormatTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoredFormat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// scene.json exactly as format 1 wrote it. Never regenerate it: it stands for every
    /// scene already on users' disks, which each later version has to keep opening.
    private static let formatOneScene = #"""
    {
      "backgroundColor" : [
        0.1,
        0.2,
        0.3
      ],
      "canvasHeight" : 360,
      "canvasWidth" : 640,
      "formatVersion" : 1,
      "highDynamicRange" : true,
      "layers" : [
        {
          "blendMode" : "normal",
          "capturesCanvas" : false,
          "depthAutoCycles" : 1,
          "depthAutoMotion" : 0,
          "depthFollowsCursor" : true,
          "depthStrength" : 0.5,
          "effects" : [

          ],
          "id" : "74249F9B-8CA2-46DB-9C5A-69BEB9AD6485",
          "imageFile" : "bg.png",
          "isLocked" : false,
          "isVisible" : true,
          "keyframes" : [

          ],
          "kind" : "image",
          "name" : "bg",
          "opacity" : 0.8,
          "parallaxDepth" : 0,
          "tint" : {
            "alpha" : 1,
            "blue" : 1,
            "green" : 1,
            "red" : 1
          },
          "transform" : {
            "offsetX" : 0,
            "offsetY" : 0,
            "rotation" : 0,
            "scale" : 1
          },
          "usesMediaArtwork" : false
        },
        {
          "blendMode" : "normal",
          "capturesCanvas" : false,
          "depthAutoCycles" : 1,
          "depthAutoMotion" : 0,
          "depthFollowsCursor" : true,
          "depthStrength" : 0.5,
          "effects" : [

          ],
          "id" : "1ACFA333-01FB-49E4-8BCD-B4C11599DC8E",
          "imageFile" : "fg.png",
          "isLocked" : false,
          "isVisible" : true,
          "keyframes" : [

          ],
          "kind" : "image",
          "name" : "fg",
          "opacity" : 1,
          "parallaxDepth" : 0,
          "tint" : {
            "alpha" : 1,
            "blue" : 1,
            "green" : 1,
            "red" : 1
          },
          "transform" : {
            "offsetX" : 0,
            "offsetY" : 0,
            "rotation" : 0,
            "scale" : 1
          },
          "usesMediaArtwork" : false
        }
      ],
      "links" : [

      ],
      "loopSeconds" : 30,
      "rigs" : [

      ],
      "runsInRealTime" : false,
      "scripts" : [

      ],
      "sounds" : [

      ],
      "timeBands" : [
        {
          "startMinute" : 360,
          "timeOfDay" : "morning"
        },
        {
          "startMinute" : 600,
          "timeOfDay" : "day"
        },
        {
          "startMinute" : 1020,
          "timeOfDay" : "evening"
        },
        {
          "startMinute" : 1140,
          "timeOfDay" : "night"
        }
      ]
    }
    """#

    private func install(_ json: String, name: String = "a") throws -> (video: String, file: URL) {
        let video = directory.appendingPathComponent("\(name).mp4").path
        let folder = SceneStore.folderURL(forVideoPath: video)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("scene.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return (video, file)
    }

    private func bytes(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func testASavedSceneCarriesTheCurrentVersion() throws {
        let video = directory.appendingPathComponent("saved.mp4").path
        try SceneStore.save(
            SceneDocument(canvasWidth: 8, canvasHeight: 8, layers: []),
            videoPath: video
        )
        let file = SceneStore.folderURL(forVideoPath: video).appendingPathComponent("scene.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes(file)) as? [String: Any])
        XCTAssertEqual(json["formatVersion"] as? Int, StoredFormat.scene.current)
    }

    func testAFormatOneSceneStillLoads() throws {
        let (video, _) = try install(Self.formatOneScene)
        let scene = try XCTUnwrap(SceneStore.load(videoPath: video))
        XCTAssertEqual(scene.canvasWidth, 640)
        XCTAssertEqual(scene.canvasHeight, 360)
        XCTAssertEqual(scene.loopSeconds, 30)
        XCTAssertTrue(scene.highDynamicRange)
        XCTAssertEqual(scene.backgroundColor, [0.1, 0.2, 0.3])
        XCTAssertEqual(scene.layers.map(\.name), ["bg", "fg"])
        XCTAssertEqual(scene.layers[0].opacity, 0.8)
        XCTAssertEqual(scene.layers[1].imageFile, "fg.png")
    }

    func testASceneWithoutANumberLoadsAsIsAndNoCopyIsKept() throws {
        let unnumbered = Self.formatOneScene.replacingOccurrences(
            of: "  \"formatVersion\" : 1,\n",
            with: ""
        )
        XCTAssertFalse(unnumbered.contains("formatVersion"))
        let (video, file) = try install(unnumbered)
        let before = try bytes(file)

        let scene = try XCTUnwrap(SceneStore.load(videoPath: video))

        XCTAssertEqual(scene.canvasWidth, 640)
        XCTAssertEqual(try bytes(file), before)
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["scene.json"])
    }

    func testANewerSceneIsRefusedAndLeftUntouched() throws {
        let newer = """
        {"formatVersion": \(StoredFormat.scene
            .current + 1), "layers": [{"kind": "hologram"}], "somethingNew": {}}
        """
        let (video, file) = try install(newer)
        let before = try bytes(file)

        XCTAssertThrowsError(try SceneStore.load(videoPath: video)) { error in
            XCTAssertEqual(
                (error as? StoredFormat.NewerVersionError)?.found,
                StoredFormat.scene.current + 1
            )
        }
        XCTAssertEqual(try bytes(file), before)
    }

    func testInstallingANewerSceneFromAPackageIsRefused() throws {
        let source = directory.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let newer = Self.formatOneScene.replacingOccurrences(
            of: "\"formatVersion\" : 1",
            with: "\"formatVersion\" : 99"
        )
        try newer.write(
            to: source.appendingPathComponent("scene.json"),
            atomically: true,
            encoding: .utf8
        )
        let video = directory.appendingPathComponent("imported.mp4").path

        XCTAssertThrowsError(try SceneStore.importScene(from: source, videoPath: video)) { error in
            XCTAssertTrue(error is StoredFormat.NewerVersionError)
        }
        XCTAssertFalse(SceneStore.hasScene(videoPath: video))
    }

    func testANegativeOrFractionalNumberIsNotAFormat() throws {
        for value in ["-1", "1.5", "\"1\""] {
            let (video, _) = try install(
                Self.formatOneScene.replacingOccurrences(
                    of: "\"formatVersion\" : 1",
                    with: "\"formatVersion\" : \(value)"
                ),
                name: "bad\(value.count)\(value.hashValue.magnitude)"
            )
            XCTAssertThrowsError(try SceneStore.load(videoPath: video), value)
        }
    }

    func testAReshapingStepRunsOnOlderScenesAndKeepsACopyOfTheFile() throws {
        // A future format 2 that changes the shape: here, it forces the loop to 45 seconds.
        let next = StoredFormat(steps: StoredFormat.scene.steps + [
            .init(stampOnly: false) { $0["loopSeconds"] = 45 }
        ])
        let (video, file) = try install(Self.formatOneScene)
        let original = try bytes(file)

        let scene = try XCTUnwrap(SceneStore.load(videoPath: video, format: next))

        XCTAssertEqual(scene.loopSeconds, 45)
        XCTAssertEqual(scene.layers.map(\.name), ["bg", "fg"])
        let copy = file.deletingLastPathComponent().appendingPathComponent(".scene.json.v1.bak")
        XCTAssertEqual(try bytes(copy), original)
        XCTAssertEqual(try bytes(file), original, "loading alone does not rewrite the file")

        // Loading again must not replace the copy of the file as the older app wrote it.
        _ = try SceneStore.load(videoPath: video, format: next)
        XCTAssertEqual(try bytes(copy), original)
    }

    func testStepsApplyInOrderFromTheStoredVersion() throws {
        var log: [String] = []
        let format = StoredFormat(steps: [
            .init(stampOnly: false) { _ in log.append("0to1") },
            .init(stampOnly: false) { _ in log.append("1to2") },
            .init(stampOnly: false) { _ in log.append("2to3") }
        ])
        let fromOne = try format.prepare(Data(#"{"formatVersion": 1}"#.utf8))
        XCTAssertEqual(log, ["1to2", "2to3"])
        XCTAssertEqual(fromOne.storedVersion, 1)
        XCTAssertTrue(fromOne.reshaped)
        let migrated = try XCTUnwrap(JSONSerialization
            .jsonObject(with: fromOne.data) as? [String: Any])
        XCTAssertEqual(migrated["formatVersion"] as? Int, 3)

        log = []
        let current = try format.prepare(Data(#"{"formatVersion": 3}"#.utf8))
        XCTAssertEqual(log, [])
        XCTAssertFalse(current.reshaped)
    }

    func testPresetsAreVersionedAndANewerOneIsSkippedAndCounted() throws {
        let store = ScenePresetStore(directory: directory.appendingPathComponent("presets"))
        let preset = ScenePreset(name: "mine", effects: [])
        try store.save(preset, filesFrom: directory)
        let savedFile = store.folderURL(of: preset.id).appendingPathComponent("preset.json")
        let json = try XCTUnwrap(JSONSerialization
            .jsonObject(with: bytes(savedFile)) as? [String: Any])
        XCTAssertEqual(json["formatVersion"] as? Int, StoredFormat.scenePreset.current)

        let newerFolder = store.folderURL(of: UUID())
        try FileManager.default.createDirectory(at: newerFolder, withIntermediateDirectories: true)
        let newerFile = newerFolder.appendingPathComponent("preset.json")
        let newer = #"{"formatVersion": 99, "name": "later", "somethingNew": true}"#
        try newer.write(to: newerFile, atomically: true, encoding: .utf8)

        let loaded = try store.loadAll()

        XCTAssertEqual(loaded.presets.map(\.id), [preset.id])
        XCTAssertEqual(loaded.newerVersionCount, 1)
        XCTAssertEqual(try String(contentsOf: newerFile, encoding: .utf8), newer)
    }
}

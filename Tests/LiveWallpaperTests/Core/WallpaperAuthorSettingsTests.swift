import Combine
import Foundation
@testable import LiveWallpaper
import XCTest

@MainActor
final class WallpaperAuthorSettingsTests: XCTestCase {
    private var tempDirectory: URL!
    private var createdUserDefaultsKeys: Set<String> = []

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallpaperAuthorSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        // Clean up any stale keys from prior test runs
        UserDefaults.standard.removeObject(forKey: "authorSettings.external.test-provider/item-1")
        UserDefaults.standard.removeObject(forKey: "authorSettings.scene.wallpaper-1.mp4")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        for key in createdUserDefaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        createdUserDefaultsKeys.removeAll()
    }

    func testSceneDocumentDecodesProperties() throws {
        let json = """
        {
            "canvasWidth": 1920,
            "canvasHeight": 1080,
            "layers": [],
            "properties": [
                {
                    "id": "speed",
                    "kind": "slider",
                    "label": {"en": "Speed", "ja": "速度"},
                    "value": 50,
                    "minimum": 0,
                    "maximum": 100,
                    "step": 1
                },
                {
                    "id": "toggle_feature",
                    "kind": "bool",
                    "label": {"en": "Feature"},
                    "value": true
                }
            ]
        }
        """

        let document = try JSONDecoder().decode(SceneDocument.self, from: Data(json.utf8))
        XCTAssertEqual(document.properties?.count, 2)
        let speed = try XCTUnwrap(document.properties?.first(where: { $0.id == "speed" }))
        XCTAssertEqual(speed.kind, "slider")
        XCTAssertEqual(speed.minimum, 0)
        XCTAssertEqual(speed.maximum, 100)
        XCTAssertEqual(speed.step, 1)

        // Verify roundtrip encoding
        let encoded = try JSONEncoder().encode(document)
        let roundtrip = try JSONDecoder().decode(SceneDocument.self, from: encoded)
        XCTAssertEqual(roundtrip.properties?.count, 2)
    }

    func testExternalWallpaperAuthorSettingsContext() throws {
        let model = WallpaperModel()
        let uniqueID = "test-provider/\(UUID().uuidString)"
        let settingsKey = "authorSettings.external." + uniqueID
        createdUserDefaultsKeys.insert(settingsKey)

        let property = LocalWebProperty(
            id: "bloom",
            kind: "bool",
            label: ["en": "Bloom"],
            value: .bool(false)
        )
        let wallpaper = ExternalWallpaper(
            id: uniqueID,
            providerName: "Test Provider",
            name: "Test Scene",
            path: "/tmp/fake-\(UUID().uuidString).mp4",
            properties: [property]
        )

        XCTAssertTrue(model.hasAuthorSettings(forExternalWallpaper: wallpaper))

        let context = try XCTUnwrap(model.authorSettingsContext(forExternalWallpaper: wallpaper))
        XCTAssertEqual(context.title, "Test Scene")
        XCTAssertEqual(context.properties.count, 1)

        // Load defaults
        var settings = try context.loadSettings()
        XCTAssertTrue(settings.values.isEmpty)

        // Modify and save
        settings.values["bloom"] = .bool(true)
        try context.saveSettings(settings)

        // Reload and verify
        let reloaded = try context.loadSettings()
        XCTAssertEqual(reloaded.values["bloom"], .bool(true))
    }

    func testSceneWallpaperAuthorSettingsForPath() throws {
        let model = WallpaperModel()
        let videoURL = tempDirectory.appendingPathComponent("wallpaper-\(UUID().uuidString).mp4")
        try Data([0, 1, 2]).write(to: videoURL)

        let sceneURL = SceneStore.folderURL(forVideoPath: videoURL.path)
        try FileManager.default.createDirectory(at: sceneURL, withIntermediateDirectories: true)

        let settingsKey = "authorSettings.scene." + videoURL.standardizedFileURL.path
        createdUserDefaultsKeys.insert(settingsKey)

        let prop = LocalWebProperty(
            id: "rate",
            kind: "slider",
            label: ["en": "Playback Rate"],
            value: .number(1.0),
            minimum: 0.1,
            maximum: 3.0
        )
        let propData = try JSONEncoder().encode([prop])
        try propData.write(to: sceneURL.appendingPathComponent("properties.json"))

        XCTAssertTrue(model.hasAuthorSettings(forPath: videoURL.path))

        let context = try XCTUnwrap(model.authorSettingsContext(forPath: videoURL.path))
        XCTAssertEqual(context.properties.count, 1)
        XCTAssertEqual(context.properties[0].id, "rate")

        var settings = try context.loadSettings()
        XCTAssertTrue(settings.values.isEmpty)

        settings.values["rate"] = .number(1.5)
        try context.saveSettings(settings)

        let reloaded = try context.loadSettings()
        XCTAssertEqual(reloaded.values["rate"], .number(1.5))
    }

    func testEmptyPropertiesDoNotReportAuthorSettings() throws {
        let model = WallpaperModel()
        let videoURL = tempDirectory.appendingPathComponent("empty-\(UUID().uuidString).mp4")
        try Data([0, 1, 2]).write(to: videoURL)

        let sceneURL = SceneStore.folderURL(forVideoPath: videoURL.path)
        try FileManager.default.createDirectory(at: sceneURL, withIntermediateDirectories: true)

        // properties.json with empty list
        let emptyPropsData = try JSONEncoder().encode([LocalWebProperty]())
        try emptyPropsData.write(to: sceneURL.appendingPathComponent("properties.json"))

        XCTAssertFalse(model.hasAuthorSettings(forPath: videoURL.path))
        XCTAssertNil(model.authorSettingsContext(forPath: videoURL.path))
    }

    func testAuthorSettingsLegacyKeyFallback() throws {
        let model = WallpaperModel()
        let filename = "legacy-\(UUID().uuidString).mp4"
        let videoURL = tempDirectory.appendingPathComponent(filename)
        try Data([0, 1, 2]).write(to: videoURL)

        let sceneURL = SceneStore.folderURL(forVideoPath: videoURL.path)
        try FileManager.default.createDirectory(at: sceneURL, withIntermediateDirectories: true)

        let prop = LocalWebProperty(
            id: "quality",
            kind: "slider",
            label: ["en": "Quality"],
            value: .number(50),
            minimum: 0,
            maximum: 100
        )
        let propData = try JSONEncoder().encode([prop])
        try propData.write(to: sceneURL.appendingPathComponent("properties.json"))

        // Save under legacy key
        let legacyKey = "authorSettings.scene." + filename
        createdUserDefaultsKeys.insert(legacyKey)
        let normalizedKey = "authorSettings.scene." + videoURL.standardizedFileURL.path
        createdUserDefaultsKeys.insert(normalizedKey)

        var legacySettings = LocalWebSettings()
        legacySettings.values["quality"] = .number(80)
        try legacySettings.save(key: legacyKey)

        // Verify fallback loads legacy key
        let context = try XCTUnwrap(model.authorSettingsContext(forPath: videoURL.path))
        let loaded = try context.loadSettings()
        XCTAssertEqual(loaded.values["quality"], .number(80))
    }

    func testSceneFrameEvaluatorReceivesUserProperties() throws {
        let layer = SceneLayer(name: "Image", imageFile: "image.png")
        var document = SceneDocument(canvasWidth: 100, canvasHeight: 80, layers: [layer])
        var script = SceneScript(
            source: "function update(c){ return [{id: c.targets[0].id, values: {scale: c.userProperties ? c.userProperties.speed : 1.0}}]; }",
            layerIDs: [layer.id]
        )
        script.isAuthorized = true
        document.scripts = [script]

        let evaluator = SceneFrameEvaluator()
        let inputWithProps = SceneFrameInput(
            time: 0,
            userProperties: ["speed": .number(3.5)]
        )
        let frame = try evaluator.evaluate(document, input: inputWithProps, timeOfDay: .day)
        XCTAssertEqual(frame.layers[layer.id]?.transform.scale, 3.5)

        let inputWithoutProps = SceneFrameInput(time: 0)
        let frameDefault = try evaluator.evaluate(document, input: inputWithoutProps, timeOfDay: .day)
        XCTAssertEqual(frameDefault.layers[layer.id]?.transform.scale, 1.0)

        // Verify empty dictionary is passed as an object, allowing script to see empty props
        let inputEmptyProps = SceneFrameInput(time: 0, userProperties: [:])
        let frameEmpty = try evaluator.evaluate(document, input: inputEmptyProps, timeOfDay: .day)
        XCTAssertEqual(frameEmpty.layers[layer.id]?.transform.scale, 1.0)
    }

    func testHasAuthorSettingsSkipsSceneJSONWhenPropertiesJSONExists() throws {
        let model = WallpaperModel()
        let videoURL = tempDirectory.appendingPathComponent("skip-scene-json-\(UUID().uuidString).mp4")
        try Data([0, 1, 2]).write(to: videoURL)

        let sceneURL = SceneStore.folderURL(forVideoPath: videoURL.path)
        try FileManager.default.createDirectory(at: sceneURL, withIntermediateDirectories: true)

        // Write empty properties.json
        let emptyPropsData = try JSONEncoder().encode([LocalWebProperty]())
        try emptyPropsData.write(to: sceneURL.appendingPathComponent("properties.json"))

        // Write corrupt or broken scene.json that would fail JSON parsing if opened
        let sceneJSONURL = sceneURL.appendingPathComponent("scene.json")
        try "BROKEN_JSON_DATA".data(using: .utf8)!.write(to: sceneJSONURL)

        // If properties.json is respected as fast-path, it returns false without attempting to parse scene.json
        XCTAssertFalse(model.hasAuthorSettings(forPath: videoURL.path))
        XCTAssertNil(model.sceneDocumentsByPath[videoURL.path])
    }

    func testApplySceneAuthorSettingsLoadsMissingDocumentFromDisk() throws {
        let model = WallpaperModel()
        let videoURL = tempDirectory.appendingPathComponent("missing-doc-\(UUID().uuidString).mp4")
        try Data([0, 1, 2]).write(to: videoURL)

        let sceneURL = SceneStore.folderURL(forVideoPath: videoURL.path)
        try FileManager.default.createDirectory(at: sceneURL, withIntermediateDirectories: true)

        let document = SceneDocument(canvasWidth: 100, canvasHeight: 100, layers: [])
        let sceneData = try JSONEncoder().encode(document)
        try sceneData.write(to: sceneURL.appendingPathComponent("scene.json"))

        let settingsKey = "authorSettings.scene." + videoURL.standardizedFileURL.path
        createdUserDefaultsKeys.insert(settingsKey)

        XCTAssertNil(model.sceneDocumentsByPath[videoURL.path])

        var settings = LocalWebSettings()
        settings.values["speed"] = .number(2.0)

        try model.applySceneAuthorSettings(forPath: videoURL.path, settings: settings)

        // Verify document was restored into sceneDocumentsByPath
        XCTAssertNotNil(model.sceneDocumentsByPath[videoURL.path])
        XCTAssertTrue(model.sceneStaleVideoPaths.contains(videoURL.path))
    }

    func testSceneMetalLayerLoadUserProperties() throws {
        let videoURL = tempDirectory.appendingPathComponent("test-load-props-\(UUID().uuidString).mp4")
        let normalizedPath = videoURL.standardizedFileURL.path
        let normalizedKey = "authorSettings.scene." + normalizedPath
        createdUserDefaultsKeys.insert(normalizedKey)

        XCTAssertNil(SceneMetalLayer.loadUserProperties(forVideoPath: videoURL.path))

        var settings = LocalWebSettings()
        settings.values["speed"] = .number(2.0)
        try settings.save(key: normalizedKey)

        let loaded = SceneMetalLayer.loadUserProperties(forVideoPath: videoURL.path)
        XCTAssertEqual(loaded?["speed"], .number(2.0))
    }

    func testApplySceneAuthorSettingsMarksStaleAndSchedulesBake() throws {
        let model = WallpaperModel()
        let videoURL = tempDirectory.appendingPathComponent("test-apply-\(UUID().uuidString).mp4")
        let path = videoURL.path
        let document = SceneDocument(canvasWidth: 100, canvasHeight: 100, layers: [])
        model.sceneDocumentsByPath[path] = document

        var settings = LocalWebSettings()
        settings.values["brightness"] = .number(0.8)

        try model.applySceneAuthorSettings(forPath: path, settings: settings)

        XCTAssertTrue(model.sceneStaleVideoPaths.contains(path))
    }

    func testApplyExternalAuthorSettingsSchedulesBakeAndSavesNormalizedKey() throws {
        let model = WallpaperModel()
        let uniqueID = "test-provider/\(UUID().uuidString)"
        let videoURL = tempDirectory.appendingPathComponent("test-ext-\(UUID().uuidString).mp4")
        let normalizedKey = "authorSettings.scene." + videoURL.standardizedFileURL.path
        createdUserDefaultsKeys.insert(normalizedKey)

        let wallpaper = ExternalWallpaper(
            id: uniqueID,
            providerName: "Test Provider",
            name: "Test Scene",
            path: videoURL.path,
            sceneFolderPath: tempDirectory.path
        )

        var settings = LocalWebSettings()
        settings.values["tint"] = .string("#ff0000")

        try model.applyExternalAuthorSettings(forWallpaper: wallpaper, settings: settings)

        XCTAssertTrue(model.sceneStaleVideoPaths.contains(videoURL.path))
        let loaded = try LocalWebSettings.load(key: normalizedKey)
        XCTAssertEqual(loaded.values["tint"], .string("#ff0000"))
    }

    func testLoadedLegacySceneReadsAuthorSettingsFromSidecar() throws {
        let model = WallpaperModel()
        let videoURL = tempDirectory.appendingPathComponent("fallthrough-\(UUID().uuidString).mp4")
        let path = videoURL.path
        try Data([0, 1, 2]).write(to: videoURL)

        let sceneURL = SceneStore.folderURL(forVideoPath: path)
        try FileManager.default.createDirectory(at: sceneURL, withIntermediateDirectories: true)

        let prop = LocalWebProperty(
            id: "speed",
            kind: "slider",
            label: ["en": "Speed"],
            value: .number(1.0)
        )
        let propData = try JSONEncoder().encode([prop])
        try propData.write(to: sceneURL.appendingPathComponent("properties.json"))

        let document = SceneDocument(canvasWidth: 1920, canvasHeight: 1080, layers: [], properties: nil)
        model.sceneDocumentsByPath[path] = document

        var changeCount = 0
        let cancellable = model.objectWillChange.sink { _ in
            changeCount += 1
        }
        defer { cancellable.cancel() }

        XCTAssertTrue(model.hasAuthorSettings(forPath: path))
        let context = try XCTUnwrap(model.authorSettingsContext(forPath: path))
        XCTAssertEqual(context.properties, [prop])
        XCTAssertEqual(model.sceneDocumentsByPath[path], document)
        XCTAssertEqual(changeCount, 0)
    }

    func testHasAuthorSettingsNeverMutatesPublishedStateForUnloadedSceneWithPropertiesJSON() throws {
        let model = WallpaperModel()
        let videoURL = tempDirectory.appendingPathComponent("unloaded-prop-\(UUID().uuidString).mp4")
        let path = videoURL.path
        try Data([0, 1, 2]).write(to: videoURL)

        let sceneURL = SceneStore.folderURL(forVideoPath: path)
        try FileManager.default.createDirectory(at: sceneURL, withIntermediateDirectories: true)

        let prop = LocalWebProperty(
            id: "intensity",
            kind: "slider",
            label: ["en": "Intensity"],
            value: .number(2.0)
        )
        let propData = try JSONEncoder().encode([prop])
        try propData.write(to: sceneURL.appendingPathComponent("properties.json"))

        var changeCount = 0
        let cancellable = model.objectWillChange.sink { _ in
            changeCount += 1
        }
        defer { cancellable.cancel() }

        XCTAssertNil(model.sceneDocumentsByPath[path])

        XCTAssertTrue(model.hasAuthorSettings(forPath: path))
        XCTAssertNil(model.sceneDocumentsByPath[path])
        XCTAssertEqual(changeCount, 0)
    }

    func testHasAuthorSettingsNeverMutatesPublishedStateForUnloadedSceneWithSceneJSON() throws {
        let model = WallpaperModel()
        let videoURL = tempDirectory.appendingPathComponent("unloaded-scene-\(UUID().uuidString).mp4")
        let path = videoURL.path
        try Data([0, 1, 2]).write(to: videoURL)

        let sceneURL = SceneStore.folderURL(forVideoPath: path)
        try FileManager.default.createDirectory(at: sceneURL, withIntermediateDirectories: true)

        let prop = LocalWebProperty(
            id: "intensity",
            kind: "slider",
            label: ["en": "Intensity"],
            value: .number(2.0)
        )
        let document = SceneDocument(canvasWidth: 100, canvasHeight: 100, layers: [], properties: [prop])
        let sceneData = try JSONEncoder().encode(document)
        try sceneData.write(to: sceneURL.appendingPathComponent("scene.json"))

        var changeCount = 0
        let cancellable = model.objectWillChange.sink { _ in
            changeCount += 1
        }
        defer { cancellable.cancel() }

        XCTAssertNil(model.sceneDocumentsByPath[path])

        XCTAssertTrue(model.hasAuthorSettings(forPath: path))
        XCTAssertNil(model.sceneDocumentsByPath[path])
        XCTAssertEqual(changeCount, 0)
    }

    func testHasAuthorSettingsNeverMutatesPublishedStateWhenNoProperties() throws {
        let model = WallpaperModel()
        let videoURL = tempDirectory.appendingPathComponent("unloaded-empty-\(UUID().uuidString).mp4")
        let path = videoURL.path
        try Data([0, 1, 2]).write(to: videoURL)

        let sceneURL = SceneStore.folderURL(forVideoPath: path)
        try FileManager.default.createDirectory(at: sceneURL, withIntermediateDirectories: true)

        let document = SceneDocument(canvasWidth: 100, canvasHeight: 100, layers: [], properties: nil)
        let sceneData = try JSONEncoder().encode(document)
        try sceneData.write(to: sceneURL.appendingPathComponent("scene.json"))

        var changeCount = 0
        let cancellable = model.objectWillChange.sink { _ in
            changeCount += 1
        }
        defer { cancellable.cancel() }

        XCTAssertFalse(model.hasAuthorSettings(forPath: path))
        XCTAssertNil(model.sceneDocumentsByPath[path])
        XCTAssertEqual(changeCount, 0)
    }

    func testHasAuthorSettingsForExternalWallpaperDoesNotDecodeSceneJSON() throws {
        let model = WallpaperModel()
        let sceneFolder = tempDirectory.appendingPathComponent("external-scene-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sceneFolder, withIntermediateDirectories: true)

        let sceneJSONURL = sceneFolder.appendingPathComponent("scene.json")
        try "CORRUPT_OR_MASSIVE_JSON".data(using: .utf8)!.write(to: sceneJSONURL)

        let wallpaper = ExternalWallpaper(
            id: "provider/test-item",
            providerName: "Test Provider",
            name: "External Scene",
            path: "",
            sceneFolderPath: sceneFolder.path,
            properties: nil
        )

        XCTAssertFalse(model.hasAuthorSettings(forExternalWallpaper: wallpaper))
        XCTAssertNil(model.authorSettingsContext(forExternalWallpaper: wallpaper))
    }

    func testHasAuthorSettingsForExternalWallpaperRelyOnPropertiesOrPropertiesJSON() throws {
        let model = WallpaperModel()
        let sceneFolder = tempDirectory.appendingPathComponent("external-props-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sceneFolder, withIntermediateDirectories: true)

        let prop = LocalWebProperty(
            id: "color",
            kind: "color",
            label: ["en": "Color"],
            value: .string("#ffffff")
        )

        let wallpaperWithProps = ExternalWallpaper(
            id: "provider/props-1",
            providerName: "Provider",
            name: "With Props",
            path: "",
            properties: [prop]
        )
        XCTAssertTrue(model.hasAuthorSettings(forExternalWallpaper: wallpaperWithProps))

        let wallpaperEmptyProps = ExternalWallpaper(
            id: "provider/props-2",
            providerName: "Provider",
            name: "Empty Props",
            path: "",
            properties: []
        )
        XCTAssertFalse(model.hasAuthorSettings(forExternalWallpaper: wallpaperEmptyProps))

        let propData = try JSONEncoder().encode([prop])
        try propData.write(to: sceneFolder.appendingPathComponent("properties.json"))
        let wallpaperWithPropJSON = ExternalWallpaper(
            id: "provider/props-3",
            providerName: "Provider",
            name: "With Prop JSON",
            path: "",
            sceneFolderPath: sceneFolder.path,
            properties: nil
        )
        XCTAssertTrue(model.hasAuthorSettings(forExternalWallpaper: wallpaperWithPropJSON))
    }

    func testHasAuthorSettingsForPathSkipsMassiveSceneJSON() throws {
        let model = WallpaperModel()
        let videoURL = tempDirectory.appendingPathComponent("massive-\(UUID().uuidString).mp4")
        let path = videoURL.path
        try Data([0, 1, 2]).write(to: videoURL)

        let sceneURL = SceneStore.folderURL(forVideoPath: path)
        try FileManager.default.createDirectory(at: sceneURL, withIntermediateDirectories: true)

        // Write a 6MB dummy scene.json (exceeds the 5MB MainActor safety threshold)
        let massiveData = Data(count: 6 * 1024 * 1024)
        try massiveData.write(to: sceneURL.appendingPathComponent("scene.json"))

        var changeCount = 0
        let cancellable = model.objectWillChange.sink { _ in
            changeCount += 1
        }
        defer { cancellable.cancel() }

        // Must return false without decoding 6MB on MainActor, and must not mutate @Published state
        XCTAssertFalse(model.hasAuthorSettings(forPath: path))
        XCTAssertNil(model.authorSettingsContext(forPath: path))
        XCTAssertNil(model.sceneDocumentsByPath[path])
        XCTAssertEqual(changeCount, 0)
    }
    func testResetDoesNotResurrectLegacySettings() throws {
        let model = WallpaperModel()
        let video = tempDirectory.appendingPathComponent("reset-\(UUID().uuidString).mp4")
        let normalizedKey = "authorSettings.scene." + video.standardizedFileURL.path
        let legacyKey = "authorSettings.scene." + video.lastPathComponent
        createdUserDefaultsKeys.formUnion([normalizedKey, legacyKey])
        let property = LocalWebProperty(id: "speed", kind: "slider", label: ["en": "Speed"], value: .number(1))
        model.sceneDocumentsByPath[video.path] = SceneDocument(canvasWidth: 100, canvasHeight: 80, layers: [], properties: [property])
        try LocalWebSettings(values: ["speed": .number(9)]).save(key: legacyKey)
        let context = try XCTUnwrap(model.authorSettingsContext(forPath: video.path))
        XCTAssertEqual(try context.loadSettings().values["speed"], .number(9))
        try context.saveSettings(LocalWebSettings())
        XCTAssertTrue(try context.loadSettings().values.isEmpty)
        XCTAssertNil(SceneMetalLayer.loadUserProperties(forVideoPath: video.path))
    }

    func testAuthorSettingsKeepUnbakedVideoStaleAcrossModelReload() throws {
        let path = tempDirectory.appendingPathComponent("deferred.mp4").path
        try Data([0, 1, 2]).write(to: URL(fileURLWithPath: path))
        let document = SceneDocument(canvasWidth: 100, canvasHeight: 80, layers: [])
        try SceneStore.save(document, videoPath: path)
        let sceneJSON = SceneStore.folderURL(forVideoPath: path).appendingPathComponent("scene.json")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: sceneJSON.path)
        XCTAssertFalse(SceneStore.isNewerThanVideo(videoPath: path))
        let model = WallpaperModel()
        model.sceneDocumentsByPath[path] = document
        try model.applySceneAuthorSettings(forPath: path, settings: LocalWebSettings(values: ["speed": .number(2)]))
        XCTAssertTrue(SceneStore.isNewerThanVideo(videoPath: path))
        let reloadedModel = WallpaperModel()
        reloadedModel.registerImportedScene(try XCTUnwrap(SceneStore.load(videoPath: path)), path: path)
        XCTAssertTrue(reloadedModel.sceneStaleVideoPaths.contains(path))
    }

    func testExternalWebIntegrationSettingsRemainAvailableWithoutProperties() throws {
        let model = WallpaperModel()
        let folder = tempDirectory.appendingPathComponent("audio.web")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: folder.appendingPathComponent("index.html"))
        let package = LocalWebWallpaperPackage(entryPoint: "index.html", properties: [], supportsSpectrum: true, supportsMedia: true)
        try JSONEncoder().encode(package).write(to: folder.appendingPathComponent(LocalWebWallpaperPackage.fileName))
        let source = WebWallpaperSource(url: folder.appendingPathComponent("index.html"), localFolderPath: folder.path)
        let wallpaper = ExternalWallpaper(id: "audio", providerName: "Test", name: "Audio", path: "", webSource: source, properties: [])
        XCTAssertTrue(model.hasAuthorSettings(forExternalWallpaper: wallpaper))
        let context = try XCTUnwrap(model.authorSettingsContext(forExternalWallpaper: wallpaper))
        XCTAssertTrue(context.supportsSpectrum)
        XCTAssertTrue(context.supportsMedia)
    }

    func testScenePruningKeepsAuthorPropertiesSidecar() throws {
        let path = tempDirectory.appendingPathComponent("prune.mp4").path
        let document = SceneDocument(canvasWidth: 100, canvasHeight: 80, layers: [])
        try SceneStore.save(document, videoPath: path)
        let properties = SceneStore.folderURL(forVideoPath: path).appendingPathComponent("properties.json")
        try Data("[]".utf8).write(to: properties)
        WallpaperModel().pruneSceneFiles(document, path: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: properties.path))
    }

    func testSceneImportRejectsSymbolicAuthorPropertiesSidecar() throws {
        let sourceVideo = tempDirectory.appendingPathComponent("source.mp4")
        let document = SceneDocument(canvasWidth: 100, canvasHeight: 80, layers: [])
        try SceneStore.save(document, videoPath: sourceVideo.path)
        let outside = tempDirectory.appendingPathComponent("outside.json")
        try Data("[]".utf8).write(to: outside)
        let source = SceneStore.folderURL(forVideoPath: sourceVideo.path)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("properties.json"), withDestinationURL: outside)
        let destination = tempDirectory.appendingPathComponent("destination.mp4").path
        XCTAssertThrowsError(try SceneStore.importScene(from: source, videoPath: destination))
        XCTAssertFalse(SceneStore.hasScene(videoPath: destination))
    }

    func testLegacyLibraryCopyUsesProviderSchemaWithoutModifyingScene() throws {
        let model = WallpaperModel()
        let path = tempDirectory.appendingPathComponent("old-import.mp4").path
        let document = SceneDocument(canvasWidth: 100, canvasHeight: 80, layers: [])
        let property = LocalWebProperty(id: "speed", kind: "slider", label: ["en": "Speed"], value: .number(1))
        let externalID = "provider/legacy"
        model.importedExternalWallpaperPaths[externalID] = path
        model.externalWallpapers = [ExternalWallpaper(id: externalID, providerName: "Provider", name: "Legacy", path: "/provider/video.mp4", properties: [property])]
        model.sceneDocumentsByPath[path] = document
        var changeCount = 0
        let subscription = model.objectWillChange.sink { _ in changeCount += 1 }
        defer { subscription.cancel() }
        XCTAssertTrue(model.hasAuthorSettings(forPath: path))
        let context = try XCTUnwrap(model.authorSettingsContext(forPath: path))
        XCTAssertEqual(context.properties, [property])
        XCTAssertEqual(model.sceneDocumentsByPath[path], document)
        XCTAssertEqual(changeCount, 0)
        model.sceneDocumentsByPath[path]?.properties = []
        XCTAssertFalse(model.hasAuthorSettings(forPath: path))
        XCTAssertNil(model.authorSettingsContext(forPath: path))
    }

    func testLegacyLibraryCopyCanReadProviderSidecar() throws {
        let model = WallpaperModel()
        let path = tempDirectory.appendingPathComponent("old-import-sidecar.mp4").path
        let folder = tempDirectory.appendingPathComponent("provider.scene")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let property = LocalWebProperty(id: "tint", kind: "color", label: ["en": "Tint"], value: .string("1 0 0"))
        try JSONEncoder().encode([property]).write(to: folder.appendingPathComponent("properties.json"))
        let externalID = "provider/legacy-sidecar"
        model.importedExternalWallpaperPaths[externalID] = path
        model.externalWallpapers = [ExternalWallpaper(id: externalID, providerName: "Provider", name: "Legacy", path: "/provider/video.mp4", sceneFolderPath: folder.path)]
        model.sceneDocumentsByPath[path] = SceneDocument(canvasWidth: 100, canvasHeight: 80, layers: [])
        XCTAssertTrue(model.hasAuthorSettings(forPath: path))
        XCTAssertEqual(try XCTUnwrap(model.authorSettingsContext(forPath: path)).properties, [property])
    }

}

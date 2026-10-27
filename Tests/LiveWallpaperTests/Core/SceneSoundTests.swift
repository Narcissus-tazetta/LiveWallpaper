import AVFoundation
import XCTest
@testable import LiveWallpaper

@MainActor
final class SceneSoundTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SceneSound-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A one second mono tone. Every test plays it at master volume 0, so nothing is heard.
    private func writeTone(_ name: String) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let file = try AVAudioFile(forWriting: folder.appendingPathComponent(name), settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
        buffer.frameLength = 8000
        for index in 0 ..< 8000 { buffer.floatChannelData![0][index] = sin(Float(index) / 10) * 0.2 }
        try file.write(from: buffer)
    }

    private func player() -> SceneSoundPlayer {
        let player = SceneSoundPlayer()
        player.masterVolume = 0
        return player
    }

    private func wait(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testSoundsRoundTripAndTheirFilesAreKept() throws {
        var sound = SceneSound(name: "BGM", files: ["sound-1.mp3"])
        sound.volume = 0.5
        sound.mode = .random
        sound.startsSilent = true
        var document = SceneDocument(canvasWidth: 10, canvasHeight: 10, layers: [])
        document.sounds = [sound]
        let decoded = try JSONDecoder().decode(SceneDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded.sounds, [sound])
        XCTAssertEqual(SceneStore.referencedFiles(of: decoded), ["sound-1.mp3"])
    }

    func testScenesSavedWithoutSoundsStillLoad() throws {
        let document = SceneDocument(canvasWidth: 10, canvasHeight: 10, layers: [])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        json.removeValue(forKey: "sounds")
        let decoded = try JSONDecoder().decode(SceneDocument.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.sounds, [])
    }

    func testSoundFilesCannotLeaveTheSceneFolder() throws {
        let document = SceneDocument(canvasWidth: 10, canvasHeight: 10, layers: [])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        json["sounds"] = [["id": UUID().uuidString, "name": "x", "files": ["../../secret.mp3"]]]
        XCTAssertThrowsError(try JSONDecoder().decode(SceneDocument.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    func testLoopPlaysOnlyWhileActiveAndPausesInBetween() throws {
        try writeTone("tone.wav")
        let sound = SceneSound(name: "BGM", files: ["tone.wav"])
        let player = player()
        player.configure(key: "a", folder: folder, sounds: [sound])
        XCTAssertEqual(player.playingSoundIDs, [], "Nothing plays until the caller allows it")
        player.isActive = true
        XCTAssertEqual(player.playingSoundIDs, [sound.id])
        player.isActive = false
        XCTAssertEqual(player.playingSoundIDs, [])
        player.isActive = true
        XCTAssertEqual(player.playingSoundIDs, [sound.id])
        player.stop()
        XCTAssertEqual(player.playingSoundIDs, [])
        XCTAssertNil(player.key)
    }

    func testLoopKeepsPlayingPastTheEndOfTheFile() throws {
        try writeTone("tone.wav")
        let sound = SceneSound(name: "BGM", files: ["tone.wav"])
        let player = player()
        player.configure(key: "a", folder: folder, sounds: [sound])
        player.isActive = true
        wait(1.4)
        XCTAssertEqual(player.playingSoundIDs, [sound.id])
    }

    func testSeveralFilesFollowEachOther() throws {
        try writeTone("one.wav")
        try writeTone("two.wav")
        let sound = SceneSound(name: "BGM", files: ["one.wav", "two.wav"])
        let player = player()
        player.configure(key: "a", folder: folder, sounds: [sound])
        player.isActive = true
        wait(1.4)
        XCTAssertEqual(player.playingSoundIDs, [sound.id], "The second file takes over when the first ends")
    }

    func testReconfiguringTheSameSceneKeepsPlaying() throws {
        try writeTone("tone.wav")
        let sound = SceneSound(name: "BGM", files: ["tone.wav"])
        let player = player()
        player.configure(key: "a", folder: folder, sounds: [sound])
        player.isActive = true
        wait(0.3)
        player.configure(key: "a", folder: folder, sounds: [sound])
        XCTAssertEqual(player.playingSoundIDs, [sound.id])
        let other = SceneSound(name: "Other", files: ["tone.wav"])
        player.configure(key: "b", folder: folder, sounds: [other])
        XCTAssertEqual(player.playingSoundIDs, [other.id], "A different scene replaces the sounds")
    }

    func testRandomSoundWaitsItsPauseBeforeThePlayStarts() throws {
        try writeTone("tone.wav")
        var sound = SceneSound(name: "Ambient", files: ["tone.wav"])
        sound.mode = .random
        sound.startsSilent = true
        sound.minimumPause = 0.2
        sound.maximumPause = 0.2
        let player = player()
        player.randomPause = { $0.lowerBound }
        player.configure(key: "a", folder: folder, sounds: [sound])
        player.isActive = true
        XCTAssertEqual(player.playingSoundIDs, [])
        XCTAssertEqual(player.waitingSoundIDs, [sound.id])
        wait(0.5)
        XCTAssertEqual(player.playingSoundIDs, [sound.id])
        player.isActive = false
        XCTAssertEqual(player.waitingSoundIDs, [])
    }

    func testSingleSoundIsNotStartedByASilentStart() throws {
        try writeTone("tone.wav")
        var sound = SceneSound(name: "Click", files: ["tone.wav"])
        sound.mode = .single
        sound.startsSilent = true
        let player = player()
        player.configure(key: "a", folder: folder, sounds: [sound])
        player.isActive = true
        wait(0.2)
        XCTAssertEqual(player.playingSoundIDs, [])
    }

    func testScriptedSoundStaysQuietUntilTheScriptReports() throws {
        try writeTone("tone.wav")
        var sound = SceneSound(name: "Track", files: ["tone.wav"])
        sound.volumeIsScripted = true
        let player = player()
        player.configure(key: "a", folder: folder, sounds: [sound])
        player.isActive = true
        XCTAssertEqual(player.playingSoundIDs, [])
        player.setScriptedSounds([sound.id: SceneScriptedSound(volume: 0.7, playing: true, plays: 0, stops: 0)])
        XCTAssertEqual(player.playingSoundIDs, [sound.id])
    }

    func testSilentStartWaitsForAScriptThatPlaysStopsAndPlaysAgain() throws {
        try writeTone("tone.wav")
        var sound = SceneSound(name: "BGM", files: ["tone.wav"])
        sound.startsSilent = true
        let player = player()
        player.configure(key: "a", folder: folder, sounds: [sound])
        player.isActive = true
        wait(0.2)
        XCTAssertEqual(player.playingSoundIDs, [], "A loop that starts silent waits for its script")
        func report(playing: Bool, plays: Int, stops: Int) {
            player.setScriptedSounds([sound.id: SceneScriptedSound(volume: 1, playing: playing, plays: plays, stops: stops)])
        }
        report(playing: false, plays: 0, stops: 0)
        XCTAssertEqual(player.playingSoundIDs, [])
        report(playing: true, plays: 1, stops: 0)
        XCTAssertEqual(player.playingSoundIDs, [sound.id])
        report(playing: false, plays: 1, stops: 1)
        XCTAssertEqual(player.playingSoundIDs, [])
        report(playing: true, plays: 2, stops: 1)
        XCTAssertEqual(player.playingSoundIDs, [sound.id])
    }

    func testScriptPausingKeepsThePlaceAndAnotherPlayRestarts() throws {
        try writeTone("tone.wav")
        var sound = SceneSound(name: "Click", files: ["tone.wav"])
        sound.mode = .single
        sound.startsSilent = true
        let player = player()
        player.configure(key: "a", folder: folder, sounds: [sound])
        player.isActive = true
        func report(playing: Bool, plays: Int) {
            player.setScriptedSounds([sound.id: SceneScriptedSound(volume: 1, playing: playing, plays: plays, stops: 0)])
        }
        report(playing: true, plays: 1)
        XCTAssertEqual(player.playingSoundIDs, [sound.id])
        wait(0.3)
        report(playing: false, plays: 1)
        XCTAssertEqual(player.playingSoundIDs, [])
        report(playing: true, plays: 1)
        XCTAssertEqual(player.playingSoundIDs, [sound.id], "Playing again after a pause carries on")
        wait(1.2)
        XCTAssertEqual(player.playingSoundIDs, [], "A single sound ends with its file")
        report(playing: true, plays: 2)
        XCTAssertEqual(player.playingSoundIDs, [sound.id], "Each play() call plays it once more")
    }

    func testSoundOutputOfScriptsIsValidated() throws {
        let id = UUID()
        let good: [Any] = [["id": id.uuidString, "volume": 0.5, "playing": true, "plays": 2, "stops": 1]]
        XCTAssertEqual(try SceneScriptRuntime.readSounds(good), [id: SceneScriptedSound(volume: 0.5, playing: true, plays: 2, stops: 1)])
        let tooLoud: [Any] = [["id": id.uuidString, "volume": 4, "playing": true, "plays": 0, "stops": 0]]
        XCTAssertThrowsError(try SceneScriptRuntime.readSounds(tooLoud))
        let unknownField: [Any] = [["id": id.uuidString, "volume": 1, "playing": true, "plays": 0, "stops": 0, "file": "x"]]
        XCTAssertThrowsError(try SceneScriptRuntime.readSounds(unknownField))
        let twice: [Any] = good + good
        XCTAssertThrowsError(try SceneScriptRuntime.readSounds(twice))
    }

    func testOnlyScriptDrivenSoundsNeedTheSceneDrawnLive() {
        var document = SceneDocument(canvasWidth: 10, canvasHeight: 10, layers: [])
        var script = SceneScript(source: "function update(c){return []}", layerIDs: [])
        script.isAuthorized = true
        var plain = SceneSound(name: "BGM", files: ["a.mp3"])
        document.sounds = [plain]
        document.scripts = [script]
        XCTAssertFalse(document.soundsNeedScripts)
        plain.startsSilent = true
        document.sounds = [plain]
        XCTAssertTrue(document.soundsNeedScripts)
        document.scripts = []
        XCTAssertFalse(document.soundsNeedScripts, "No script to run, no reason to draw live")
    }

    func testAFileThatCannotBeReadDoesNotStopTheOthers() throws {
        try writeTone("tone.wav")
        let broken = SceneSound(name: "Broken", files: ["missing.mp3"])
        let fine = SceneSound(name: "Fine", files: ["tone.wav"])
        let player = player()
        player.configure(key: "a", folder: folder, sounds: [broken, fine])
        player.isActive = true
        XCTAssertEqual(player.playingSoundIDs, [fine.id])
    }

    func testAudioSettingOffNeverAllowsSound() {
        let screens = ["1"]
        XCTAssertFalse(WallpaperModel.sceneSoundIsAllowed(audioEnabled: false, blockers: [], sharedDisplayIDs: screens, suspendedDisplayIDs: []))
        XCTAssertTrue(WallpaperModel.sceneSoundIsAllowed(audioEnabled: true, blockers: [], sharedDisplayIDs: screens, suspendedDisplayIDs: []))
    }

    func testCoveredLockedAndSaverStatesStopSound() {
        func allowed(_ blockers: Set<SceneSoundBlocker> = [], suspended: Set<String> = []) -> Bool {
            WallpaperModel.sceneSoundIsAllowed(
                audioEnabled: true, blockers: blockers, sharedDisplayIDs: ["1", "2"], suspendedDisplayIDs: suspended
            )
        }
        XCTAssertTrue(allowed())
        XCTAssertTrue(allowed(suspended: ["1"]), "One screen still shows the wallpaper")
        XCTAssertFalse(allowed(suspended: ["1", "2"]))
        XCTAssertFalse(allowed([.locked]))
        XCTAssertFalse(allowed([.screenSaver]))
        XCTAssertFalse(allowed([.displayAsleep]))
        XCTAssertFalse(WallpaperModel.sceneSoundIsAllowed(audioEnabled: true, blockers: [], sharedDisplayIDs: [], suspendedDisplayIDs: []))
    }

    func testModelStaysSilentWhileTheAudioSettingIsOff() throws {
        try writeTone("tone.wav")
        let video = folder.appendingPathComponent("wallpaper.mp4").path
        var document = SceneDocument(canvasWidth: 10, canvasHeight: 10, layers: [])
        let sound = SceneSound(name: "BGM", files: ["tone.wav"])
        document.sounds = [sound]
        let model = WallpaperModel()
        model.sceneSoundPlayer.masterVolume = 0
        defer { model.sceneSoundPlayer.stop() }
        model.audioEnabled = false
        model.sceneDocumentsByPath[video] = document
        model.currentVideoPath = video
        model.syncSceneSound()
        XCTAssertEqual(model.sceneSoundPlayer.key, video)
        XCTAssertFalse(model.sceneSoundPlayer.isActive)
        XCTAssertEqual(model.sceneSoundPlayer.playingSoundIDs, [])
        model.currentVideoPath = nil
        model.syncSceneSound()
        XCTAssertNil(model.sceneSoundPlayer.key, "Leaving the scene releases its sounds")
    }
}

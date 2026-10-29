import AVFoundation
import Foundation

/// What the scene's scripts say about a sound this frame (Wallpaper Engine's layer
/// `play`, `pause`, `stop` and `volume`). `plays` and `stops` count the calls, so a
/// second `play()` on a sound that is already playing starts it again.
struct SceneScriptedSound: Equatable {
    var volume: Double
    var playing: Bool
    var plays: Int
    var stops: Int
}

/// Plays the sounds of the scene on screen. It only does what it is told: whether the
/// app's audio setting, the lock screen or a covered wallpaper allows sound is decided by
/// the caller through `isActive` and `masterVolume`.
@MainActor
final class SceneSoundPlayer {
    private final class Voice: NSObject, AVAudioPlayerDelegate {
        let sound: SceneSound
        let urls: [URL]
        var player: AVAudioPlayer?
        var nextIndex = 0
        var pending: DispatchWorkItem?
        /// A `single` sound plays once; a `random` one that has started waits between sounds.
        var started = false
        var script: SceneScriptedSound?
        unowned let owner: SceneSoundPlayer

        init(sound: SceneSound, urls: [URL], owner: SceneSoundPlayer) {
            self.sound = sound
            self.urls = urls
            self.owner = owner
        }

        // Voice is a nested class, so it does not inherit the player's main-actor isolation; reading
        // the owner's masterVolume needs it spelled out or newer compilers reject the access.
        @MainActor var volume: Float {
            Float(min(max(script?.volume ?? sound.volume, 0), 1)) * owner.masterVolume
        }

        /// What the sound does without a script's say: scripted or silent-start sounds wait
        /// for a script, the others start on their own.
        var wantsToPlay: Bool {
            if let script { return script.playing }
            if sound.volumeIsScripted { return false }
            return !sound.startsSilent
        }

        func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
            // The documentation does not say which thread calls this.
            DispatchQueue.main.async { [self] in MainActor.assumeIsolated { owner.finished(self) } }
        }
    }

    private(set) var key: String?
    private var sounds: [SceneSound] = []
    private var voices: [Voice] = []
    var masterVolume: Float = 1 {
        didSet { for voice in voices { voice.player?.volume = voice.volume } }
    }

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive { voices.forEach(reconcile) } else { suspend() }
        }
    }

    var randomPause: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }

    /// Sounds whose audio is playing right now.
    var playingSoundIDs: Set<UUID> {
        Set(voices.filter { $0.player?.isPlaying == true }.map(\.sound.id))
    }

    /// Sounds waiting for their turn to start.
    var waitingSoundIDs: Set<UUID> {
        Set(voices.filter { $0.pending != nil }.map(\.sound.id))
    }

    /// Does nothing when `key` and `sounds` are what is already loaded. Sounds whose
    /// files cannot be read are skipped; the others play.
    func configure(key: String, folder: URL, sounds newSounds: [SceneSound]) {
        guard key != self.key || newSounds != sounds else { return }
        teardown()
        self.key = key
        sounds = newSounds
        for sound in newSounds where !sound.files.isEmpty {
            voices.append(Voice(sound: sound, urls: sound.files.map { folder.appendingPathComponent($0) }, owner: self))
        }
        if isActive { voices.forEach(reconcile) }
    }

    /// What the scene's scripts made of each sound, by sound ID.
    func setScriptedSounds(_ states: [UUID: SceneScriptedSound]) {
        for voice in voices {
            guard let state = states[voice.sound.id], state.volume.isFinite else { continue }
            let previous = voice.script
            voice.script = state
            if state.stops != (previous?.stops ?? 0) || state.plays != (previous?.plays ?? 0) {
                halt(voice)
            }
            voice.player?.volume = voice.volume
            reconcile(voice)
        }
    }

    func stop() {
        teardown()
        key = nil
        sounds = []
    }

    private func teardown() {
        voices.forEach(halt)
        voices = []
    }

    /// Back to the start, as `stop()` of a sound layer leaves it.
    private func halt(_ voice: Voice) {
        voice.pending?.cancel()
        voice.pending = nil
        voice.player?.delegate = nil
        voice.player?.stop()
        voice.player = nil
        voice.nextIndex = 0
        voice.started = false
    }

    private func suspend() {
        for voice in voices {
            voice.pending?.cancel()
            voice.pending = nil
            voice.player?.pause()
        }
    }

    private func reconcile(_ voice: Voice) {
        guard isActive else { return }
        guard voice.wantsToPlay else {
            voice.pending?.cancel()
            voice.pending = nil
            voice.player?.pause()
            return
        }
        if let player = voice.player {
            if !player.isPlaying { play(player, voice: voice) }
            return
        }
        guard voice.pending == nil else { return }
        switch voice.sound.mode {
        case .loop:
            begin(voice)
        case .random:
            voice.started ? waitThenPlay(voice) : begin(voice)
        case .single:
            if !voice.started { begin(voice) }
        }
    }

    private func begin(_ voice: Voice) {
        voice.started = true
        let index = voice.sound.mode == .random ? Int.random(in: 0 ..< voice.urls.count) : voice.nextIndex % voice.urls.count
        voice.nextIndex = index + 1
        let url = voice.urls[index]
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = voice
            // One looping file needs no hand-over; with several, the next one starts when this ends.
            player.numberOfLoops = voice.sound.mode == .loop && voice.urls.count == 1 ? -1 : 0
            player.volume = voice.volume
            voice.player = player
            play(player, voice: voice)
        } catch {
            AppLog.sceneSound.error("scene sound unreadable file=\(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func play(_ player: AVAudioPlayer, voice: Voice) {
        if !player.play() {
            AppLog.sceneSound.error("scene sound did not start name=\(voice.sound.name, privacy: .public)")
        }
    }

    private func waitThenPlay(_ voice: Voice) {
        let item = DispatchWorkItem { [weak self, weak voice] in
            guard let self, let voice else { return }
            voice.pending = nil
            if isActive { begin(voice) }
        }
        voice.pending?.cancel()
        voice.pending = item
        let pause = randomPause(voice.sound.minimumPause ... voice.sound.maximumPause)
        DispatchQueue.main.asyncAfter(deadline: .now() + pause, execute: item)
    }

    private func finished(_ voice: Voice) {
        guard voices.contains(where: { $0 === voice }), isActive else { return }
        switch voice.sound.mode {
        case .loop:
            begin(voice)
        case .random:
            voice.player = nil
            waitThenPlay(voice)
        case .single:
            voice.player = nil
        }
    }
}

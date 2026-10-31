import AppKit
import Combine

/// The sounds of a scene (SceneDocument.sounds). They play only while the audio setting
/// is on and the wallpaper is on screen, which the same suspension state that pauses the
/// shared video decides (coverage, pause, battery, Reduce Motion). The lock screen and
/// the screen saver are added here: coverage is optional and arrives after a delay, and a
/// scene's music must never leak onto a locked Mac.
enum SceneSoundBlocker: Hashable {
    case locked, screenSaver, displayAsleep
}

@MainActor
extension WallpaperModel {
    func configureSceneSoundMonitoring() {
        // @Published fires before the new value is stored, so read it a turn later.
        sceneSoundCancellable = Publishers.MergeMany(
            $currentVideoPath.map { _ in () }.eraseToAnyPublisher(),
            $sceneDocumentsByPath.map { _ in () }.eraseToAnyPublisher(),
            $wallpaperKind.map { _ in () }.eraseToAnyPublisher(),
            $activeExternalWallpaperID.map { _ in () }.eraseToAnyPublisher(),
            $audioEnabled.map { _ in () }.eraseToAnyPublisher(),
            $audioVolume.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            MainActor.assumeIsolated { self?.syncSceneSound() }
        }

        // A scene whose sounds only scripts drive is drawn live while the audio setting is on.
        sceneSoundLiveCancellable = $audioEnabled.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.sceneDocumentsByPath.values.contains(where: \.soundsNeedScripts) else { return }
                    self.refreshSceneHosts()
                }
            }

        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        // Locked, screen saver and display sleep are tracked apart: waking the display
        // must not unmute a Mac that is still locked.
        let changes: [(NotificationCenter, Notification.Name, SceneSoundBlocker, Bool)] = [
            (distributed, Notification.Name("com.apple.screenIsLocked"), .locked, true),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), .locked, false),
            (distributed, Notification.Name("com.apple.screensaver.didstart"), .screenSaver, true),
            (distributed, Notification.Name("com.apple.screensaver.didstop"), .screenSaver, false),
            (workspace, NSWorkspace.screensDidSleepNotification, .displayAsleep, true),
            (workspace, NSWorkspace.screensDidWakeNotification, .displayAsleep, false)
        ]
        sceneSoundBlockers = []
        sceneSoundObservers = changes.map { center, name, blocker, blocks in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if blocks { self.sceneSoundBlockers.insert(blocker) } else { self.sceneSoundBlockers.remove(blocker) }
                    self.syncSceneSound()
                }
            }
        }
    }

    /// Whether the scene on the shared player's screens may be heard right now.
    var sceneSoundIsAllowed: Bool {
        let displayCount = max(playerViews.count, windows.count)
        return Self.sceneSoundIsAllowed(
            audioEnabled: audioEnabled, blockers: sceneSoundBlockers,
            sharedDisplayIDs: sharedPlayerDisplayIDs(among: (0 ..< displayCount).map { displayIDForWindow(at: $0) }),
            suspendedDisplayIDs: suspendedDisplayIDs
        )
    }

    /// Sound follows the video: it stops once every screen showing it is suspended.
    nonisolated static func sceneSoundIsAllowed(
        audioEnabled: Bool, blockers: Set<SceneSoundBlocker>, sharedDisplayIDs: [String], suspendedDisplayIDs: Set<String>
    ) -> Bool {
        audioEnabled && blockers.isEmpty && !sharedDisplayIDs.isEmpty
            && !sharedDisplayIDs.allSatisfy { suspendedDisplayIDs.contains($0) }
    }

    func syncSceneSound() {
        guard !isWebWallpaperActive, let path = currentVideoPath,
              let document = sceneDocumentsByPath[path], !document.sounds.isEmpty
        else {
            sceneSoundPlayer.stop()
            return
        }
        sceneSoundPlayer.configure(
            key: path, folder: SceneStore.folderURL(forVideoPath: path), sounds: document.sounds
        )
        sceneSoundPlayer.masterVolume = audioVolume
        sceneSoundPlayer.isActive = sceneSoundIsAllowed
    }
}

extension WallpaperModel {
    func updateSceneSounds(path: String, _ change: (inout [SceneSound]) -> Void) {
        guard var document = sceneDocumentsByPath[path] else { return }
        change(&document.sounds)
        updateScene(document, path: path)
    }

    /// Copies each audio file into the scene folder and adds a looping sound for it.
    func addSceneSounds(from urls: [URL], path: String) {
        guard var document = sceneDocumentsByPath[path] else { return }
        let folder = SceneStore.folderURL(forVideoPath: path)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for url in urls where document.sounds.count < SceneSound.maximumCount {
                let source = url.resolvingSymlinksInPath()
                let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
                let fileName = "sound-\(UUID().uuidString).\(ext)"
                try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(fileName))
                document.sounds.append(SceneSound(name: source.deletingPathExtension().lastPathComponent, files: [fileName]))
            }
        } catch {
            AppLog.windowRefresh.error("adding scene sound failed: \(error.localizedDescription, privacy: .public)")
            sceneErrorMessage = error.localizedDescription
        }
        updateScene(document, path: path, coalescing: false)
    }
}

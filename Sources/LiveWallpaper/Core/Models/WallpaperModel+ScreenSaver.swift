import Combine
import Foundation

@MainActor
extension WallpaperModel {
    func refreshScreenSaverInstallState() {
        screenSaverInstallState = screenSaverInstaller.state()
    }

    func installScreenSaver() {
        UserDefaults.standard.set(true, forKey: PrefsKey.screenSaverEnabled)
        do {
            try screenSaverInstaller.install()
            screenSaverErrorMessage = nil
            // The write is gated on the install state, so refresh it first.
            refreshScreenSaverInstallState()
            writeScreenSaverConfigIfInstalled(force: true)
        } catch {
            AppLog.appDelegate.error("screensaver install failed: \(error.localizedDescription, privacy: .public)")
            screenSaverErrorMessage = error.localizedDescription
        }
        refreshScreenSaverInstallState()
    }

    func uninstallScreenSaver() {
        UserDefaults.standard.set(false, forKey: PrefsKey.screenSaverEnabled)
        do {
            try screenSaverInstaller.uninstall()
            screenSaverErrorMessage = nil
            lastWrittenScreenSaverConfig = nil
        } catch {
            AppLog.appDelegate.error("screensaver uninstall failed: \(error.localizedDescription, privacy: .public)")
            screenSaverErrorMessage = error.localizedDescription
        }
        refreshScreenSaverInstallState()
    }

    /// Call once at launch. Puts the saver back (removed at the last quit) and keeps its
    /// config following whatever the desktop shows.
    func configureScreenSaverSync() {
        refreshScreenSaverInstallState()
        // Installs made before the preference existed count as enabled.
        let enabled = UserDefaults.standard.object(forKey: PrefsKey.screenSaverEnabled) as? Bool
            ?? isScreenSaverInstalled
        if enabled, screenSaverInstallState != .unavailable {
            installScreenSaver()
        }

        let triggers: [AnyPublisher<Void, Never>] = [
            $currentVideoPath.map { _ in () }.eraseToAnyPublisher(),
            $wallpaperKind.map { _ in () }.eraseToAnyPublisher(),
            $videoOverrideByScreenID.map { _ in () }.eraseToAnyPublisher(),
            $videoBySpaceUUID.map { _ in () }.eraseToAnyPublisher(),
            $currentSpaceUUIDByDisplayID.map { _ in () }.eraseToAnyPublisher(),
            $spaceWallpaperFeatureEnabled.map { _ in () }.eraseToAnyPublisher(),
            $wallpaperEditByPath.map { _ in () }.eraseToAnyPublisher(),
            $wallpaperPresentationByPath.map { _ in () }.eraseToAnyPublisher(),
            $fitMode.map { _ in () }.eraseToAnyPublisher(),
            $displayScreens.map { _ in () }.eraseToAnyPublisher(),
            $videoAspectRatioByPath.map { _ in () }.eraseToAnyPublisher(),
        ]
        // @Published emits on willSet; the debounce also lets the value settle and
        // coalesces bursts such as a schedule switch touching several properties.
        screenSaverSyncCancellable = Publishers.MergeMany(triggers)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.writeScreenSaverConfigIfInstalled(force: false)
            }
    }

    /// Quitting takes the saver out the same way uninstall does, so the previous screen
    /// saver comes back and nothing is left behind if the app is then deleted. The
    /// preference stays on, so the next launch puts it back.
    func removeScreenSaverBeforeExit() {
        guard isScreenSaverInstalled else {
            return
        }
        do {
            try screenSaverInstaller.uninstall()
        } catch {
            AppLog.appDelegate.error("screensaver removal before exit failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var isScreenSaverInstalled: Bool {
        screenSaverInstallState == .installed || screenSaverInstallState == .updateAvailable
    }

    private func writeScreenSaverConfigIfInstalled(force: Bool) {
        guard isScreenSaverInstalled else {
            return
        }
        let config = makeScreenSaverConfig()
        guard force || config != lastWrittenScreenSaverConfig else {
            return
        }
        do {
            try screenSaverInstaller.writeConfig(config)
            lastWrittenScreenSaverConfig = config
        } catch {
            AppLog.appDelegate.error("screensaver config write failed: \(error.localizedDescription, privacy: .public)")
            screenSaverErrorMessage = error.localizedDescription
        }
    }

    /// What each display shows right now. Web wallpapers cannot be played by the
    /// saver, so while one is active the config lists nothing and the saver says so.
    func makeScreenSaverConfig() -> ScreenSaverConfig {
        guard !isWebWallpaperActive else {
            return ScreenSaverConfig(displays: [:], fallback: nil)
        }
        var displays: [String: ScreenSaverConfig.Display] = [:]
        for screen in displayScreens {
            let path = resolvedOverridePath(forScreenID: screen.id) ?? currentVideoPath
            if let path, let display = screenSaverDisplay(path: path, screenID: screen.id) {
                displays[screen.id] = display
            }
        }
        let fallback = currentVideoPath.flatMap { path in
            screenSaverDisplay(path: path, screenID: displayScreens.first?.id ?? "main")
        }
        return ScreenSaverConfig(displays: displays, fallback: fallback)
    }

    private func screenSaverDisplay(path: String, screenID: String) -> ScreenSaverConfig.Display? {
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        let edit = wallpaperEditByPath[path]
        let hasEdit = edit.map { !$0.isNoOp } ?? false
        return ScreenSaverConfig.Display(
            videoPath: path,
            fitMode: wallpaperFitMode(path: path, screenID: screenID),
            zoom: wallpaperZoom(path: path, screenID: screenID),
            offsetX: wallpaperOffsetX(path: path, screenID: screenID),
            offsetY: wallpaperOffsetY(path: path, screenID: screenID),
            videoAspectRatio: videoAspectRatioByPath[path],
            trimStart: hasEdit ? edit?.trimStart ?? 0 : 0,
            trimEnd: hasEdit ? edit?.trimEnd : nil,
            loopStart: hasEdit ? edit?.loopStart : nil
        )
    }
}

import AppKit

extension AppDelegate {
    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureStatusIcon()

        let menu = NSMenu()
        menu.showsStateColumn = false
        let openWallpaperItem = NSMenuItem(
            title: localized("壁紙を開く"),
            action: #selector(openWallpaperTab),
            keyEquivalent: ""
        )
        openWallpaperItem.image = wallpaperMenuIcon()
        openWallpaperItem.tag = MenuTag.openWallpaper
        menu.addItem(openWallpaperItem)
        let openWallpaperFitItem = NSMenuItem(
            title: localized("壁紙設定を開く"),
            action: #selector(openWallpaperFitTab),
            keyEquivalent: ""
        )
        openWallpaperFitItem.image = wallpaperFitMenuIcon()
        openWallpaperFitItem.tag = MenuTag.openWallpaperFit
        menu.addItem(openWallpaperFitItem)
        let openSettingsItem = NSMenuItem(
            title: localized("設定を開く"),
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        openSettingsItem.tag = MenuTag.openSettings
        menu.addItem(openSettingsItem)

        let toggleItem = NSMenuItem(
            title: audioMenuTitle(wallpaperModel.audioEnabled),
            action: #selector(toggleAudioEnabled),
            keyEquivalent: ""
        )
        toggleItem.image = audioMenuIcon(wallpaperModel.audioEnabled)
        toggleItem.tag = MenuTag.audioToggle
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        let playlistItem = NSMenuItem(
            title: playlistMenuTitle(wallpaperModel.playlistPlaybackEnabled),
            action: #selector(togglePlaylistPlayback),
            keyEquivalent: ""
        )
        playlistItem.image = playlistMenuIcon()
        playlistItem.tag = MenuTag.playlistToggle
        menu.addItem(playlistItem)

        let pinItem = NSMenuItem(
            title: pinCurrentVideoMenuTitle(wallpaperModel.pinCurrentVideo),
            action: #selector(togglePinCurrentVideo),
            keyEquivalent: ""
        )
        pinItem.image = pinCurrentVideoMenuIcon()
        pinItem.tag = MenuTag.pinCurrentVideoToggle
        menu.addItem(pinItem)

        let shuffleItem = NSMenuItem(
            title: shuffleMenuTitle(wallpaperModel.shufflePlaybackEnabled),
            action: #selector(toggleShufflePlayback),
            keyEquivalent: ""
        )
        shuffleItem.image = shuffleMenuIcon()
        shuffleItem.tag = MenuTag.shuffleToggle
        menu.addItem(shuffleItem)

        let previousItem = NSMenuItem(
            title: localized("前の動画"),
            action: #selector(playPreviousVideo),
            keyEquivalent: "["
        )
        previousItem.image = previousVideoMenuIcon()
        previousItem.tag = MenuTag.previousVideo
        menu.addItem(previousItem)

        let nextItem = NSMenuItem(
            title: localized("次の動画"),
            action: #selector(playNextVideo),
            keyEquivalent: "]"
        )
        nextItem.image = nextVideoMenuIcon()
        nextItem.tag = MenuTag.nextVideo
        menu.addItem(nextItem)

        let refreshItem = NSMenuItem(
            title: localized("再生をリフレッシュ"),
            action: #selector(refreshPlaybackState),
            keyEquivalent: "r"
        )
        refreshItem.image = refreshMenuIcon()
        refreshItem.tag = MenuTag.refreshPlayback
        menu.addItem(refreshItem)

        let exportItem = NSMenuItem(
            title: localized("壁紙を共有"),
            action: #selector(exportPackage),
            keyEquivalent: "e"
        )
        exportItem.image = NSImage(
            systemSymbolName: "square.and.arrow.up",
            accessibilityDescription: "Share"
        )
        exportItem.tag = MenuTag.exportPackage
        menu.addItem(exportItem)

        let importItem = NSMenuItem(
            title: localized("壁紙を読み込む"),
            action: #selector(importPackage),
            keyEquivalent: "i"
        )
        importItem.image = NSImage(
            systemSymbolName: "square.and.arrow.down",
            accessibilityDescription: "Import"
        )
        importItem.tag = MenuTag.importPackage
        menu.addItem(importItem)

        wallpaperModel.$audioEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let item = self?.statusItem?.menu?.item(withTag: MenuTag.audioToggle)
                else { return }
                item.title = self?.audioMenuTitle(enabled) ?? ""
                item.image = self?.audioMenuIcon(enabled)
            }
            .store(in: &cancellables)

        wallpaperModel.$playlistPlaybackEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else {
                    return
                }
                if let item = statusItem?.menu?.item(withTag: MenuTag.playlistToggle) {
                    item.title = playlistMenuTitle(enabled)
                    item.image = playlistMenuIcon()
                }
                refreshPlaybackMenuState()
            }
            .store(in: &cancellables)

        wallpaperModel.$pinCurrentVideo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else {
                    return
                }
                if let item = statusItem?.menu?.item(withTag: MenuTag.pinCurrentVideoToggle) {
                    item.title = pinCurrentVideoMenuTitle(enabled)
                    item.image = pinCurrentVideoMenuIcon()
                }
                refreshPlaybackMenuState()
            }
            .store(in: &cancellables)

        wallpaperModel.$shufflePlaybackEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else {
                    return
                }
                if let item = statusItem?.menu?.item(withTag: MenuTag.shuffleToggle) {
                    item.title = shuffleMenuTitle(enabled)
                    item.image = shuffleMenuIcon()
                }
            }
            .store(in: &cancellables)

        wallpaperModel.$registeredVideoPaths
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshPlaybackMenuState()
            }
            .store(in: &cancellables)

        wallpaperModel.$appLanguage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshLocalizedInterface()
            }
            .store(in: &cancellables)

        #if canImport(Sparkle)
            let updateItem = NSMenuItem(
                title: localized("アップデートを確認"),
                action: #selector(checkForUpdates),
                keyEquivalent: "u"
            )
            updateItem.image = updateMenuIcon()
            updateItem.tag = MenuTag.updateMenu
            menu.addItem(updateItem)
        #endif

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(
            title: localized("終了"),
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.tag = MenuTag.quitApp
        menu.addItem(quitItem)

        statusItem?.menu = menu
        refreshPlaybackMenuState()
        refreshLocalizedInterface()
    }

    func configureStatusIcon() {
        guard let button = statusItem?.button else {
            return
        }

        if let image = selectWindowStatusIcon() {
            button.image = image
            button.image?.size = NSSize(width: 18, height: 18)
            button.image?.isTemplate = true
            button.title = ""
            return
        }

        if let fallback = NSImage(
            systemSymbolName: "macwindow.on.rectangle",
            accessibilityDescription: "Live Wallpaper"
        ) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            button.image = fallback.withSymbolConfiguration(config)
            button.image?.isTemplate = true
            button.title = ""
        } else {
            button.title = "LW"
        }
    }

    func selectWindowStatusIcon() -> NSImage? {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else {
            return nil
        }

        context.setStrokeColor(NSColor.labelColor.cgColor)
        context.setLineWidth(1.6)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let backRect = CGRect(x: 3.1, y: 4.2, width: 9.4, height: 8.0)
        let frontRect = CGRect(x: 5.5, y: 6.4, width: 9.4, height: 8.0)
        context.stroke(backRect.insetBy(dx: 0.35, dy: 0.35))
        context.stroke(frontRect.insetBy(dx: 0.35, dy: 0.35))

        image.isTemplate = true
        return image
    }

    func appIconImage() -> NSImage? {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            return NSImage(contentsOf: iconURL)
        }
        return nil
    }

    func refreshPlaybackMenuState() {
        let hasMultipleVideos = wallpaperModel.registeredVideoPaths.count > 1
        let playlistEnabled = wallpaperModel.playlistPlaybackEnabled
        let canPin = wallpaperModel.canPinCurrentVideo

        if let pinItem = statusItem?.menu?.item(withTag: MenuTag.pinCurrentVideoToggle) {
            pinItem.isHidden = !canPin
            pinItem.title = pinCurrentVideoMenuTitle(wallpaperModel.pinCurrentVideo)
            pinItem.image = pinCurrentVideoMenuIcon()
        }
        if let shuffleItem = statusItem?.menu?.item(withTag: MenuTag.shuffleToggle) {
            shuffleItem.isEnabled =
                playlistEnabled && hasMultipleVideos && !wallpaperModel.pinCurrentVideo
        }
        if let previousItem = statusItem?.menu?.item(withTag: MenuTag.previousVideo) {
            previousItem.isEnabled = hasMultipleVideos
        }
        if let nextItem = statusItem?.menu?.item(withTag: MenuTag.nextVideo) {
            nextItem.isEnabled = hasMultipleVideos
        }
    }

    func refreshLocalizedInterface() {
        guard let menu = statusItem?.menu else {
            return
        }

        if let item = menu.item(withTag: MenuTag.openWallpaper) {
            item.title = localized("壁紙を開く")
        }
        if let item = menu.item(withTag: MenuTag.openWallpaperFit) {
            item.title = localized("壁紙設定を開く")
        }
        if let item = menu.item(withTag: MenuTag.openSettings) {
            item.title = localized("設定を開く")
        }
        if let item = menu.item(withTag: MenuTag.audioToggle) {
            item.title = audioMenuTitle(wallpaperModel.audioEnabled)
        }
        if let item = menu.item(withTag: MenuTag.playlistToggle) {
            item.title = playlistMenuTitle(wallpaperModel.playlistPlaybackEnabled)
        }
        if let item = menu.item(withTag: MenuTag.pinCurrentVideoToggle) {
            item.title = pinCurrentVideoMenuTitle(wallpaperModel.pinCurrentVideo)
        }
        if let item = menu.item(withTag: MenuTag.shuffleToggle) {
            item.title = shuffleMenuTitle(wallpaperModel.shufflePlaybackEnabled)
        }
        if let item = menu.item(withTag: MenuTag.previousVideo) {
            item.title = localized("前の動画")
        }
        if let item = menu.item(withTag: MenuTag.nextVideo) {
            item.title = localized("次の動画")
        }
        if let item = menu.item(withTag: MenuTag.exportPackage) {
            item.title = localized("壁紙を共有")
        }
        if let item = menu.item(withTag: MenuTag.importPackage) {
            item.title = localized("壁紙を読み込む")
        }
        #if canImport(Sparkle)
            if let item = menu.item(withTag: MenuTag.updateMenu) {
                item.title = localized("アップデートを確認")
            }
        #endif
        if let item = menu.item(withTag: MenuTag.refreshPlayback) {
            item.title = localized("再生をリフレッシュ")
        }
        if let item = menu.item(withTag: MenuTag.quitApp) {
            item.title = localized("終了")
        }

        settingsWindowController?.window?.title = localized("Live Wallpaper 設定")
    }

    func audioMenuTitle(_ enabled: Bool) -> String {
        localized("音声を再生") + ": " + (enabled ? localized("ON") : localized("OFF"))
    }

    func playlistMenuTitle(_ enabled: Bool) -> String {
        localized("プレイリスト連続再生") + ": " + (enabled ? localized("ON") : localized("OFF"))
    }

    func shuffleMenuTitle(_ enabled: Bool) -> String {
        localized("シャッフル") + ": " + (enabled ? localized("ON") : localized("OFF"))
    }

    func pinCurrentVideoMenuTitle(_ enabled: Bool) -> String {
        localized("この動画で固定") + ": " + (enabled ? localized("ON") : localized("OFF"))
    }

    func audioMenuIcon(_ enabled: Bool) -> NSImage? {
        let symbolName: String = enabled ? "speaker.wave.2" : "speaker.slash"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "音声")
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = image?.withSymbolConfiguration(config)
        configured?.isTemplate = true
        return configured
    }

    func updateMenuIcon() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: localized("アップデート")
        )
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = image?.withSymbolConfiguration(config)
        configured?.isTemplate = true
        return configured
    }

    func wallpaperMenuIcon() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "photo.on.rectangle",
            accessibilityDescription: localized("壁紙")
        )
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = image?.withSymbolConfiguration(config)
        configured?.isTemplate = true
        return configured
    }

    func playlistMenuIcon() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "rectangle.stack",
            accessibilityDescription: localized("プレイリスト")
        )
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = image?.withSymbolConfiguration(config)
        configured?.isTemplate = true
        return configured
    }

    func pinCurrentVideoMenuIcon() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "pin.fill",
            accessibilityDescription: localized("この動画で固定")
        )
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = image?.withSymbolConfiguration(config)
        configured?.isTemplate = true
        return configured
    }

    func shuffleMenuIcon() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "shuffle",
            accessibilityDescription: localized("シャッフル")
        )
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = image?.withSymbolConfiguration(config)
        configured?.isTemplate = true
        return configured
    }

    func previousVideoMenuIcon() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "backward.fill",
            accessibilityDescription: localized("前の動画")
        )
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = image?.withSymbolConfiguration(config)
        configured?.isTemplate = true
        return configured
    }

    func nextVideoMenuIcon() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "forward.fill",
            accessibilityDescription: localized("次の動画")
        )
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = image?.withSymbolConfiguration(config)
        configured?.isTemplate = true
        return configured
    }

    func wallpaperFitMenuIcon() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "viewfinder",
            accessibilityDescription: localized("壁紙設定")
        )
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = image?.withSymbolConfiguration(config)
        configured?.isTemplate = true
        return configured
    }

    func refreshMenuIcon() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: localized("再生をリフレッシュ")
        )
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = image?.withSymbolConfiguration(config)
        configured?.isTemplate = true
        return configured
    }
}

import AVFoundation
import ScreenSaver

/// Plays the wallpaper the app is currently showing on this display, with the same
/// trim/loop (WallpaperLoopBuilder) and fit (WallpaperGeometry) as the desktop.
///
/// Built by scripts/build_screensaver.sh together with the shared sources it lists;
/// the app installs it into ~/Library/Screen Savers and keeps ScreenSaverConfig up
/// to date.
@objc(LiveWallpaperSaverView)
final class LiveWallpaperSaverView: ScreenSaverView {
    private let playerLayer = AVPlayerLayer()
    private let messageLayer = CATextLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var display: ScreenSaverConfig.Display?
    private var videoAspectRatio: Double?
    private var stopObserver: NSObjectProtocol?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
        messageLayer.alignmentMode = .center
        messageLayer.foregroundColor = NSColor(white: 1, alpha: 0.7).cgColor
        messageLayer.fontSize = isPreview ? 10 : 18
        messageLayer.isWrapped = true
        messageLayer.isHidden = true
        layer?.addSublayer(messageLayer)
        // Since Sonoma the host often never calls stopAnimation and keeps old
        // instances alive, which would leave video decoding in the background.
        stopObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screensaver.willstop"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopPlayback()
            }
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let stopObserver {
            DistributedNotificationCenter.default().removeObserver(stopObserver)
        }
    }

    override var hasConfigureSheet: Bool {
        false
    }

    override var configureSheet: NSWindow? {
        nil
    }

    override func startAnimation() {
        super.startAnimation()
        // Re-read every start: the user may have changed the wallpaper since the
        // host created this (possibly long-lived) instance.
        stopPlayback()
        guard let config = Self.loadConfig() else {
            showMessage(Self.localized(
                ja: "LiveWallpaper を起動して壁紙を選ぶと、ここに表示されます。",
                en: "Open LiveWallpaper and choose a wallpaper to show it here."
            ))
            return
        }
        guard let display = config.display(forDisplayID: displayID()),
              FileManager.default.fileExists(atPath: display.videoPath)
        else {
            showMessage(Self.localized(
                ja: "この画面に表示できる動画の壁紙がありません。",
                en: "There is no video wallpaper for this display."
            ))
            return
        }
        messageLayer.isHidden = true
        self.display = display
        videoAspectRatio = display.videoAspectRatio
        startPlayback(display)
        layoutPlayerLayer()
    }

    override func stopAnimation() {
        super.stopAnimation()
        stopPlayback()
    }

    override func layout() {
        super.layout()
        layoutPlayerLayer()
        messageLayer.frame = bounds.insetBy(dx: bounds.width * 0.1, dy: bounds.height * 0.45)
    }

    private func startPlayback(_ display: ScreenSaverConfig.Display) {
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .none
        let asset = AVURLAsset(url: URL(fileURLWithPath: display.videoPath))
        looper = WallpaperLoopBuilder.makeLooper(
            player: player,
            templateItem: AVPlayerItem(asset: asset),
            trimStart: display.trimStart,
            trimEnd: display.trimEnd,
            loopStart: display.loopStart,
            context: "screensaver"
        )
        playerLayer.player = player
        player.play()
        self.player = player

        Task { [weak self] in
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (size, transform) = try? await track.load(.naturalSize, .preferredTransform)
            else {
                return
            }
            let oriented = size.applying(transform)
            guard abs(oriented.height) > 0 else {
                return
            }
            await MainActor.run {
                self?.videoAspectRatio = Double(abs(oriented.width) / abs(oriented.height))
                self?.layoutPlayerLayer()
            }
        }
    }

    private func stopPlayback() {
        looper?.disableLooping()
        looper = nil
        player?.pause()
        player?.removeAllItems()
        player = nil
        playerLayer.player = nil
    }

    /// Same placement as WallpaperModel.applyPlayerPresentation.
    private func layoutPlayerLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let display else {
            playerLayer.frame = bounds
            return
        }
        let aspect = videoAspectRatio ?? Double(bounds.width / max(bounds.height, 1))
        let geometry = WallpaperGeometry.resolve(
            containerSize: bounds.size,
            videoAspectRatio: aspect,
            fitMode: display.fitMode,
            zoom: display.zoom,
            offsetX: display.offsetX,
            offsetY: display.offsetY
        )
        playerLayer.videoGravity = display.fitMode == .fit ? .resizeAspect : .resizeAspectFill
        let width = max(geometry.renderedSize.width, 1)
        let height = max(geometry.renderedSize.height, 1)
        playerLayer.frame = CGRect(
            x: (bounds.width - width) * 0.5 + geometry.translation.width,
            y: (bounds.height - height) * 0.5 + geometry.translation.height,
            width: width,
            height: height
        )
    }

    private func displayID() -> String? {
        let screen = window?.screen ?? NSScreen.main
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return nil
        }
        return String(number.uint32Value)
    }

    private func showMessage(_ text: String) {
        messageLayer.string = text
        messageLayer.contentsScale = window?.backingScaleFactor ?? 2
        messageLayer.isHidden = false
    }

    private static func loadConfig() -> ScreenSaverConfig? {
        guard let data = try? Data(contentsOf: ScreenSaverConfig.fileURL(home: realHomeDirectory())),
              let config = try? JSONDecoder().decode(ScreenSaverConfig.self, from: data),
              config.formatVersion <= ScreenSaverConfig.currentFormatVersion
        else {
            return nil
        }
        return config
    }

    /// NSHomeDirectory() is the sandbox container inside legacyScreenSaver.
    private static func realHomeDirectory() -> URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    private static func localized(ja: String, en: String) -> String {
        Locale.preferredLanguages.first?.hasPrefix("ja") == true ? ja : en
    }
}

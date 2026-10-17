import AppKit
import AVFoundation

final class PlayerView: NSView {
    /// Set `player` rather than `playerLayer.player`, which is left empty while a
    /// live scene covers the video.
    let playerLayer: AVPlayerLayer = .init()
    /// The player this screen shows. While a live scene covers the video, the
    /// layer is given no player: an AVPlayerLayer keeps decoding and compositing
    /// every frame even under an opaque layer (about as costly as showing it),
    /// while a player with no layer still advances the clock the scene follows.
    var player: AVPlayer? {
        didSet {
            updateVideoRendering()
        }
    }
    /// Holds the video and the switch-effect picture so the cursor parallax can move
    /// them as one without touching playerLayer's own fit/zoom frame.
    private let contentLayer: CALayer = .init()
    /// Shows the pre-switch content (the old player, or the still while paused)
    /// above the new content for the duration of a wallpaper switch effect.
    private let transitionLayer: AVPlayerLayer = .init()
    /// Black layer above both, used by the dip-to-black effect.
    private let blackoutLayer: CALayer = .init()
    private(set) var transitionGeneration: Int = 0
    private var blackoutCompletesAt: CFTimeInterval = 0

    private lazy var menuBarMaskView: NSVisualEffectView = {
        let view = NSVisualEffectView()
        view.material = .titlebar
        view.blendingMode = .withinWindow
        view.state = .active
        view.isHidden = true
        return view
    }()

    private let cursorOverlayView = CursorEffectsOverlayView()

    /// Sits right above the video and under the switch-effect layer, with the video's
    /// fit/zoom frame (syncSceneFrame). Created on first use.
    private var sceneLayer: SceneMetalLayer?
    /// While the baked video is out of date (an edit is still being baked), the
    /// player's time does not match the scene's loop.
    private var sceneUsesFreeClock = false
    private var sceneRunsInRealTime = false
    private var sceneClockOrigin: CFTimeInterval?
    /// The scene has finished a frame since it was shown, so dropping the video
    /// under it reveals nothing.
    private var sceneCoversVideo = false
    /// Set while a hidden scene stays up until the video layer has a frame again;
    /// removing it sooner shows the desktop for the ~30 ms that takes.
    private var sceneRemovalObservation: NSKeyValueObservation?

    private lazy var readabilityDimOverlayView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.isHidden = true
        return view
    }()

    var menuBarMaskHeight: CGFloat = 0 {
        didSet {
            guard menuBarMaskHeight != oldValue else {
                return
            }
            menuBarMaskView.isHidden = menuBarMaskHeight <= 0
            layoutMenuBarMask()
        }
    }

    var readabilityDimOpacity: CGFloat = 0 {
        didSet {
            guard readabilityDimOpacity != oldValue else {
                return
            }
            readabilityDimOverlayView.alphaValue = readabilityDimOpacity
            readabilityDimOverlayView.isHidden = readabilityDimOpacity <= 0
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    override func makeBackingLayer() -> CALayer {
        CALayer()
    }

    override func layout() {
        super.layout()
        layer?.frame = bounds
        // bounds/position rather than frame: frame is undefined once the parallax
        // transform is set.
        contentLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        contentLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        blackoutLayer.frame = bounds
        readabilityDimOverlayView.frame = bounds
        cursorOverlayView.frame = bounds
        layoutMenuBarMask()
    }

    private func setupLayers() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.needsDisplayOnBoundsChange = true
        if contentLayer.superlayer == nil {
            layer?.addSublayer(contentLayer)
            contentLayer.addSublayer(playerLayer)
        }
        transitionLayer.isHidden = true
        transitionLayer.backgroundColor = NSColor.clear.cgColor
        blackoutLayer.isHidden = true
        blackoutLayer.backgroundColor = NSColor.black.cgColor
        if transitionLayer.superlayer == nil {
            // Above the live video but below the dim overlay and menu bar mask
            // (subviews), so the effect does not change readability styling.
            contentLayer.insertSublayer(transitionLayer, above: playerLayer)
            layer?.insertSublayer(blackoutLayer, above: contentLayer)
        }
        // 減光オーバーレイはメニューバーマスクより上に載せる。マスク
        // (NSVisualEffectView, .withinWindow)は下のコンテンツをサンプルするため、
        // マスクを上にすると減光済みの黒を拾ってメニューバー帯だけ色味が変わる。
        // 上下逆にして、壁紙全体に均一な減光がかかるようにする。
        addSubview(menuBarMaskView, positioned: .above, relativeTo: nil)
        addSubview(readabilityDimOverlayView, positioned: .above, relativeTo: nil)
        addSubview(cursorOverlayView, positioned: .above, relativeTo: nil)
    }

    // MARK: - Scene

    var isShowingScene: Bool {
        sceneLayer?.renderer != nil
    }

    var sceneUsesCursor: Bool {
        sceneLayer?.renderer?.usesCursor ?? false
    }

    func setSceneScriptIssueHandler(_ handler: @escaping ([SceneScriptIssue]) -> Void) {
        sceneLayer?.scriptIssueHandler = handler
    }

    /// `freeClock` animates on wall time instead of the player's position, for while
    /// the baked video does not match the scene yet. Either way the animation only
    /// runs while the player plays, so every pause rule for videos applies.
    func showScene(
        _ document: SceneDocument,
        videoPath: String,
        freeClock: Bool,
        timeOfDay: SceneTimeOfDay,
        maximumFramesPerSecond: Float?
    ) throws {
        let layer = sceneLayer ?? {
            let layer = SceneMetalLayer()
            layer.hostView = self
            layer.clock = { [weak self] in
                self?.sceneClockReading() ?? SceneClockReading(time: 0, isRunning: false)
            }
            layer.frameDidComplete = { [weak self] in
                guard let self, self.sceneLayer?.renderer != nil, self.sceneRemovalObservation == nil,
                      !self.sceneCoversVideo
                else {
                    return
                }
                self.sceneCoversVideo = true
                self.updateVideoRendering()
            }
            contentLayer.insertSublayer(layer, above: playerLayer)
            sceneLayer = layer
            return layer
        }()
        sceneRemovalObservation = nil
        sceneUsesFreeClock = freeClock
        sceneRunsInRealTime = freeClock && document.requiresRealTimePlayback
        layer.maximumFramesPerSecond = maximumFramesPerSecond
        layer.timeOfDay = timeOfDay
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer.frame = sceneFrame(aspectRatio: document.aspectRatio)
        layer.isHidden = false
        CATransaction.commit()
        try layer.show(document, videoPath: videoPath)
    }

    private func sceneClockReading() -> SceneClockReading {
        guard let player else {
            return SceneClockReading(time: 0, isRunning: false)
        }
        let running = player.rate != 0
        if sceneUsesFreeClock {
            // Seconds since the scene was first shown: the time since boot is too
            // large for the Float the shaders read it as.
            let origin = sceneClockOrigin ?? CACurrentMediaTime()
            sceneClockOrigin = origin
            return SceneClockReading(
                time: CACurrentMediaTime() - origin, isRunning: running, isRealTime: sceneRunsInRealTime
            )
        }
        let seconds = player.currentTime().seconds
        return SceneClockReading(time: seconds.isFinite ? seconds : 0, isRunning: running)
    }

    /// playerLayer's frame only has the video's shape once its aspect ratio is known,
    /// and AVPlayerLayer hides any mismatch with its gravity; apply the same gravity
    /// so the scene is never stretched.
    private func sceneFrame(aspectRatio: Double) -> CGRect {
        let frame = playerLayer.frame
        guard frame.width > 0, frame.height > 0, aspectRatio > 0 else {
            return frame
        }
        let fill = playerLayer.videoGravity == .resizeAspectFill
        let frameAspect = frame.width / frame.height
        let widthLimited = (CGFloat(aspectRatio) > frameAspect) != fill
        let size = widthLimited
            ? CGSize(width: frame.width, height: frame.width / CGFloat(aspectRatio))
            : CGSize(width: frame.height * CGFloat(aspectRatio), height: frame.height)
        return CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Call after changing playerLayer.frame.
    func syncSceneFrame() {
        guard let sceneLayer, let document = sceneLayer.renderer?.document else {
            return
        }
        let frame = sceneFrame(aspectRatio: document.aspectRatio)
        guard sceneLayer.frame != frame else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sceneLayer.frame = frame
        CATransaction.commit()
    }

    func hideScene() {
        guard let sceneLayer, sceneLayer.renderer != nil, sceneRemovalObservation == nil else {
            return
        }
        sceneCoversVideo = false
        updateVideoRendering()
        guard playerLayer.player != nil, !playerLayer.isReadyForDisplay else {
            removeScene()
            return
        }
        let observation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, change in
            guard change.newValue == true else {
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishSceneRemoval()
                }
            }
        }
        sceneRemovalObservation = observation
        // isReadyForDisplay may never turn true (the item failed or was replaced);
        // the desktop showing through briefly beats a scene that never leaves.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.sceneRemovalObservation === observation else {
                    return
                }
                self.finishSceneRemoval()
            }
        }
    }

    private func finishSceneRemoval() {
        guard sceneRemovalObservation != nil else {
            return
        }
        sceneRemovalObservation = nil
        removeScene()
    }

    private func removeScene() {
        guard let sceneLayer else {
            return
        }
        sceneLayer.clear()
        sceneLayer.isHidden = true
    }

    private var isTransitioning: Bool {
        !transitionLayer.isHidden || !blackoutLayer.isHidden
    }

    /// A switch effect keeps the video attached: the code finishing it waits for
    /// playerLayer to show the new content.
    private func updateVideoRendering() {
        let shown = sceneCoversVideo && !isTransitioning ? nil : player
        guard playerLayer.player !== shown else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.player = shown
        CATransaction.commit()
    }

    /// `point` is in this view's coordinates.
    func setSceneCursor(_ point: CGPoint?, parallax: CGPoint) {
        guard let sceneLayer, sceneLayer.renderer != nil else {
            return
        }
        let local = point.map { sceneLayer.convert($0, from: layer) }
        sceneLayer.setCursor(local, parallax: parallax)
    }

    // MARK: - Cursor effects

    /// `offset` and `scale` come from CursorEffectGeometry; identity turns it off.
    func setParallax(offset: CGSize, scale: CGFloat) {
        let target = CATransform3DMakeAffineTransform(
            CGAffineTransform(translationX: offset.width, y: offset.height).scaledBy(x: scale, y: scale)
        )
        guard !CATransform3DEqualToTransform(contentLayer.transform, target) else {
            return
        }
        // Start from what is on screen, so a new cursor position mid-animation
        // bends the motion instead of jumping back to the previous target.
        let current = contentLayer.presentation()?.transform ?? contentLayer.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.transform = target
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = current
        animation.toValue = target
        animation.duration = 0.3
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        contentLayer.add(animation, forKey: "parallax")
    }

    func setSpotlight(radius: CGFloat?, opacity: CGFloat, center: CGPoint?) {
        cursorOverlayView.setSpotlight(radius: radius, opacity: opacity, center: center)
    }

    func configureTrail(_ appearance: CursorTrailAppearance) {
        cursorOverlayView.configureTrail(appearance)
    }

    func setTrail(position: CGPoint?, emitting: Bool) {
        cursorOverlayView.setTrail(position: position, emitting: emitting)
    }

    func showClick(at point: CGPoint, style: CursorClickStyle, color: CursorEffectColor, customColor: RGBAColor) {
        cursorOverlayView.showClick(at: point, style: style, color: color, customColor: customColor)
    }

    /// Before macOS 26 there is no per-layer control and AVPlayerLayer shows HDR video
    /// as HDR regardless. On 26+ the wallpaper uses the constrained range Apple meant
    /// for content that shares the screen with other windows, rather than `.high`.
    func setHighDynamicRange(_ enabled: Bool) {
        guard #available(macOS 26, *) else {
            return
        }
        let range: CALayer.DynamicRange = enabled ? .constrainedHigh : .standard
        playerLayer.preferredDynamicRange = range
        transitionLayer.preferredDynamicRange = range
    }

    /// Pins what is on screen now as the "before" image of a wallpaper switch.
    /// The frame and gravity are copied from playerLayer so that a different fit
    /// on the new wallpaper does not make the old picture jump mid-fade. The
    /// returned generation must be passed back, so a newer switch is never torn
    /// down by the completion of an older fade.
    func beginTransition(from player: AVPlayer?, still: Any?) -> Int {
        transitionGeneration += 1
        blackoutCompletesAt = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        transitionLayer.removeAllAnimations()
        blackoutLayer.removeAllAnimations()
        transitionLayer.frame = playerLayer.frame
        transitionLayer.videoGravity = playerLayer.videoGravity
        transitionLayer.backgroundColor = playerLayer.backgroundColor
        transitionLayer.player = player
        transitionLayer.contents = player == nil ? still : nil
        transitionLayer.opacity = 1
        transitionLayer.isHidden = false
        blackoutLayer.frame = bounds
        blackoutLayer.opacity = 0
        blackoutLayer.isHidden = true
        CATransaction.commit()
        updateVideoRendering()
        return transitionGeneration
    }

    /// Starts the part of the effect that does not depend on the new content.
    /// Dipping to black begins right away so its first half overlaps the time the
    /// new video needs before its first frame.
    func startTransition(generation: Int, style: WallpaperTransitionStyle, duration: TimeInterval) {
        guard generation == transitionGeneration, style == .dipToBlack else {
            return
        }
        let half = duration / 2
        blackoutCompletesAt = CACurrentMediaTime() + half
        animateOpacity(of: blackoutLayer, from: 0, to: 1, duration: half, completion: nil)
    }

    func finishTransition(
        generation: Int,
        style: WallpaperTransitionStyle,
        duration: TimeInterval,
        completion: @escaping () -> Void
    ) {
        guard generation == transitionGeneration, !transitionLayer.isHidden else {
            completion()
            return
        }
        let finish: () -> Void = { [weak self] in
            if let self, generation == self.transitionGeneration {
                self.clearTransitionLayer()
            }
            completion()
        }
        switch style {
        case .crossfade:
            animateOpacity(of: transitionLayer, from: 1, to: 0, duration: duration, completion: finish)
        case .dipToBlack:
            let wait = max(blackoutCompletesAt - CACurrentMediaTime(), 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self, generation == self.transitionGeneration else {
                    completion()
                    return
                }
                // Fully black now: drop the old picture and reveal the new one.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.transitionLayer.isHidden = true
                self.transitionLayer.player = nil
                CATransaction.commit()
                self.animateOpacity(
                    of: self.blackoutLayer, from: 1, to: 0, duration: duration / 2, completion: finish
                )
            }
        }
    }

    func cancelTransition() {
        transitionGeneration += 1
        clearTransitionLayer()
    }

    private func animateOpacity(
        of layer: CALayer,
        from: Float,
        to: Float,
        duration: TimeInterval,
        completion: (() -> Void)?
    ) {
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.isHidden = false
        layer.opacity = to
        layer.add(fade, forKey: "wallpaperTransition")
        CATransaction.commit()
    }

    private func clearTransitionLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        transitionLayer.removeAllAnimations()
        transitionLayer.isHidden = true
        transitionLayer.player = nil
        transitionLayer.contents = nil
        blackoutLayer.removeAllAnimations()
        blackoutLayer.isHidden = true
        blackoutLayer.opacity = 0
        CATransaction.commit()
        updateVideoRendering()
    }

    private func layoutMenuBarMask() {
        menuBarMaskView.frame = CGRect(
            x: 0,
            y: bounds.height - menuBarMaskHeight,
            width: bounds.width,
            height: menuBarMaskHeight
        )
    }
}

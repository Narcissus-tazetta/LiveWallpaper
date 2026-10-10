import AppKit
import AVFoundation

final class PlayerView: NSView {
    let playerLayer: AVPlayerLayer = .init()
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
        blackoutLayer.frame = bounds
        readabilityDimOverlayView.frame = bounds
        layoutMenuBarMask()
    }

    private func setupLayers() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.needsDisplayOnBoundsChange = true
        if playerLayer.superlayer == nil {
            layer?.addSublayer(playerLayer)
        }
        transitionLayer.isHidden = true
        transitionLayer.backgroundColor = NSColor.clear.cgColor
        blackoutLayer.isHidden = true
        blackoutLayer.backgroundColor = NSColor.black.cgColor
        if transitionLayer.superlayer == nil {
            // Above the live video but below the dim overlay and menu bar mask
            // (subviews), so the effect does not change readability styling.
            layer?.insertSublayer(transitionLayer, above: playerLayer)
            layer?.insertSublayer(blackoutLayer, above: transitionLayer)
        }
        // 減光オーバーレイはメニューバーマスクより上に載せる。マスク
        // (NSVisualEffectView, .withinWindow)は下のコンテンツをサンプルするため、
        // マスクを上にすると減光済みの黒を拾ってメニューバー帯だけ色味が変わる。
        // 上下逆にして、壁紙全体に均一な減光がかかるようにする。
        addSubview(menuBarMaskView, positioned: .above, relativeTo: nil)
        addSubview(readabilityDimOverlayView, positioned: .above, relativeTo: nil)
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

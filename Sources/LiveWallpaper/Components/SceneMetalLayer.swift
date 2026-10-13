import AppKit
import QuartzCore

/// Where an animated scene takes its time from, and whether that time is moving.
struct SceneClockReading {
    var time: Double
    var isRunning: Bool
}

/// Shows a scene live. Draws only when something changes: a tick runs while the
/// scene animates and its clock is running, or while the parallax is still easing;
/// otherwise nothing is drawn until the next cursor move or edit.
@MainActor
final class SceneMetalLayer: CAMetalLayer {
    private(set) var renderer: SceneRenderer?
    private(set) var videoPath: String?
    private var target = SceneFrameInput.rest
    private var current = SceneFrameInput.rest
    private var ticker: AnyObject?
    private var tickRateApplied: Float = 0
    private var lastInteraction: CFTimeInterval = 0
    private var poller: Timer?
    private var lastStep: CFTimeInterval = 0

    /// Provides the animation time. nil leaves the scene at the loop start.
    var clock: (() -> SceneClockReading)?
    /// The view whose display drives the ticks.
    weak var hostView: NSView?
    var maximumFramesPerSecond: Float? {
        didSet {
            if maximumFramesPerSecond != oldValue {
                stopTicking()
                updateTicking()
            }
        }
    }

    /// Seconds for the parallax to cover ~63% of the way to the cursor.
    private static let parallaxTimeConstant: Double = 0.12

    override init() {
        super.init()
        commonInit()
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        pixelFormat = .bgra8Unorm
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        isOpaque = true
        framebufferOnly = true
        presentsWithTransaction = true
        // Each screen-sized drawable is tens of MB; frames wait to be scheduled
        // before presenting, so a third one is never needed.
        maximumDrawableCount = 2
        needsDisplayOnBoundsChange = true
        actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "hidden": NSNull()]
    }

    func show(_ document: SceneDocument, videoPath: String) throws {
        if let renderer, self.videoPath == videoPath {
            if renderer.document != document {
                try renderer.update(document: document)
            }
        } else {
            let renderer = try SceneRenderer(document: document, videoPath: videoPath)
            renderer.effectResolutionScale = 0.5
            self.renderer = renderer
            self.videoPath = videoPath
            device = renderer.device
            current = .rest
            target = .rest
        }
        readClock()
        redraw()
        updateTicking()
    }

    func clear() {
        stopTicking()
        stopPolling()
        renderer = nil
        videoPath = nil
    }

    /// Call when the clock may have started or stopped.
    func clockDidChange() {
        readClock()
        redraw()
        updateTicking()
    }

    func setPaintOverride(_ override: ScenePaintOverride?) {
        do {
            try renderer?.setPaintOverride(override)
        } catch {
            AppLog.windowRefresh.error("scene paint preview failed: \(error.localizedDescription, privacy: .public)")
        }
        redraw()
    }

    /// `cursor` is in this layer's coordinates (origin bottom-left), nil when the
    /// cursor is not on this screen or masks may not react. `parallax` is -1...1 from
    /// the screen centre, zero when parallax may not move.
    func setCursor(_ cursor: CGPoint?, parallax: CGPoint) {
        let uv = cursor.flatMap(canvasUV(of:))
        let newTarget = SceneFrameInput(
            parallax: SIMD2(Float(parallax.x), Float(-parallax.y)), cursor: uv, time: target.time
        )
        guard newTarget.parallax != target.parallax || newTarget.cursor != target.cursor else {
            return
        }
        target.parallax = newTarget.parallax
        target.cursor = uv
        current.cursor = uv
        lastInteraction = CACurrentMediaTime()
        applyTickRate()
        if current.parallax == target.parallax {
            redraw()
        } else {
            lastStep = CACurrentMediaTime()
            updateTicking()
        }
    }

    /// A point in this layer's coordinates (origin bottom-left) → canvas UV.
    func canvasUV(of point: CGPoint) -> SIMD2<Float>? {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else {
            return nil
        }
        return SIMD2(Float(point.x / size.width), Float(1 - point.y / size.height))
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        redraw()
    }

    override func display() {
        redraw()
    }

    func redraw() {
        guard let renderer, bounds.width > 0, bounds.height > 0 else {
            return
        }
        let scale = contentsScale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        if drawableSize != size {
            drawableSize = size
        }
        guard let drawable = nextDrawable(),
              let commandBuffer = renderer.commandQueue.makeCommandBuffer()
        else {
            return
        }
        do {
            try renderer.encode(into: drawable.texture, commandBuffer: commandBuffer, input: current)
        } catch {
            AppLog.windowRefresh.error("scene render failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Frames presented from display-link ticks outside a Core Animation
        // transaction never showed in captures of the window; redraws made while
        // handling an event did. Presenting with the transaction shows both.
        commandBuffer.commit()
        commandBuffer.waitUntilScheduled()
        drawable.present()
    }

    // MARK: - Ticking

    private var isAnimating: Bool {
        guard let renderer, renderer.document.isAnimated, let clock else {
            return false
        }
        return clock().isRunning
    }

    private var isEasing: Bool {
        current.parallax != target.parallax
    }

    private func readClock() {
        guard let renderer, renderer.document.isAnimated, let reading = clock?() else {
            current.time = 0
            return
        }
        current.time = reading.time
    }

    private func updateTicking() {
        if isAnimating || isEasing {
            stopPolling()
            startTicking()
        } else {
            stopTicking()
            updatePolling()
        }
    }

    /// An animated scene whose clock stopped checks twice a second for it to start
    /// again: players get paused, swapped and rebuilt in many places, and none of
    /// that is observable reliably from here.
    private func updatePolling() {
        guard let renderer, renderer.document.isAnimated, clock != nil else {
            stopPolling()
            return
        }
        guard poller == nil else {
            return
        }
        let timer = Timer(timeInterval: 0.5, target: self, selector: #selector(poll), userInfo: nil, repeats: true)
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        poller = timer
    }

    private func stopPolling() {
        poller?.invalidate()
        poller = nil
    }

    @objc private func poll() {
        if isAnimating {
            updateTicking()
        }
    }

    private func startTicking() {
        guard ticker == nil else {
            return
        }
        lastStep = CACurrentMediaTime()
        tickRateApplied = tickRateCap
        // Target/selector: the display link or timer retains the layer only until
        // ticking stops and invalidates it.
        if #available(macOS 14, *), let hostView {
            let link = hostView.displayLink(target: self, selector: #selector(tick))
            let cap = tickRateApplied
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, cap), maximum: cap, preferred: cap)
            link.add(to: .main, forMode: .common)
            ticker = link
        } else {
            let fps = Double(tickRateApplied)
            let timer = Timer(
                timeInterval: 1 / max(fps, 30), target: self, selector: #selector(tick), userInfo: nil, repeats: true
            )
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
    }

    /// Motion on its own runs at 30 fps (each frame costs main-thread time, and a
    /// wallpaper's slow motion does not need more); while the cursor moves, the
    /// display's full rate keeps parallax and reveals smooth.
    private var tickRateCap: Float {
        let display = Float(NSScreen.main?.maximumFramesPerSecond ?? 60)
        var cap = maximumFramesPerSecond ?? display
        if !isInteracting {
            cap = min(cap, Self.idleAnimationFramesPerSecond)
        }
        return max(min(cap, display), 1)
    }

    private static let idleAnimationFramesPerSecond: Float = 30
    /// How long after the last cursor move the full rate is kept.
    private static let interactionHold: CFTimeInterval = 0.6

    private var isInteracting: Bool {
        isEasing || CACurrentMediaTime() - lastInteraction < Self.interactionHold
    }

    /// Restarts the tick when the wanted rate changed.
    private func applyTickRate() {
        guard ticker != nil, tickRateApplied != tickRateCap else {
            return
        }
        stopTicking()
        startTicking()
    }

    private func stopTicking() {
        if #available(macOS 14, *), let link = ticker as? CADisplayLink {
            link.invalidate()
        }
        (ticker as? Timer)?.invalidate()
        ticker = nil
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let dt = now - lastStep
        lastStep = now
        if isEasing {
            let k = Float(1 - exp(-dt / Self.parallaxTimeConstant))
            let delta = target.parallax - current.parallax
            if abs(delta.x) < 0.001, abs(delta.y) < 0.001 {
                current.parallax = target.parallax
            } else {
                current.parallax += delta * k
            }
        }
        readClock()
        redraw()
        if !isAnimating, !isEasing {
            updateTicking()
        } else {
            applyTickRate()
        }
    }
}

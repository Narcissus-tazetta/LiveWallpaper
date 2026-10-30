import AppKit
import QuartzCore

/// Where an animated scene takes its time from, and whether that time is moving.
struct SceneClockReading {
    var time: Double
    var isRunning: Bool
    /// `time` counts real seconds since the scene was shown, for real-time effects.
    var isRealTime = false
}

/// Shows a scene live. Draws only when something changes: a tick runs while the
/// scene animates and its clock is running, or while the parallax is still easing;
/// otherwise nothing is drawn until the next cursor move or edit.
@MainActor
final class SceneMetalLayer: CAMetalLayer {
    @MainActor private final class TickTarget: NSObject {
        weak var layer: SceneMetalLayer?

        init(layer: SceneMetalLayer) { self.layer = layer }

        @objc func tick(_ sender: AnyObject) {
            if let layer { layer.tick() } else { invalidate(sender) }
        }

        @objc func poll(_ sender: Timer) {
            if let layer { layer.poll() } else { sender.invalidate() }
        }

        @objc func soundReactionDidChange(_: Notification) {
            layer?.updateMediaSubscription()
        }

        private func invalidate(_ sender: AnyObject) {
            if #available(macOS 14, *), let link = sender as? CADisplayLink { link.invalidate() }
            (sender as? Timer)?.invalidate()
        }
    }

    // RunLoop and display links retain their targets independently of the view.
    private lazy var tickTarget = TickTarget(layer: self)
    private(set) var renderer: SceneRenderer?
    private(set) var videoPath: String?
    private var target = SceneFrameInput.rest
    private var current = SceneFrameInput.rest
    private var ticker: AnyObject?
    private var tickRateApplied: Float = 0
    private var lastInteraction: CFTimeInterval = 0
    private var poller: Timer?
    private var lastStep: CFTimeInterval = 0
    /// A frame whose GPU work has not finished yet. Asking for another drawable then
    /// blocks the main thread in nextDrawable (up to a second while a bake keeps the
    /// GPU busy), so the redraw waits for it instead.
    private var isFrameInFlight = false
    private var needsRedrawAfterFrame = false
    private var scriptWorker = SceneScriptWorker()
    private var isEvaluatingScript = false
    private var needsScriptEvaluation = false
    private var scriptGeneration = UUID()
    private var frozenScriptInput: SceneFrameInput?
    private var stoppedScriptIDs: Set<UUID> = []
    /// Waiting for the next script run, which sees each one once.
    private var pendingPointerPresses: [ScenePointerPress] = []
    /// What is playing, while a script reads it.
    private var media: SceneMediaState? {
        didSet {
            guard media != oldValue else { return }
            current.media = media
            target.media = media
            redraw()
        }
    }
    private let mediaSubscriptionID = UUID()
    private var isSubscribedToMedia = false
    private var isSubscribedToSpectrum = false
    private(set) var isSuspended = false
    private struct Artwork {
        var source: String
        var id: String
        var palette: SceneMediaPalette?
        var data: Data?
    }
    private var artwork: Artwork?
    private var loadingVideos: Set<String> = []
    /// The screen whose per-screen storage area the scene's scripts use. nil (the
    /// editor preview, a window on no screen) gives them the global area under both names.
    var storageScreen: String? {
        didSet { if storageScreen != oldValue { storage = nil } }
    }
    private var storage: SceneScriptStorage.Session?
    var scriptIssueHandler: (([SceneScriptIssue]) -> Void)?
    var soundHandler: (([UUID: SceneScriptedSound]) -> Void)?
    var scriptLogHandler: (([UUID: String]) -> Void)?

    var userProperties: [String: WebPropertyValue]? {
        didSet {
            guard userProperties != oldValue else { return }
            current.userProperties = userProperties
            target.userProperties = userProperties
            redraw()
        }
    }

    static func loadUserProperties(forVideoPath videoPath: String) -> [String: WebPropertyValue]? {
        guard let settings = try? LocalWebSettings.loadScene(videoPath: videoPath), !settings.values.isEmpty else { return nil }
        return settings.values
    }

    /// Provides the animation time. nil leaves the scene at the loop start.
    var clock: (() -> SceneClockReading)?
    /// The part of the canvas shown (origin and size in canvas UV); the editor zooms.
    var viewport = SIMD4<Float>(0, 0, 1, 1) {
        didSet {
            if viewport != oldValue {
                current.viewport = viewport
                target.viewport = viewport
                redraw()
            }
        }
    }
    /// The part of the day the scene's links see.
    var timeOfDay: SceneTimeOfDay = .day {
        didSet {
            if timeOfDay != oldValue {
                renderer?.timeOfDay = timeOfDay
                redraw()
            }
        }
    }
    /// The editor's stand-in cursor, -1...1 per axis (+y down); while set, the real
    /// pointer is ignored. nil follows setCursor.
    var simulatedCursor: SIMD2<Float>? {
        didSet {
            guard simulatedCursor != oldValue else {
                return
            }
            if let simulatedCursor {
                applyCursor(uv: (simulatedCursor + 1) / 2, parallax: simulatedCursor)
            } else {
                applyCursor(uv: nil, parallax: .zero)
            }
        }
    }
    /// The view whose display drives the ticks.
    weak var hostView: NSView?
    /// Called after each frame is encoded, for overlays that follow the animation.
    var didDraw: (() -> Void)?
    /// Called on the main thread once the GPU has finished a frame.
    var frameDidComplete: (() -> Void)?
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
        // Posted on the main thread by SceneSoundReaction.setEnabled.
        NotificationCenter.default.addObserver(
            tickTarget, selector: #selector(TickTarget.soundReactionDidChange(_:)), name: SceneSoundReaction.didChange, object: nil
        )
    }

    func show(_ document: SceneDocument, videoPath: String, userProperties: [String: WebPropertyValue]? = nil) throws {
        let changedVideo = self.videoPath != videoPath
        if changedVideo {
            scriptWorker = SceneScriptWorker()
            frozenScriptInput = nil
            storage = nil
            self.userProperties = nil
        }
        if changedVideo || renderer?.document != document {
            scriptGeneration = UUID()
            stoppedScriptIDs = []
        }
        if let renderer, !changedVideo {
            if renderer.document != document {
                try renderer.update(document: document)
            }
        } else {
            let renderer = try SceneRenderer(document: document, videoPath: videoPath)
            renderer.decodesVideoAhead = true
            renderer.timeOfDay = timeOfDay
            self.renderer = renderer
            self.videoPath = videoPath
            device = renderer.device
            current = .rest
            target = .rest
            current.viewport = viewport
            target.viewport = viewport
        }
        current.media = media
        target.media = media
        self.userProperties = userProperties ?? Self.loadUserProperties(forVideoPath: videoPath)
        current.userProperties = self.userProperties
        target.userProperties = self.userProperties
        updateMediaSubscription()
        loadVideos()
        readClock()
        // SwiftUI may still be attaching or resizing the backing layer here.
        // Draw during the ensuing CA display transaction, after its surface settles.
        setNeedsDisplay()
        updateTicking()
    }

    func clear() {
        suspend()
        isSuspended = false
        scriptWorker = SceneScriptWorker()
        frozenScriptInput = nil
        scriptGeneration = UUID()
        scriptIssueHandler?([])
        renderer = nil
        videoPath = nil
        userProperties = nil
        target = .rest
        current = .rest
        updateMediaSubscription()
    }

    /// Until its frames load, a video layer shows its first frame (the layer's image).
    private func loadVideos() {
        guard let renderer else { return }
        let device = renderer.device
        for video in renderer.videosToLoad where !loadingVideos.contains(video.file) {
            loadingVideos.insert(video.file)
            Task { [weak self, weak renderer] in
                do {
                    let frames = try await SceneVideoFrames.load(url: video.url, device: device)
                    // Another scene may have the same file name; only its own renderer takes it.
                    if let self, let renderer, self.renderer === renderer {
                        renderer.install(frames, videoFile: video.file)
                        self.redraw()
                    }
                } catch {
                    AppLog.windowRefresh.error("scene video failed: \(error.localizedDescription, privacy: .public)")
                }
                self?.loadingVideos.remove(video.file)
                // A scene shown meanwhile may need a file of the same name.
                if self?.renderer !== renderer { self?.loadVideos() }
            }
        }
    }

    fileprivate func updateMediaSubscription() {
        let wantsMedia = renderer?.document.scripts.contains { $0.canRun && $0.usesMedia } == true
            || renderer?.document.layers.contains { $0.isVisible && $0.usesMediaArtwork } == true
        let wantsSpectrum = renderer?.document.usesAudio == true
            && videoPath.map { SceneSoundReaction.isEnabled(videoPath: $0) } == true
        guard wantsMedia != isSubscribedToMedia || wantsSpectrum != isSubscribedToSpectrum else { return }
        isSubscribedToMedia = wantsMedia
        isSubscribedToSpectrum = wantsSpectrum
        if !wantsMedia { media = nil }
        if !wantsSpectrum { setAudio(nil) }
        MainActor.assumeIsolated {
            LocalWebIntegration.shared.update(id: mediaSubscriptionID, subscription: wantsMedia || wantsSpectrum ? .init(
                sceneSpectrum: wantsSpectrum, media: wantsMedia,
                receiveSceneSpectrum: { [weak self] values in self?.receiveSpectrum(values) },
                receiveMedia: { [weak self] value, enabled in self?.receiveMedia(value, isAvailable: enabled) }
            ) : nil)
        }
    }

    /// 64 bands per channel, left first, as SceneAudioAnalyzer makes them.
    private func receiveSpectrum(_ values: [Float]) {
        guard isSubscribedToSpectrum, values.count == 2 * SceneAudioSpectrum.bandCount else { return }
        let count = SceneAudioSpectrum.bandCount
        setAudio(SceneAudioSpectrum(left: Array(values[..<count]), right: Array(values[count...])))
    }

    /// The next tick draws it: a scene with sound effects animates while its clock runs,
    /// and a paused scene should not move with the sound.
    private func setAudio(_ audio: SceneAudioSpectrum?) {
        current.audio = audio
        target.audio = audio
    }

    private func receiveMedia(_ value: WebNowPlaying, isAvailable: Bool) {
        guard isSubscribedToMedia else { return }
        guard isAvailable else {
            media = SceneMediaState(isAvailable: false)
            return
        }
        if artwork?.source != value.artwork {
            var decoded: SceneMediaPalette?
            var imageData: Data?
            if let comma = value.artwork.firstIndex(of: ","), value.artwork.hasPrefix("data:image/"),
               let data = Data(base64Encoded: String(value.artwork[value.artwork.index(after: comma)...])) {
                imageData = data
                do { decoded = try SceneMediaPalette(imageData: data) } catch {
                    AppLog.windowRefresh.error("media artwork colours failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            artwork = Artwork(source: value.artwork, id: value.artwork.isEmpty ? "" : "\(value.artwork.utf8.count):\(value.artwork.hashValue)",
                              palette: decoded, data: imageData)
        }
        media = SceneMediaState(
            isAvailable: true, playback: SceneMediaState.Playback(rawValue: value.state) ?? .stopped,
            title: value.title, artist: value.artist, album: value.album, position: value.position,
            duration: value.duration,
            artworkID: artwork?.id ?? "", palette: artwork?.palette, artworkData: artwork?.data
        )
    }

    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        scriptGeneration = UUID()
        needsScriptEvaluation = false
        stopTicking()
        stopPolling()
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        clockDidChange()
    }

    /// Call when the clock may have started or stopped.
    func clockDidChange() {
        readClock()
        setNeedsDisplay()
        updateTicking()
    }

    func freezeScriptsForEditing() {
        guard renderer?.document.scripts.contains(where: \.canRun) == true else { return }
        frozenScriptInput = renderer?.lastDrawnInput ?? current
        scriptGeneration = UUID()
        updateTicking()
    }

    func unfreezeScripts() {
        guard frozenScriptInput != nil else { return }
        frozenScriptInput = nil
        scriptGeneration = UUID()
        readClock()
        updateTicking()
        redraw()
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
        guard simulatedCursor == nil else {
            return
        }
        applyCursor(uv: cursor.flatMap(canvasUV(of:)), parallax: SIMD2(Float(parallax.x), Float(-parallax.y)))
    }

    /// A press or release of the primary button on the desktop, at `point` in this
    /// layer's coordinates (origin bottom-left).
    func addPointerPress(at point: CGPoint, isDown: Bool) {
        guard simulatedCursor == nil, let position = canvasUV(of: point),
              renderer?.document.scripts.contains(where: { $0.canRun && $0.usesCursor }) == true else { return }
        // A script run that never comes (a stopped script) must not grow this forever.
        pendingPointerPresses = Array((pendingPointerPresses + [.init(isDown: isDown, position: position)]).suffix(32))
        redraw()
    }

    /// `parallax` is -1...1 with +y down.
    private func applyCursor(uv: SIMD2<Float>?, parallax: SIMD2<Float>) {
        guard parallax != target.parallax || uv != target.cursor else {
            return
        }
        target.parallax = parallax
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
        let viewUV = SIMD2(Float(point.x / size.width), Float(1 - point.y / size.height))
        return SIMD2(viewport.x, viewport.y) + viewUV * SIMD2(viewport.z, viewport.w)
    }

    /// Canvas UV → a point in this layer's coordinates (origin bottom-left).
    func point(ofCanvasUV uv: SIMD2<Float>) -> CGPoint {
        let viewUV = (uv - SIMD2(viewport.x, viewport.y)) / SIMD2(viewport.z, viewport.w)
        return CGPoint(x: CGFloat(viewUV.x) * bounds.width, y: CGFloat(1 - viewUV.y) * bounds.height)
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        redraw()
    }

    override func display() {
        redraw()
    }

    func redraw() {
        guard !isSuspended, let renderer else { return }
        if renderer.document.scripts.contains(where: \.canRun) {
            needsScriptEvaluation = true
            guard !isEvaluatingScript else { return }
            needsScriptEvaluation = false
            isEvaluatingScript = true
            let generation = scriptGeneration
            let document = renderer.document
            var input = frozenScriptInput ?? current
            if frozenScriptInput == nil {
                input.pointerPresses = pendingPointerPresses
                pendingPointerPresses = []
            }
            if drawableSize.width > 0, drawableSize.height > 0 {
                input.screenSize = SIMD2(Int(drawableSize.width), Int(drawableSize.height))
            }
            let requestedTimeOfDay = timeOfDay
            let storage = storage ?? SceneScriptStorage.shared.session(path: videoPath!, screen: storageScreen)
            self.storage = storage
            scriptWorker.evaluate(document, input: input, timeOfDay: requestedTimeOfDay, storage: storage) { [weak self] result in
                guard let self else { return }
                self.isEvaluatingScript = false
                if self.scriptGeneration == generation, self.renderer?.document == document,
                   self.timeOfDay == requestedTimeOfDay {
                    switch result {
                    case let .success(frame):
                        self.scriptIssueHandler?(frame.issues)
                        self.scriptLogHandler?(frame.logs)
                        if !frame.sounds.isEmpty { self.soundHandler?(frame.sounds) }
                        // A script paused for running out of time keeps the clock going, so it can resume.
                        self.stoppedScriptIDs = Set(frame.issues.filter { !$0.isTemporary }.map(\.scriptID))
                        self.draw(input: frame.input, frame: frame)
                        self.updateTicking()
                    case let .failure(error):
                        AppLog.windowRefresh.error("script frame failed: \(error.localizedDescription, privacy: .public)")
                        self.scriptIssueHandler?([SceneScriptIssue(scriptID: document.scripts.first!.id,
                                                                  name: "JavaScript", message: error.localizedDescription)])
                    }
                }
                if self.needsScriptEvaluation { self.redraw() }
            }
        } else {
            draw(input: current, frame: nil)
        }
    }

    private func draw(input: SceneFrameInput, frame: SceneEvaluatedFrame?) {
        guard let renderer, bounds.width > 0, bounds.height > 0 else {
            return
        }
        guard !isFrameInFlight else {
            if let frame { renderer.holdParticleControls(from: frame) }
            needsRedrawAfterFrame = true
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
            if let frame { renderer.holdParticleControls(from: frame) }
            return
        }
        do {
            try renderer.encode(into: drawable.texture, commandBuffer: commandBuffer, input: input, frame: frame)
        } catch {
            AppLog.windowRefresh.error("scene render failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        isFrameInFlight = true
        let finish: @MainActor () -> Void = { [weak self] in
            self?.frameDidFinish()
        }
        commandBuffer.addCompletedHandler { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    finish()
                }
            }
        }
        // Frames presented from display-link ticks outside a Core Animation
        // transaction never showed in captures of the window; redraws made while
        // handling an event did. Presenting with the transaction shows both.
        commandBuffer.commit()
        commandBuffer.waitUntilScheduled()
        drawable.present()
        didDraw?()
    }

    private func frameDidFinish() {
        isFrameInFlight = false
        frameDidComplete?()
        if needsRedrawAfterFrame {
            needsRedrawAfterFrame = false
            setNeedsDisplay()
        }
    }

    // MARK: - Ticking

    private var isAnimating: Bool {
        guard frozenScriptInput == nil else { return false }
        guard let renderer, let clock else {
            return false
        }
        let animated = renderer.document.layers.contains(where: \.isAnimated)
            || renderer.document.scripts.contains { $0.canRun && $0.usesTime && !stoppedScriptIDs.contains($0.id) }
        return animated && clock().isRunning
    }

    private var isEasing: Bool {
        frozenScriptInput == nil && current.parallax != target.parallax
    }

    private func readClock() {
        guard let renderer, renderer.document.isAnimated, let reading = clock?() else {
            current.time = 0
            return
        }
        current.time = reading.time
        current.isRealTime = reading.isRealTime
    }

    private func updateTicking() {
        guard !isSuspended else {
            stopTicking()
            stopPolling()
            return
        }
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
        let timer = Timer(timeInterval: 0.5, target: tickTarget, selector: #selector(TickTarget.poll(_:)), userInfo: nil, repeats: true)
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
        if #available(macOS 14, *), let hostView {
            let link = hostView.displayLink(target: tickTarget, selector: #selector(TickTarget.tick(_:)))
            let cap = tickRateApplied
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, cap), maximum: cap, preferred: cap)
            link.add(to: .main, forMode: .common)
            ticker = link
        } else {
            let fps = Double(tickRateApplied)
            let timer = Timer(
                timeInterval: 1 / max(fps, 30), target: tickTarget, selector: #selector(TickTarget.tick(_:)), userInfo: nil, repeats: true
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
            let k = Float(renderer?.document.parallaxResponse.map { min($0 * dt, 1) } ?? 1 - exp(-dt / Self.parallaxTimeConstant))
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

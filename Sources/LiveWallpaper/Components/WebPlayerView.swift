import AppKit
import WebKit

@MainActor
final class WebPlayerView: NSView {
    static let scriptMessageName = "liveWallpaper"
    private static let embedReadyTimeout: TimeInterval = 20

    private static let captionsOffScript = """
    (function() {
      try {
        document.querySelectorAll('track').forEach(function(track) {
          if (track.kind === 'subtitles' || track.kind === 'captions') {
            track.remove();
          }
        });
        document.querySelectorAll('video').forEach(function(video) {
          for (var i = 0; i < video.textTracks.length; i++) {
            video.textTracks[i].mode = 'disabled';
          }
        });
      } catch (e) {}
    })();
    """

    /// The wallpaper window ignores the mouse, so desktop clicks are replayed into the
    /// page as synthetic events. Only elements that look clickable take a press;
    /// range inputs ignore synthetic events and are driven by value instead.
    private static let pointerForwardScript = """
    (function() {
      var target = null, isRange = false;
      var clickable = 'a[href],button,input,select,textarea,summary,label,[role=button],[role=slider],[role=checkbox],[role=tab],[role=menuitem],[role=option],[onclick]';
      function interactive(el) {
        while (el && el.nodeType === 1) {
          if (el.matches(clickable)) return el;
          var c = getComputedStyle(el).cursor;
          if (c === 'pointer' || c === 'grab' || c === 'ew-resize' || c === 'col-resize') return el;
          el = el.parentElement;
        }
        return null;
      }
      function fire(el, name, x, y, buttons, pointer) {
        var o = { bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y,
                  screenX: x, screenY: y, button: 0, buttons: buttons, detail: 1,
                  pointerId: 1, pointerType: 'mouse', isPrimary: true };
        el.dispatchEvent(pointer ? new PointerEvent(name, o) : new MouseEvent(name, o));
      }
      function setRange(el, x) {
        var r = el.getBoundingClientRect();
        var f = Math.min(1, Math.max(0, (x - r.left) / r.width));
        var min = +el.min || 0, max = el.max === '' ? 100 : +el.max, step = +el.step || 1;
        el.value = Math.round((min + f * (max - min) - min) / step) * step + min;
        el.dispatchEvent(new Event('input', { bubbles: true }));
      }
      window.__liveWallpaperPointer = function(phase, x, y, dx, dy) {
        if (phase === 'wheel') {
          for (var el = document.elementFromPoint(x, y); el; el = el.parentElement) {
            if (/(auto|scroll)/.test(getComputedStyle(el).overflowY) && el.scrollHeight > el.clientHeight) {
              el.scrollBy(dx, dy);
              return true;
            }
          }
          return false;
        }
        if (phase === 'down') {
          target = interactive(document.elementFromPoint(x, y));
          if (!target) return false;
          isRange = target.matches('input[type=range]');
          if (isRange) { setRange(target, x); return true; }
          fire(target, 'pointerdown', x, y, 1, true);
          fire(target, 'mousedown', x, y, 1, false);
          return true;
        }
        if (!target) return false;
        if (phase === 'move') {
          if (isRange) { setRange(target, x); return true; }
          fire(target, 'pointermove', x, y, 1, true);
          fire(target, 'mousemove', x, y, 1, false);
          return true;
        }
        var t = target;
        target = null;
        if (isRange) { t.dispatchEvent(new Event('change', { bubbles: true })); return true; }
        fire(t, 'pointerup', x, y, 0, true);
        fire(t, 'mouseup', x, y, 0, false);
        var under = document.elementFromPoint(x, y);
        if (under && t.contains(under)) t.click();
        return true;
      };
    })();
    """

    enum PointerPhase: String {
        case down, move, up, wheel
    }

    /// `point` is in page coordinates (top-left origin). `onDeclined` runs when the page
    /// had nothing clickable there, so the rest of that press is not forwarded.
    func forwardPointer(
        _ phase: PointerPhase, at point: CGPoint, scroll: CGVector = .zero, onDeclined: (() -> Void)? = nil
    ) {
        // The page is drawn mirrored when flipped, so a press lands on what is shown there.
        let flipped = displayAdjustment.flipsHorizontally
        let x = flipped ? bounds.width - point.x : point.x
        let dx = flipped ? -scroll.dx : scroll.dx
        let call = "window.__liveWallpaperPointer ? window.__liveWallpaperPointer('\(phase.rawValue)', \(x), \(point.y), \(dx), \(scroll.dy)) : false"
        webView.evaluateJavaScript(call) { result, error in
            if let error {
                AppLog.externalWallpapers
                    .error("pointer forward failed: \(error.localizedDescription, privacy: .public)")
            } else if (result as? Bool) != true {
                onDeclined?()
            }
        }
    }

    let webView: WKWebView
    private let navigationDelegate: NavigationDelegate
    private let scriptMessageHandler: EmbedReadyMessageHandler
    private var retryCount = 0
    private let maxRetries = 3
    private var audioEnabled = false
    private var currentLayoutMode: WebWallpaperLayoutMode = .generic
    private var currentRequest: WebWallpaperPlaybackRequest?
    private var awaitsEmbedPlayerReady = false
    private var playerReadyTimeoutWorkItem: DispatchWorkItem?
    private var loadGeneration: UInt64 = 0
    private var suspensionGeneration: UInt64 = 0
    private var isSuspended = false
    /// The page has been torn down to free its resources while the wallpaper is
    /// covered; the webview holds a blank document and the freeze image is what
    /// the user sees. See `deepUnload()`.
    private var isDeepUnloaded = false
    /// A deep-unloaded page is loading again behind the freeze image, which stays
    /// up until the real page can be shown.
    private var awaitsDeepReloadReveal = false
    private lazy var freezeImageView: NSImageView = {
        let imageView = NSImageView(frame: bounds)
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleAxesIndependently
        imageView.isHidden = true
        return imageView
    }()

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

    private let integrationID = UUID()
    private var wantsSpectrum = false
    private var wantsMedia = false
    private var localSettings = LocalWebSettings()
    private var localProperties: [String: WebPropertyValue] = [:]
    private var lastMediaArtwork: String?
    private var spectrumInFlight = false
    private var assetProperties: [String] = []

    func setLocalConfiguration(
        values: [String: WebPropertyValue],
        settings: LocalWebSettings,
        assets: [String] = []
    ) {
        let changed = localProperties != values || assetProperties != assets
        localProperties = values
        assetProperties = assets
        localSettings = settings
        guard currentRequest?.isLocalPackage == true else { return }
        let json = LocalWebHostScript.json(values)
        let assetsJSON = LocalWebHostScript.json(assets)
        if changed {
            webView
                .evaluateJavaScript(
                    "window.__liveWallpaperSetProperties && window.__liveWallpaperSetProperties(\(json), \(assetsJSON));"
                ) { _, error in
                    if let error {
                        AppLog.externalWallpapers
                            .error(
                                "web properties failed: \(error.localizedDescription, privacy: .public)"
                            )
                    }
                }
        }
        refreshIntegration()
    }

    private func refreshIntegration() {
        let active = currentRequest?.isLocalPackage == true && !isSuspended && !isDeepUnloaded
        let spectrum = active && wantsSpectrum && localSettings.audioReactiveEnabled
        let media = active && wantsMedia && localSettings.mediaEnabled
        LocalWebIntegration.shared.update(
            id: integrationID,
            subscription: spectrum || media ? .init(
                spectrum: spectrum, media: media,
                receiveSpectrum: { [weak self] values in self?.sendSpectrum(values) },
                receiveMedia: { [weak self] value, enabled in self?.sendMedia(
                    value,
                    enabled: enabled
                ) }
            ) : nil
        )
        if !spectrum { sendSpectrum([Float](repeating: 0, count: 128)) }
        if !media { sendMedia(WebNowPlaying(), enabled: false) }
    }

    private func sendSpectrum(_ values: [Float]) {
        guard currentRequest?.isLocalPackage == true, !spectrumInFlight else { return }
        spectrumInFlight = true
        let json = LocalWebHostScript.json(values)
        webView
            .evaluateJavaScript(
                "window.__liveWallpaperSpectrum && window.__liveWallpaperSpectrum(\(json));"
            ) { [weak self] _, error in
                self?.spectrumInFlight = false
                if let error {
                    AppLog.externalWallpapers
                        .error(
                            "web spectrum failed: \(error.localizedDescription, privacy: .public)"
                        )
                }
            }
    }

    private func sendMedia(_ value: WebNowPlaying, enabled: Bool) {
        guard currentRequest?.isLocalPackage == true else { return }
        let artworkUnchanged = lastMediaArtwork == value.artwork
        lastMediaArtwork = value.artwork
        var packet = value
        if artworkUnchanged { packet.artwork = "" }
        let json = LocalWebHostScript.json(packet)
        webView
            .evaluateJavaScript(
                "window.__liveWallpaperMedia && window.__liveWallpaperMedia(\(json), \(enabled), \(artworkUnchanged));"
            ) { _, error in
                if let error {
                    AppLog.externalWallpapers
                        .error("web media failed: \(error.localizedDescription, privacy: .public)")
                }
            }
    }

    private var hostVolume: Float = 1
    private var hostFPS: Double = 30
    private var hostLanguage = Locale.current.identifier

    private var hostState: LocalWebHostScript.State {
        .init(
            paused: isSuspended,
            audioEnabled: audioEnabled,
            volume: hostVolume,
            fps: hostFPS,
            language: hostLanguage
        )
    }

    func setHostEnvironment(volume: Float, fps: Double, language: String) {
        hostVolume = volume
        hostFPS = fps
        hostLanguage = language
        applyHostState()
    }

    private func applyHostState() {
        guard currentRequest?.isLocalPackage == true else { return }
        refreshIntegration()
        webView
            .evaluateJavaScript(
                "window.__liveWallpaperUpdate && window.__liveWallpaperUpdate(\(hostState.json));"
            ) { _, error in
                if let error {
                    AppLog.externalWallpapers
                        .error(
                            "web host state failed: \(error.localizedDescription, privacy: .public)"
                        )
                }
            }
    }

    var currentURL: URL?
    var onLoadStateChanged: ((WebWallpaperLoadState) -> Void)?
    /// 最後に読み込ませた壁紙と音の有無。再構築のたびに同じページを読み直さないための記録。
    var loadedSourceID: UUID?
    var loadedWithAudio: Bool?

    override init(frame frameRect: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        Self.installUserScripts(on: configuration.userContentController)

        let scriptMessageHandler = EmbedReadyMessageHandler()
        configuration.userContentController.add(
            scriptMessageHandler,
            name: Self.scriptMessageName
        )

        webView = WKWebView(frame: .zero, configuration: configuration)
        navigationDelegate = NavigationDelegate()
        self.scriptMessageHandler = scriptMessageHandler
        super.init(frame: frameRect)
        scriptMessageHandler.owner = self
        navigationDelegate.owner = self
        webView.navigationDelegate = navigationDelegate
        setupViewHierarchy()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        playerReadyTimeoutWorkItem?.cancel()
        let id = integrationID
        Task { @MainActor in LocalWebIntegration.shared.update(id: id, subscription: nil) }
    }

    func load(request: WebWallpaperPlaybackRequest, audioEnabled: Bool) {
        invalidatePendingWork()
        // Only invalidate any in-flight suspend snapshot (it would belong to the page being
        // replaced); don't force visibility here. rebuildWebWindows() calls
        // applyWebSuspensionState() right before this, so whatever hidden/frozen state that
        // just established for a still-suspended display must survive the reload untouched.
        suspensionGeneration &+= 1
        // invalidatePendingWork() above also drops any deep-suspend teardown: this
        // is the page we want now, not the one that got unloaded. The freeze image
        // (if any) stays owned by the suspension state, so it survives until
        // setSuspended(false) — this load must not reveal the webview by itself.
        webView.stopLoading()
        LocalWebIntegration.shared.update(id: integrationID, subscription: nil)
        wantsSpectrum = false
        wantsMedia = false
        currentRequest = request
        currentLayoutMode = request.layoutMode
        awaitsEmbedPlayerReady = request.awaitsEmbedPlayerReady
        if case let .url(url) = request.loadContent {
            currentURL = url
        } else {
            currentURL = nil
        }
        retryCount = 0
        self.audioEnabled = audioEnabled
        reportLoadState(.loading)
        performLoad(request: request)
    }

    /// Tears the page down after the wallpaper has stayed covered long enough to
    /// be worth it, freeing what a merely-paused page keeps hold of: the DOM, the
    /// JS heap, decoded media buffers and any timers the page kept running behind
    /// our pause script. This mirrors the video wallpaper's deep suspend, and like
    /// it, leans on the freeze image already on screen so nothing visibly changes.
    ///
    /// Refuses to run without that freeze image: blanking the webview would then
    /// expose the window's opaque black backing layer on a screen we may only
    /// believe is covered.
    func deepUnload() {
        guard !isDeepUnloaded, !awaitsDeepReloadReveal, isShowingFreezeImage,
              currentRequest != nil
        else {
            return
        }
        isDeepUnloaded = true
        refreshIntegration()
        playerReadyTimeoutWorkItem?.cancel()
        playerReadyTimeoutWorkItem = nil
        loadGeneration &+= 1
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        AppLog.suspend.info("web page unloaded")
    }

    /// Rebuilds the torn-down page behind the freeze image. The live page is only
    /// revealed once it reports a terminal load state, so uncovering the wallpaper
    /// never flashes a blank document.
    private func startDeepReload() {
        guard isDeepUnloaded, let request = currentRequest else {
            return
        }
        isDeepUnloaded = false
        awaitsDeepReloadReveal = true
        retryCount = 0
        awaitsEmbedPlayerReady = request.awaitsEmbedPlayerReady
        loadGeneration &+= 1
        AppLog.suspend.info("web page reloading after deep suspend")
        // Deliberately no .loading report: this is our own resource bookkeeping,
        // not a reload the user asked for, so the settings UI shouldn't blink
        // through a loading state every time the wallpaper is uncovered.
        performLoad(request: request)
    }

    /// The freeze image on screen must not be replaced by a fresh snapshot: the
    /// webview is either blank (deep-unloaded) or mid-rebuild, so snapshotting it
    /// would capture nothing useful and throw away the last good frame.
    private var freezeImageIsAuthoritative: Bool {
        isDeepUnloaded || awaitsDeepReloadReveal
    }

    private var isShowingFreezeImage: Bool {
        freezeImageView.image != nil && !freezeImageView.isHidden
    }

    private func reportLoadState(_ state: WebWallpaperLoadState) {
        switch state {
        case .loaded, .failed:
            finishDeepReloadRevealIfNeeded()
        case .idle, .loading:
            break
        }
        onLoadStateChanged?(state)
    }

    /// Swaps the freeze image for the rebuilt page. Runs on both success and
    /// failure: a page that failed to come back should look exactly like any other
    /// failed load rather than sitting frozen on a stale still forever.
    private func finishDeepReloadRevealIfNeeded() {
        guard awaitsDeepReloadReveal else {
            return
        }
        awaitsDeepReloadReveal = false
        guard !isSuspended else {
            // Re-covered while the page was rebuilding. It's live again, so put it
            // back into the ordinary frozen state (fresh snapshot + paused media);
            // the model's deep-suspend timer is still armed and will tear it down
            // again if the coverage sticks.
            setSuspended(true)
            return
        }
        webView.isHidden = false
        freezeImageView.isHidden = true
        freezeImageView.image = nil
        AppLog.suspend.info("web page revealed after deep suspend")
    }

    private func performLoad(request: WebWallpaperPlaybackRequest) {
        lastMediaArtwork = nil
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        Self.installUserScripts(on: controller)
        if request.isLocalPackage {
            controller.addUserScript(WKUserScript(
                source: LocalWebHostScript.bootstrap(
                    state: hostState,
                    properties: localProperties,
                    assets: assetProperties
                ),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        switch request.loadContent {
        case let .url(url):
            let urlRequest = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 30
            )
            webView.load(urlRequest)
        case let .html(html, baseURL):
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func setAudioEnabled(_ enabled: Bool) {
        audioEnabled = enabled
        applyAudioPolicy()
    }

    func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
        applyHostState()
        suspensionGeneration &+= 1
        let generation = suspensionGeneration

        if suspended {
            guard !freezeImageIsAuthoritative else {
                // Already frozen on a still that outranks anything we could capture
                // now, and there's no live page left to pause either.
                return
            }
            // Freeze on a snapshot instead of just hiding the webview: hiding alone would
            // expose the window's opaque black backing layer whenever the coverage heuristic
            // suspends without the screen actually being covered (see WallpaperModel+Coverage).
            webView.takeSnapshot(with: nil) { [weak self] image, _ in
                guard let self, suspensionGeneration == generation, let image else {
                    return
                }
                freezeImageView.image = image
                freezeImageView.isHidden = false
                webView.isHidden = true
            }
        } else if isDeepUnloaded {
            // The page was torn down while covered; rebuild it behind the freeze
            // image rather than revealing a blank webview. There's nothing to
            // unpause — the fresh page starts playing on its own.
            startDeepReload()
            return
        } else {
            webView.isHidden = false
            freezeImageView.isHidden = true
        }

        let embedScript = suspended
            ? "typeof pauseWallpaperPlayback==='function'&&pauseWallpaperPlayback();"
            : "typeof resumeWallpaperPlayback==='function'&&resumeWallpaperPlayback();"
        webView.evaluateJavaScript(embedScript) { [weak self] _, _ in
            guard let self, currentLayoutMode == .generic else {
                return
            }
            applyGenericPlaybackScript(paused: suspended)
        }
    }

    func stopLoading() {
        LocalWebIntegration.shared.update(id: integrationID, subscription: nil)
        invalidatePendingWork()
        webView.stopLoading()
        currentURL = nil
        currentRequest = nil
        awaitsEmbedPlayerReady = false
    }

    func tearDown() {
        LocalWebIntegration.shared.update(id: integrationID, subscription: nil)
        invalidatePendingWork()
        onLoadStateChanged = nil
        webView.stopLoading()
        currentURL = nil
        currentRequest = nil
        awaitsEmbedPlayerReady = false
    }

    func handleNavigationFinished() {
        guard !isDeepUnloaded else {
            // The blank document from deepUnload() finished loading. There's no
            // page to configure and nothing to report — the freeze image stays up
            // until startDeepReload() brings the real page back.
            return
        }
        retryCount = 0
        applyWallpaperLayoutScript()
        applyCaptionsOffScript()
        applyAudioPolicy()
        if awaitsEmbedPlayerReady {
            scheduleEmbedPlayerReadyTimeout()
            return
        }
        reportLoadState(.loaded)
    }

    func handleEmbedPlayerReady() {
        playerReadyTimeoutWorkItem?.cancel()
        reportLoadState(.loaded)
    }

    func handleEmbedPlayerError() {
        playerReadyTimeoutWorkItem?.cancel()
        reportLoadState(.failed)
    }

    func handleNavigationFailed() {
        playerReadyTimeoutWorkItem?.cancel()
        guard !isDeepUnloaded else {
            return
        }
        guard retryCount < maxRetries, let request = currentRequest else {
            reportLoadState(.failed)
            return
        }
        retryCount += 1
        let generation = loadGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(retryCount)) { [weak self] in
            guard let self,
                  loadGeneration == generation,
                  currentRequest == request
            else {
                return
            }
            reportLoadState(.loading)
            performLoad(request: request)
        }
    }

    private func invalidatePendingWork() {
        playerReadyTimeoutWorkItem?.cancel()
        playerReadyTimeoutWorkItem = nil
        loadGeneration &+= 1
        isDeepUnloaded = false
        awaitsDeepReloadReveal = false
    }

    private func scheduleEmbedPlayerReadyTimeout() {
        playerReadyTimeoutWorkItem?.cancel()
        let generation = loadGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, loadGeneration == generation else {
                return
            }
            reportLoadState(.failed)
        }
        playerReadyTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.embedReadyTimeout, execute: workItem)
    }

    private func applyWallpaperLayoutScript() {
        let css = switch currentLayoutMode {
        case .generic:
            "html, body { margin: 0 !important; padding: 0 !important; overflow: hidden !important; width: 100% !important; height: 100% !important; background: #000 !important; }"
        case .videoEmbed:
            """
            html, body, #player, #movie_player, .html5-video-player, .html5-video-container, video, iframe { margin: 0 !important; padding: 0 !important; overflow: hidden !important; width: 100% !important; height: 100% !important; max-width: 100% !important; max-height: 100% !important; background: #000 !important; border: 0 !important; }
            .ytp-chrome-top, .ytp-chrome-bottom, .ytp-gradient-top, .ytp-gradient-bottom, .ytp-pause-overlay, .ytp-title, .ytp-watermark, .ytp-ce-element, .ytp-endscreen-content, .ytp-caption-window-container, .ytp-caption-segment, .caption-window, .ytp-subtitles-button { display: none !important; opacity: 0 !important; visibility: hidden !important; }
            video::cue { visibility: hidden !important; display: none !important; }
            """
        }
        let escapedCSS = css
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
        let script = """
        (function() {
            var style = document.getElementById('live-wallpaper-style');
            if (!style) {
                style = document.createElement('style');
                style.id = 'live-wallpaper-style';
                document.documentElement.appendChild(style);
            }
            style.textContent = '\(escapedCSS)';
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func applyCaptionsOffScript() {
        webView.evaluateJavaScript(Self.captionsOffScript, completionHandler: nil)
    }

    private func applyGenericPlaybackScript(paused: Bool) {
        let script = paused
            ? "document.querySelectorAll('video').forEach(function(v){try{v.pause();}catch(e){}});"
            : "document.querySelectorAll('video').forEach(function(v){try{v.play();}catch(e){}});"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func applyAudioPolicy() {
        applyHostState()
        let script = audioEnabled
            ? "document.querySelectorAll('video,audio').forEach(function(e){e.muted=false;});"
            : "document.querySelectorAll('video,audio').forEach(function(e){e.muted=true;});"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func setupViewHierarchy() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        pageView.wantsLayer = true
        pageView.layerUsesCoreImageFilters = true
        addSubview(pageView)
        pageView.frame = bounds
        pageView.addSubview(webView)
        webView.frame = pageView.bounds
        pageView.addSubview(freezeImageView)
        freezeImageView.frame = pageView.bounds
        // 減光オーバーレイはメニューバーマスクより上に載せる(理由は PlayerView 参照)。
        addSubview(menuBarMaskView, positioned: .above, relativeTo: nil)
        addSubview(readabilityDimOverlayView, positioned: .above, relativeTo: nil)
    }

    override func layout() {
        super.layout()
        pageView.frame = bounds
        webView.frame = pageView.bounds
        freezeImageView.frame = pageView.bounds
        applyFlip()
        readabilityDimOverlayView.frame = bounds
        layoutMenuBarMask()
    }

    /// Holds the page and its freeze image, so that the display adjustment covers both.
    private let pageView = NSView()
    private(set) var displayAdjustment = WebDisplayAdjustment()

    func setDisplayAdjustment(_ adjustment: WebDisplayAdjustment) {
        guard adjustment != displayAdjustment else { return }
        let colorChanged = adjustment.color != displayAdjustment.color
        displayAdjustment = adjustment
        if colorChanged { pageView.layer?.filters = adjustment.color?.layerFilters() }
        applyFlip()
    }

    private func applyFlip() {
        // AppKit owns the layer's own transform, so the mirror goes on its sublayers.
        pageView.layer?.sublayerTransform = displayAdjustment.flipsHorizontally
            ? CATransform3DScale(CATransform3DMakeTranslation(pageView.bounds.width, 0, 0), -1, 1, 1)
            : CATransform3DIdentity
    }

    private func layoutMenuBarMask() {
        menuBarMaskView.frame = CGRect(
            x: 0,
            y: bounds.height - menuBarMaskHeight,
            width: bounds.width,
            height: menuBarMaskHeight
        )
    }

    private static func installUserScripts(on contentController: WKUserContentController) {
        let bootstrapScript = """
        (function() {
            var style = document.createElement('style');
            style.id = 'live-wallpaper-style';
            style.textContent = 'html, body { margin: 0 !important; padding: 0 !important; overflow: hidden !important; width: 100% !important; height: 100% !important; }';
            document.documentElement.appendChild(style);
        })();
        """
        contentController.addUserScript(
            WKUserScript(
                source: bootstrapScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        contentController.addUserScript(
            WKUserScript(
                source: pointerForwardScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        contentController.addUserScript(
            WKUserScript(
                source: captionsOffScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
    }

    private final class NavigationDelegate: NSObject, WKNavigationDelegate {
        weak var owner: WebPlayerView?

        func webView(_: WKWebView, didFinish _: WKNavigation!) {
            owner?.handleNavigationFinished()
        }

        func webView(
            _: WKWebView,
            didFail _: WKNavigation!,
            withError _: Error
        ) {
            owner?.handleNavigationFailed()
        }

        func webView(
            _: WKWebView,
            didFailProvisionalNavigation _: WKNavigation!,
            withError error: Error
        ) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                return
            }
            owner?.handleNavigationFailed()
        }
    }

    private final class EmbedReadyMessageHandler: NSObject, WKScriptMessageHandler {
        weak var owner: WebPlayerView?

        func userContentController(
            _: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == WebPlayerView.scriptMessageName,
                  let body = message.body as? String
            else {
                return
            }
            switch body {
            case "spectrum":
                guard message.frameInfo.isMainFrame,
                      owner?.currentRequest?.isLocalPackage == true else { return }
                owner?.wantsSpectrum = true
                owner?.refreshIntegration()
            case "media":
                guard message.frameInfo.isMainFrame,
                      owner?.currentRequest?.isLocalPackage == true else { return }
                owner?.wantsMedia = true
                owner?.refreshIntegration()
            case "ready":
                owner?.handleEmbedPlayerReady()
            case "error":
                owner?.handleEmbedPlayerError()
            default:
                break
            }
        }
    }
}

enum WebWallpaperLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed
}

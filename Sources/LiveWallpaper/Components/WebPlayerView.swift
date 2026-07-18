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

    var menuBarMaskHeight: CGFloat = 0 {
        didSet {
            guard menuBarMaskHeight != oldValue else {
                return
            }
            menuBarMaskView.isHidden = menuBarMaskHeight <= 0
            layoutMenuBarMask()
        }
    }

    var currentURL: URL?
    var onLoadStateChanged: ((WebWallpaperLoadState) -> Void)?

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
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        playerReadyTimeoutWorkItem?.cancel()
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
        currentRequest = request
        currentLayoutMode = request.layoutMode
        awaitsEmbedPlayerReady = request.awaitsEmbedPlayerReady
        if case .url(let url) = request.loadContent {
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
        playerReadyTimeoutWorkItem?.cancel()
        playerReadyTimeoutWorkItem = nil
        loadGeneration &+= 1
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        AppLog.suspend.debug("web page unloaded")
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
        AppLog.suspend.debug("web page reloading after deep suspend")
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
        AppLog.suspend.debug("web page revealed after deep suspend")
    }

    private func performLoad(request: WebWallpaperPlaybackRequest) {
        switch request.loadContent {
        case .url(let url):
            let urlRequest = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 30
            )
            webView.load(urlRequest)
        case .html(let html, let baseURL):
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func setAudioEnabled(_ enabled: Bool) {
        audioEnabled = enabled
        applyAudioPolicy()
    }

    func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
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
                guard let self, self.suspensionGeneration == generation, let image else {
                    return
                }
                self.freezeImageView.image = image
                self.freezeImageView.isHidden = false
                self.webView.isHidden = true
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
            guard let self, self.currentLayoutMode == .generic else {
                return
            }
            self.applyGenericPlaybackScript(paused: suspended)
        }
    }

    func stopLoading() {
        invalidatePendingWork()
        webView.stopLoading()
        currentURL = nil
        currentRequest = nil
        awaitsEmbedPlayerReady = false
    }

    func tearDown() {
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
                  self.loadGeneration == generation,
                  self.currentRequest == request
            else {
                return
            }
            self.reportLoadState(.loading)
            self.performLoad(request: request)
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
            guard let self, self.loadGeneration == generation else {
                return
            }
            self.reportLoadState(.failed)
        }
        playerReadyTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.embedReadyTimeout, execute: workItem)
    }

    private func applyWallpaperLayoutScript() {
        let css: String = switch currentLayoutMode {
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
        addSubview(webView)
        webView.frame = bounds
        addSubview(freezeImageView)
        freezeImageView.frame = bounds
        addSubview(menuBarMaskView, positioned: .above, relativeTo: nil)
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
        freezeImageView.frame = bounds
        layoutMenuBarMask()
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
                source: captionsOffScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
    }

    private final class NavigationDelegate: NSObject, WKNavigationDelegate {
        weak var owner: WebPlayerView?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            owner?.handleNavigationFinished()
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            owner?.handleNavigationFailed()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
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
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == WebPlayerView.scriptMessageName,
                  let body = message.body as? String
            else {
                return
            }
            switch body {
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

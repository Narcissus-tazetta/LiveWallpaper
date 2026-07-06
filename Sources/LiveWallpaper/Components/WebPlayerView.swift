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
        onLoadStateChanged?(.loading)
        performLoad(request: request)
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
        suspensionGeneration &+= 1
        let generation = suspensionGeneration

        if suspended {
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
        retryCount = 0
        applyWallpaperLayoutScript()
        applyCaptionsOffScript()
        applyAudioPolicy()
        if awaitsEmbedPlayerReady {
            scheduleEmbedPlayerReadyTimeout()
            return
        }
        onLoadStateChanged?(.loaded)
    }

    func handleEmbedPlayerReady() {
        playerReadyTimeoutWorkItem?.cancel()
        onLoadStateChanged?(.loaded)
    }

    func handleEmbedPlayerError() {
        playerReadyTimeoutWorkItem?.cancel()
        onLoadStateChanged?(.failed)
    }

    func handleNavigationFailed() {
        playerReadyTimeoutWorkItem?.cancel()
        guard retryCount < maxRetries, let request = currentRequest else {
            onLoadStateChanged?(.failed)
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
            self.onLoadStateChanged?(.loading)
            self.performLoad(request: request)
        }
    }

    private func invalidatePendingWork() {
        playerReadyTimeoutWorkItem?.cancel()
        playerReadyTimeoutWorkItem = nil
        loadGeneration &+= 1
    }

    private func scheduleEmbedPlayerReadyTimeout() {
        playerReadyTimeoutWorkItem?.cancel()
        let generation = loadGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.loadGeneration == generation else {
                return
            }
            self.onLoadStateChanged?(.failed)
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

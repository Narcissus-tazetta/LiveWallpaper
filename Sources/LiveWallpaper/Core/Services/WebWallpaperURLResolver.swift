import Foundation

enum WebWallpaperURLError: LocalizedError, Equatable {
    case emptyInput
    case invalidURL
    case unsupportedScheme

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "URLを入力してください"
        case .invalidURL:
            return "有効なURLを入力してください"
        case .unsupportedScheme:
            return "http または https のURLのみ対応しています"
        }
    }
}

enum WebWallpaperLayoutMode: Equatable {
    case generic
    case videoEmbed
}

enum WebWallpaperLoadContent: Equatable {
    case url(URL)
    case html(String, baseURL: URL)
}

struct WebWallpaperPlaybackRequest: Equatable {
    let loadContent: WebWallpaperLoadContent
    let layoutMode: WebWallpaperLayoutMode
    let canonicalKey: String
    let awaitsEmbedPlayerReady: Bool

    init(
        loadContent: WebWallpaperLoadContent,
        layoutMode: WebWallpaperLayoutMode,
        canonicalKey: String,
        awaitsEmbedPlayerReady: Bool = false
    ) {
        self.loadContent = loadContent
        self.layoutMode = layoutMode
        self.canonicalKey = canonicalKey
        self.awaitsEmbedPlayerReady = awaitsEmbedPlayerReady
    }
}

enum WebWallpaperURLResolver {
    private static let embedOrigin = URL(string: "https://livewallpaper.local")!

    static func resolve(originalURL: URL, audioEnabled: Bool) -> WebWallpaperPlaybackRequest {
        if let videoID = youtubeVideoID(from: originalURL) {
            return youtubePlaybackRequest(videoID: videoID, audioEnabled: audioEnabled)
        }
        if let videoID = vimeoVideoID(from: originalURL) {
            return WebWallpaperPlaybackRequest(
                loadContent: .url(vimeoBackgroundURL(videoID: videoID, audioEnabled: audioEnabled)),
                layoutMode: .videoEmbed,
                canonicalKey: "vimeo:\(videoID)"
            )
        }
        return WebWallpaperPlaybackRequest(
            loadContent: .url(originalURL),
            layoutMode: .generic,
            canonicalKey: originalURL.absoluteString
        )
    }

    static func canonicalKey(for url: URL) -> String {
        resolve(originalURL: url, audioEnabled: false).canonicalKey
    }

    static func normalizeURLString(_ input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WebWallpaperURLError.emptyInput
        }

        let candidate: URL? =
            if let direct = URL(string: trimmed), direct.scheme != nil {
                direct
            } else {
                URL(string: "https://\(trimmed)")
            }

        guard let url = candidate else {
            throw WebWallpaperURLError.invalidURL
        }
        try validateURL(url)
        return url
    }

    static func validateURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw WebWallpaperURLError.unsupportedScheme
        }
        guard let host = url.host, !host.isEmpty else {
            throw WebWallpaperURLError.invalidURL
        }
    }

    static func requiresReloadForAudioChange(_ url: URL) -> Bool {
        youtubeVideoID(from: url) != nil || vimeoVideoID(from: url) != nil
    }

    static func youtubeVideoID(from url: URL) -> String? {
        guard let host = url.host?.lowercased() else {
            return nil
        }

        if host == "youtu.be" {
            return pathComponentID(from: url)
        }

        guard isYouTubeHost(host) else {
            return nil
        }

        let components = url.pathComponents.filter { $0 != "/" }
        if let shortsIndex = components.firstIndex(of: "shorts"), shortsIndex + 1 < components.count {
            return components[shortsIndex + 1]
        }
        if let embedIndex = components.firstIndex(of: "embed"), embedIndex + 1 < components.count {
            return components[embedIndex + 1]
        }
        if let liveIndex = components.firstIndex(of: "live"), liveIndex + 1 < components.count {
            return components[liveIndex + 1]
        }

        if let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let videoID = queryItems.first(where: { $0.name == "v" })?.value,
           !videoID.isEmpty
        {
            return videoID
        }

        return nil
    }

    static func vimeoVideoID(from url: URL) -> String? {
        guard let host = url.host?.lowercased(), isVimeoHost(host) else {
            return nil
        }

        let components = url.pathComponents.filter { $0 != "/" }
        if let videoIndex = components.firstIndex(of: "video"), videoIndex + 1 < components.count {
            return components[videoIndex + 1]
        }
        if components.count == 1, components[0].allSatisfy(\.isNumber) {
            return components[0]
        }
        return nil
    }

    private static func youtubePlaybackRequest(
        videoID: String,
        audioEnabled: Bool
    ) -> WebWallpaperPlaybackRequest {
        let mute = audioEnabled ? "0" : "1"
        let escapedVideoID = escapeForJavaScriptString(videoID)
        let escapedOrigin = escapeForJavaScriptString(embedOrigin.absoluteString)
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        html, body { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden; background: #000; }
        #player { position: fixed; inset: 0; width: 100%; height: 100%; }
        </style>
        </head>
        <body>
        <div id="player"></div>
        <script>
        var tag = document.createElement('script');
        tag.src = 'https://www.youtube.com/iframe_api';
        var firstScriptTag = document.getElementsByTagName('script')[0];
        firstScriptTag.parentNode.insertBefore(tag, firstScriptTag);
        var player;
        function disableCaptions(target) {
          try {
            target.setOption('captions', 'track', {});
            target.unloadModule('captions');
          } catch (e) {}
        }
        function postWallpaperMessage(name) {
          try {
            window.webkit.messageHandlers.liveWallpaper.postMessage(name);
          } catch (e) {}
        }
        function pauseWallpaperPlayback() {
          try { if (player && player.pauseVideo) player.pauseVideo(); } catch (e) {}
        }
        function resumeWallpaperPlayback() {
          try { if (player && player.playVideo) player.playVideo(); } catch (e) {}
        }
        function onYouTubeIframeAPIReady() {
          player = new YT.Player('player', {
            width: '100%',
            height: '100%',
            videoId: '\(escapedVideoID)',
            playerVars: {
              autoplay: 1,
              mute: \(mute),
              controls: 0,
              loop: 1,
              playlist: '\(escapedVideoID)',
              modestbranding: 1,
              rel: 0,
              playsinline: 1,
              iv_load_policy: 3,
              disablekb: 1,
              fs: 0,
              cc_load_policy: 0,
              enablejsapi: 1,
              origin: '\(escapedOrigin)'
            },
            events: {
              onReady: function(event) {
                disableCaptions(event.target);
                postWallpaperMessage('ready');
              },
              onError: function() { postWallpaperMessage('error'); },
              onStateChange: function(event) { disableCaptions(event.target); }
            }
          });
        }
        </script>
        </body>
        </html>
        """
        return WebWallpaperPlaybackRequest(
            loadContent: .html(html, baseURL: embedOrigin),
            layoutMode: .videoEmbed,
            canonicalKey: "youtube:\(videoID)",
            awaitsEmbedPlayerReady: true
        )
    }

    private static func isYouTubeHost(_ host: String) -> Bool {
        let knownHosts: Set<String> = [
            "youtube.com",
            "www.youtube.com",
            "m.youtube.com",
            "music.youtube.com",
            "youtube-nocookie.com",
            "www.youtube-nocookie.com",
        ]
        return knownHosts.contains(host)
    }

    private static func isVimeoHost(_ host: String) -> Bool {
        let knownHosts: Set<String> = [
            "vimeo.com",
            "www.vimeo.com",
            "player.vimeo.com",
        ]
        return knownHosts.contains(host)
    }

    private static func escapeForJavaScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    static func vimeoBackgroundURL(videoID: String, audioEnabled: Bool) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "player.vimeo.com"
        components.path = "/video/\(videoID)"
        components.queryItems = [
            URLQueryItem(name: "autoplay", value: "1"),
            URLQueryItem(name: "muted", value: audioEnabled ? "0" : "1"),
            URLQueryItem(name: "loop", value: "1"),
            URLQueryItem(name: "background", value: "1"),
            URLQueryItem(name: "autopause", value: "0"),
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "texttrack", value: "false"),
        ]
        return components.url ?? URL(string: "https://player.vimeo.com/video/\(videoID)")!
    }

    private static func pathComponentID(from url: URL) -> String? {
        let id = url.pathComponents.filter { $0 != "/" }.first
        guard let id, !id.isEmpty else {
            return nil
        }
        return id
    }
}

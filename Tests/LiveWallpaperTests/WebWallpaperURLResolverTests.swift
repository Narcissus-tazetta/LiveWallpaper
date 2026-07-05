import XCTest
@testable import LiveWallpaper

final class WebWallpaperURLResolverTests: XCTestCase {
    func testYouTubeWatchURLResolvesToHTMLWrapper() {
        let original = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        let request = WebWallpaperURLResolver.resolve(originalURL: original, audioEnabled: false)

        XCTAssertEqual(request.layoutMode, .videoEmbed)
        XCTAssertEqual(request.canonicalKey, "youtube:dQw4w9WgXcQ")
        guard case .html(let html, let baseURL) = request.loadContent else {
            XCTFail("Expected HTML wrapper for YouTube")
            return
        }
        XCTAssertEqual(baseURL.absoluteString, "https://livewallpaper.local")
        XCTAssertTrue(html.contains("iframe_api"))
        XCTAssertTrue(html.contains("videoId: 'dQw4w9WgXcQ'"))
        XCTAssertTrue(html.contains("cc_load_policy: 0"))
        XCTAssertTrue(html.contains("disableCaptions"))
        XCTAssertTrue(html.contains("origin: 'https://livewallpaper.local'"))
        XCTAssertTrue(request.awaitsEmbedPlayerReady)
        XCTAssertTrue(html.contains("postWallpaperMessage"))
        XCTAssertTrue(html.contains("pauseWallpaperPlayback"))
    }

    func testSpoofedYouTubeHostFallsThroughToGenericURL() {
        let spoofed = URL(string: "https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ")!
        let request = WebWallpaperURLResolver.resolve(originalURL: spoofed, audioEnabled: false)

        XCTAssertEqual(request.layoutMode, .generic)
        XCTAssertFalse(request.awaitsEmbedPlayerReady)
        guard case .url(let playbackURL) = request.loadContent else {
            XCTFail("Expected generic URL passthrough")
            return
        }
        XCTAssertEqual(playbackURL, spoofed)
    }

    func testSpoofedVimeoHostFallsThroughToGenericURL() {
        let spoofed = URL(string: "https://vimeo.com.evil.example/123456789")!
        let request = WebWallpaperURLResolver.resolve(originalURL: spoofed, audioEnabled: false)

        XCTAssertEqual(request.layoutMode, .generic)
        guard case .url(let playbackURL) = request.loadContent else {
            XCTFail("Expected generic URL passthrough")
            return
        }
        XCTAssertEqual(playbackURL, spoofed)
    }

    func testYouTubeShortURLUsesMutedEmbedWhenAudioDisabled() {
        let original = URL(string: "https://youtu.be/abc123XYZ_0")!
        let request = WebWallpaperURLResolver.resolve(originalURL: original, audioEnabled: true)

        XCTAssertEqual(request.canonicalKey, "youtube:abc123XYZ_0")
        guard case .html(let html, _) = request.loadContent else {
            XCTFail("Expected HTML wrapper for YouTube")
            return
        }
        XCTAssertTrue(html.contains("mute: 0"))
    }

    func testVimeoURLResolvesToBackgroundPlayer() {
        let original = URL(string: "https://vimeo.com/123456789")!
        let request = WebWallpaperURLResolver.resolve(originalURL: original, audioEnabled: false)

        XCTAssertEqual(request.layoutMode, .videoEmbed)
        XCTAssertEqual(request.canonicalKey, "vimeo:123456789")
        guard case .url(let playbackURL) = request.loadContent else {
            XCTFail("Expected direct URL for Vimeo")
            return
        }
        XCTAssertEqual(playbackURL.host, "player.vimeo.com")
        XCTAssertTrue(playbackURL.query?.contains("background=1") == true)
        XCTAssertTrue(playbackURL.query?.contains("texttrack=false") == true)
    }

    func testGenericURLIsPassedThrough() {
        let original = URL(string: "https://example.com/page")!
        let request = WebWallpaperURLResolver.resolve(originalURL: original, audioEnabled: false)

        XCTAssertEqual(request.layoutMode, .generic)
        guard case .url(let playbackURL) = request.loadContent else {
            XCTFail("Expected direct URL")
            return
        }
        XCTAssertEqual(playbackURL, original)
    }
}

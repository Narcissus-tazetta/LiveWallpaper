@testable import LiveWallpaper
import XCTest

final class WebWallpaperURLResolverTests: XCTestCase {
    func testYouTubeWatchURLResolvesToHTMLWrapper() throws {
        let original = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        let request = WebWallpaperURLResolver.resolve(originalURL: original, audioEnabled: false)

        XCTAssertEqual(request.layoutMode, .videoEmbed)
        XCTAssertEqual(request.canonicalKey, "youtube:dQw4w9WgXcQ")
        guard case let .html(html, baseURL) = request.loadContent else {
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

    func testSpoofedYouTubeHostFallsThroughToGenericURL() throws {
        let spoofed =
            try XCTUnwrap(URL(string: "https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ"))
        let request = WebWallpaperURLResolver.resolve(originalURL: spoofed, audioEnabled: false)

        XCTAssertEqual(request.layoutMode, .generic)
        XCTAssertFalse(request.awaitsEmbedPlayerReady)
        guard case let .url(playbackURL) = request.loadContent else {
            XCTFail("Expected generic URL passthrough")
            return
        }
        XCTAssertEqual(playbackURL, spoofed)
    }

    func testSpoofedVimeoHostFallsThroughToGenericURL() throws {
        let spoofed = try XCTUnwrap(URL(string: "https://vimeo.com.evil.example/123456789"))
        let request = WebWallpaperURLResolver.resolve(originalURL: spoofed, audioEnabled: false)

        XCTAssertEqual(request.layoutMode, .generic)
        guard case let .url(playbackURL) = request.loadContent else {
            XCTFail("Expected generic URL passthrough")
            return
        }
        XCTAssertEqual(playbackURL, spoofed)
    }

    func testYouTubeShortURLUsesMutedEmbedWhenAudioDisabled() throws {
        let original = try XCTUnwrap(URL(string: "https://youtu.be/abc123XYZ_0"))
        let request = WebWallpaperURLResolver.resolve(originalURL: original, audioEnabled: true)

        XCTAssertEqual(request.canonicalKey, "youtube:abc123XYZ_0")
        guard case let .html(html, _) = request.loadContent else {
            XCTFail("Expected HTML wrapper for YouTube")
            return
        }
        XCTAssertTrue(html.contains("mute: 0"))
    }

    func testVimeoURLResolvesToBackgroundPlayer() throws {
        let original = try XCTUnwrap(URL(string: "https://vimeo.com/123456789"))
        let request = WebWallpaperURLResolver.resolve(originalURL: original, audioEnabled: false)

        XCTAssertEqual(request.layoutMode, .videoEmbed)
        XCTAssertEqual(request.canonicalKey, "vimeo:123456789")
        guard case let .url(playbackURL) = request.loadContent else {
            XCTFail("Expected direct URL for Vimeo")
            return
        }
        XCTAssertEqual(playbackURL.host, "player.vimeo.com")
        XCTAssertTrue(playbackURL.query?.contains("background=1") == true)
        XCTAssertTrue(playbackURL.query?.contains("texttrack=false") == true)
    }

    func testGenericURLIsPassedThrough() throws {
        let original = try XCTUnwrap(URL(string: "https://example.com/page"))
        let request = WebWallpaperURLResolver.resolve(originalURL: original, audioEnabled: false)

        XCTAssertEqual(request.layoutMode, .generic)
        guard case let .url(playbackURL) = request.loadContent else {
            XCTFail("Expected direct URL")
            return
        }
        XCTAssertEqual(playbackURL, original)
    }

    // MARK: - normalizeURLString / validateURL

    func testNormalizeURLStringRejectsEmptyInput() {
        XCTAssertThrowsError(try WebWallpaperURLResolver.normalizeURLString("   ")) { error in
            XCTAssertEqual(error as? WebWallpaperURLError, .emptyInput)
        }
    }

    func testNormalizeURLStringAddsHTTPSSchemeWhenMissing() throws {
        let url = try WebWallpaperURLResolver.normalizeURLString("example.com/page")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "example.com")
    }

    func testNormalizeURLStringTrimsWhitespace() throws {
        let url = try WebWallpaperURLResolver.normalizeURLString("  https://example.com  ")
        XCTAssertEqual(url.absoluteString, "https://example.com")
    }

    func testNormalizeURLStringRejectsUnsupportedScheme() {
        XCTAssertThrowsError(try WebWallpaperURLResolver
            .normalizeURLString("ftp://example.com"))
        { error in
            XCTAssertEqual(error as? WebWallpaperURLError, .unsupportedScheme)
        }
    }

    func testNormalizeURLStringRejectsMissingHost() {
        XCTAssertThrowsError(try WebWallpaperURLResolver
            .normalizeURLString("https:///path"))
        { error in
            XCTAssertEqual(error as? WebWallpaperURLError, .invalidURL)
        }
    }

    func testValidateURLAcceptsHTTPAndHTTPS() throws {
        XCTAssertNoThrow(try WebWallpaperURLResolver
            .validateURL(XCTUnwrap(URL(string: "http://example.com"))))
        XCTAssertNoThrow(try WebWallpaperURLResolver
            .validateURL(XCTUnwrap(URL(string: "https://example.com"))))
    }
}

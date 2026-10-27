import WebKit
import XCTest
@testable import LiveWallpaper

@MainActor
final class LocalWebHostAudioTests: XCTestCase {
    private final class Navigation: NSObject, WKNavigationDelegate {
        var onFinish: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish?() }
    }

    private func makeHost(audioEnabled: Bool) async throws -> (WKWebView, Navigation) {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let state = LocalWebHostScript.State(
            paused: false, audioEnabled: audioEnabled, volume: 1, fps: 60, language: "en"
        )
        configuration.userContentController.addUserScript(WKUserScript(
            source: LocalWebHostScript.bootstrap(state: state),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 100, height: 100), configuration: configuration)
        let navigation = Navigation()
        webView.navigationDelegate = navigation
        let loaded = expectation(description: "page loaded")
        navigation.onFinish = { loaded.fulfill() }
        webView.loadHTMLString("<html><body></body></html>", baseURL: URL(string: "https://example.test/"))
        await fulfillment(of: [loaded], timeout: 15)
        return (webView, navigation)
    }

    // A page's own `new Audio()` is never attached to the document, which is how Blue Archive
    // Memorial Lobby plays its BGM and voice lines.
    private let startDetachedAudio = """
    const samples = 8000, bytes = new Uint8Array(44 + samples * 2);
    const view = new DataView(bytes.buffer);
    const write = (offset, text) => [...text].forEach((c, i) => view.setUint8(offset + i, c.charCodeAt(0)));
    write(0, 'RIFF'); view.setUint32(4, 36 + samples * 2, true); write(8, 'WAVEfmt ');
    view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
    view.setUint32(24, 8000, true); view.setUint32(28, 16000, true); view.setUint16(32, 2, true);
    view.setUint16(34, 16, true); write(36, 'data'); view.setUint32(40, samples * 2, true);
    let binary = ''; bytes.forEach(b => binary += String.fromCharCode(b));
    const audio = new Audio('data:audio/wav;base64,' + btoa(binary));
    audio.loop = true; audio.muted = false; audio.volume = 0.5;
    window.__probeAudio = audio;
    audio.play().catch(() => {});
    await new Promise(resolve => setTimeout(resolve, 300));
    return true;
    """

    private func probe(_ webView: WKWebView) async throws -> (muted: Bool, paused: Bool) {
        let result = try await webView.callAsyncJavaScript(
            "return [window.__probeAudio.muted, window.__probeAudio.paused];",
            contentWorld: .page
        ) as? [Bool]
        return (result![0], result![1])
    }

    private func update(_ webView: WKWebView, _ json: String) async throws {
        _ = try await webView.callAsyncJavaScript(
            "window.__liveWallpaperUpdate(\(json)); return true;", contentWorld: .page
        )
    }

    func testDetachedAudioStaysMutedWhileAudioIsOff() async throws {
        let (webView, _) = try await makeHost(audioEnabled: false)
        _ = try await webView.callAsyncJavaScript(startDetachedAudio, contentWorld: .page)
        let state = try await probe(webView)
        XCTAssertTrue(state.muted)
    }

    func testDetachedAudioFollowsTheAudioSetting() async throws {
        let (webView, _) = try await makeHost(audioEnabled: false)
        _ = try await webView.callAsyncJavaScript(startDetachedAudio, contentWorld: .page)
        try await update(webView, #"{"audioEnabled": true}"#)
        var state = try await probe(webView)
        XCTAssertFalse(state.muted)
        XCTAssertFalse(state.paused)
        try await update(webView, #"{"audioEnabled": false}"#)
        state = try await probe(webView)
        XCTAssertTrue(state.muted)
    }

    func testDetachedAudioPausesWhileTheWallpaperIsPaused() async throws {
        let (webView, _) = try await makeHost(audioEnabled: true)
        _ = try await webView.callAsyncJavaScript(startDetachedAudio, contentWorld: .page)
        try await update(webView, #"{"paused": true}"#)
        var state = try await probe(webView)
        XCTAssertTrue(state.paused)
        try await update(webView, #"{"paused": false}"#)
        state = try await probe(webView)
        XCTAssertFalse(state.paused)
    }
}

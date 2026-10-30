import AppKit
import Foundation
@testable import LiveWallpaper
import WebKit
import XCTest

@MainActor
final class LocalWebUserDirectoryTests: XCTestCase {
    private var directory: URL!
    private var package: URL!
    private var chosen: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalWebUserDirectoryTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        package = directory.appendingPathComponent("package")
        chosen = directory.appendingPathComponent("directory test 日本語 & space")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        try JSONEncoder().encode(LocalWebWallpaperPackage(entryPoint: "index.html"))
            .write(to: package.appendingPathComponent(LocalWebWallpaperPackage.fileName))
        try "<html><body></body></html>".write(
            to: package.appendingPathComponent("index.html"), atomically: true, encoding: .utf8
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testPagesSeeTheFolderInTheOriginalsWindowsForm() {
        XCTAssertEqual(LocalWebUserDirectory.pageValue(path: ""), "")
        XCTAssertEqual(LocalWebUserDirectory.pageValue(path: "/Users/me/a b/"), "Z:/Users/me/a b")
        XCTAssertEqual(
            LocalWebUserDirectory.pageFile(path: "/Users/me/directory test 日本語 & space/red space.png"),
            "Z%3A/Users/me/directory%20test%20日本語%20%26%20space/red%20space.png"
        )
    }

    func testListingKeepsTheFolderTypesFiles() throws {
        for name in ["red space.png", "anim.gif", "clip.webm", "notes.txt"] {
            try Data("x".utf8).write(to: chosen.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(
            at: chosen.appendingPathComponent("sub.png"), withIntermediateDirectories: true
        )
        func names(_ fileType: String?) throws -> Set<String> {
            let files = try LocalWebUserDirectory.listing(of: .init(path: chosen.path, fileType: fileType))
            return Set(files.keys.map { String($0.split(separator: "/").last!) })
        }
        XCTAssertEqual(try names("image"), ["red%20space.png", "anim.gif"])
        XCTAssertEqual(try names("video"), ["clip.webm"])
        XCTAssertEqual(try names(nil), ["red%20space.png", "anim.gif", "clip.webm", "notes.txt"])
    }

    func testServerReadsOnlyInsideTheChosenFolders() async throws {
        try png().write(to: chosen.appendingPathComponent("red space.png"))
        try Data("secret".utf8).write(to: directory.appendingPathComponent("secret.txt"))
        let server = LocalWebWallpaperServer()
        let page = try await server.url(folder: package)
        let token = page.pathComponents[1]
        func status(_ path: String) async throws -> Int {
            let url = URL(string: "http://127.0.0.1:\(page.port!)/\(token)/_userdir")!
                .appendingPathComponent(path)
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as! HTTPURLResponse).statusCode
        }
        let file = chosen.appendingPathComponent("red space.png").path
        let before = try await status(file)
        XCTAssertEqual(before, 404, "no folder chosen yet")
        server.setUserFolders([chosen], folder: package)
        try await Task.sleep(nanoseconds: 50_000_000)
        let inside = try await status(file)
        let outside = try await status(directory.appendingPathComponent("secret.txt").path)
        let escaping = try await status(chosen.path + "/../secret.txt")
        XCTAssertEqual([inside, outside, escaping], [200, 404, 404])
    }

    private final class Navigation: NSObject, WKNavigationDelegate {
        var onFinish: (() -> Void)?
        func webView(_: WKWebView, didFinish _: WKNavigation!) { onFinish?() }
    }

    func testPageLoadsListedFilesAndHearsListingChanges() async throws {
        try png().write(to: chosen.appendingPathComponent("red space.png"))
        let server = LocalWebWallpaperServer()
        server.setUserFolders([chosen], folder: package)
        let page = try await server.url(folder: package)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: LocalWebHostScript.bootstrap(state: .init(
                paused: false, audioEnabled: false, volume: 1, fps: 60, language: "en"
            )),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 100, height: 100), configuration: configuration)
        let navigation = Navigation()
        webView.navigationDelegate = navigation
        let loaded = expectation(description: "page loaded")
        navigation.onFinish = { loaded.fulfill() }
        webView.load(URLRequest(url: page))
        await fulfillment(of: [loaded], timeout: 15)

        let file = LocalWebUserDirectory.pageFile(path: chosen.appendingPathComponent("red space.png").path)
        let result = try await webView.callAsyncJavaScript("""
        const events = [];
        window.addEventListener('livewallpaper:directory', event => events.push(event.detail));
        window.__liveWallpaperSetDirectory('image_dir', [[file, 1]]);
        window.__liveWallpaperSetDirectory('image_dir', [[file, 1]]);
        window.__liveWallpaperSetDirectory('image_dir', [[file, 2]]);
        window.__liveWallpaperSetDirectory('image_dir', []);
        const image = new Image();
        const source = 'file:///' + file;
        await new Promise((resolve, reject) => { image.onload = resolve; image.onerror = reject; image.src = source; });
        const fetched = await fetch(source);
        return {
            events: JSON.stringify(events),
            width: image.naturalWidth,
            readBack: image.src === source && image.getAttribute('src') === source,
            fetched: fetched.status
        };
        """, arguments: ["file": file], contentWorld: .page) as? [String: Any]
        XCTAssertEqual(
            result?["events"] as? String,
            #"[{"property":"image_dir","added":["\#(file)"],"removed":[]},"#
                + #"{"property":"image_dir","added":["\#(file)"],"removed":[]},"#
                + #"{"property":"image_dir","added":[],"removed":["\#(file)"]}]"#
        )
        XCTAssertEqual(result?["width"] as? Int, 4)
        XCTAssertEqual(result?["readBack"] as? Bool, true)
        XCTAssertEqual(result?["fetched"] as? Int, 200)
    }
}

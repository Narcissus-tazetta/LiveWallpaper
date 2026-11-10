import AppKit
import AVFoundation
@testable import LiveWallpaper
import XCTest

@MainActor
final class SceneShareSettingsTests: XCTestCase {
    func testLooseAndPackagedVideosUseSavedSceneSettings() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let video = root.appendingPathComponent("source.mp4")
        try Data("old video".utf8).write(to: video)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let imageFile = try SceneStore.writeImage(
            XCTUnwrap(context.makeImage()), prefix: "layer", videoPath: video.path
        )
        let layer = SceneLayer(name: "red", imageFile: imageFile)
        var document = SceneDocument(
            canvasWidth: 64, canvasHeight: 48, layers: [layer],
            properties: [.init(
                id: "opacity", kind: "slider", label: ["default": "Opacity"], value: .number(1)
            )]
        )
        var script = SceneScript(
            source: "function update(c){return [{id:c.targets[0].id,values:{opacity:c.userProperties.opacity}}]}",
            layerIDs: [layer.id]
        )
        script.usesTime = false
        script.isAuthorized = true
        document.scripts = [script]
        SceneScriptPermissions.authorizeAll(document, path: video.path)
        try SceneStore.save(document, videoPath: video.path)
        try SceneStore.markVideoOutOfDate(videoPath: video.path)
        XCTAssertTrue(SceneStore.isNewerThanVideo(videoPath: video.path))
        let model = WallpaperModel()
        model.registerImportedScene(document, path: video.path)
        let key = "authorSettings.scene." + video.standardizedFileURL.path
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let settings = LocalWebSettings(values: ["opacity": .number(0.2)])
        try settings.save(key: key)
        let expected = root.appendingPathComponent("expected.mp4")
        try await SceneVideoBaker.bake(
            document: document, videoPath: video.path, userProperties: settings.values,
            quality: BakeQuality.maximum.compressionQuality, to: expected
        ) { _ in }
        let expectedRed = try meanRed(of: expected)
        XCTAssertLessThan(expectedRed, 100)
        for includePackage in [false, true] {
            let output = root.appendingPathComponent(UUID().uuidString)
            try files.createDirectory(at: output, withIntermediateDirectories: true)
            let urls = try await PackageExporter().exportSingleWallpaper(
                model: model, videoPath: video.path, outputFolderURL: output,
                includePackage: includePackage
            )
            XCTAssertEqual(try meanRed(of: XCTUnwrap(urls.first)), expectedRed, accuracy: 2)
            if includePackage {
                let unpacked = output.appendingPathComponent("unpacked")
                try await ProcessRunner.run(
                    "/usr/bin/unzip", arguments: ["-q", urls[1].path, "-d", unpacked.path]
                )
                let content = unpacked.appendingPathComponent("content")
                let manifest = try JSONDecoder().decode(
                    PackageManifest.self,
                    from: Data(contentsOf: content.appendingPathComponent("metadata.json"))
                )
                let id = try XCTUnwrap(manifest.videos.first?.id)
                XCTAssertEqual(
                    try meanRed(of: content.appendingPathComponent("videos/\(id).mp4")),
                    expectedRed, accuracy: 2
                )
            }
        }
    }

    private func meanRed(of video: URL) throws -> Double {
        let image = try XCTUnwrap(VideoFrameCapture.capture(path: video.path, time: .zero))
        var pixels = [UInt8](repeating: 0, count: 64 * 48 * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 48))
        return stride(from: 0, to: pixels.count, by: 4)
            .reduce(0.0) { $0 + Double(pixels[$1]) } / Double(64 * 48)
    }
}

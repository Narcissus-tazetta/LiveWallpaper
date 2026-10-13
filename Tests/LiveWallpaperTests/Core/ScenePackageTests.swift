import CoreGraphics
import ImageIO
import XCTest

@testable import LiveWallpaper

/// Scenes travel inside packages from anyone, so the import only takes the plain
/// files that scene.json names.
final class ScenePackageTests: XCTestCase {
    private var workingDirectory: URL!

    override func setUpWithError() throws {
        workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScenePackageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: workingDirectory)
    }

    private func makeScene(at videoPath: String) throws -> SceneDocument {
        let context = CGContext(
            data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        let image = workingDirectory.appendingPathComponent("red.png")
        let destination = CGImageDestinationCreateWithURL(image as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        var (layer, _) = try SceneStore.importImage(at: image, videoPath: videoPath)
        var effect = SceneEffect(kind: .waves)
        effect.maskFile = try SceneStore.writePaintImage(
            [UInt8](repeating: 255, count: 16), width: 4, height: 4, target: .mask, videoPath: videoPath
        )
        layer.effects = [effect]
        let document = SceneDocument(
            canvasWidth: 64, canvasHeight: 40,
            layers: [layer, SceneLayer(name: "snow", particles: SceneParticles(preset: .snow))]
        )
        try SceneStore.save(document, videoPath: videoPath)
        return document
    }

    func testPackagedSceneComesBackWhole() throws {
        let original = workingDirectory.appendingPathComponent("a.mp4").path
        let document = try makeScene(at: original)
        let packaged = workingDirectory.appendingPathComponent("package/scenes/id", isDirectory: true)
        try SceneStore.copyScene(videoPath: original, to: packaged)

        let imported = workingDirectory.appendingPathComponent("b.mp4").path
        let restored = try SceneStore.importScene(from: packaged, videoPath: imported)

        XCTAssertEqual(restored, document)
        for name in SceneStore.referencedFiles(of: restored) {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: SceneStore.folderURL(forVideoPath: imported).appendingPathComponent(name).path
            ))
        }
    }

    func testImportRejectsNamesOutsideTheSceneFolder() throws {
        let original = workingDirectory.appendingPathComponent("a.mp4").path
        var document = try makeScene(at: original)
        let packaged = workingDirectory.appendingPathComponent("package/scenes/id", isDirectory: true)
        try SceneStore.copyScene(videoPath: original, to: packaged)
        document.layers[0].imageFile = "../../secret.png"
        try JSONEncoder().encode(document).write(to: packaged.appendingPathComponent("scene.json"))

        let imported = workingDirectory.appendingPathComponent("b.mp4").path
        XCTAssertThrowsError(try SceneStore.importScene(from: packaged, videoPath: imported))
        XCTAssertFalse(FileManager.default.fileExists(atPath: SceneStore.folderURL(forVideoPath: imported).path))
    }

    /// A copy that fails part way must leave the scene that was there, not a scene.json
    /// whose images are missing.
    func testFailedImportKeepsTheExistingScene() throws {
        let original = workingDirectory.appendingPathComponent("a.mp4").path
        let document = try makeScene(at: original)
        let packaged = workingDirectory.appendingPathComponent("package/scenes/id", isDirectory: true)
        try SceneStore.copyScene(videoPath: original, to: packaged)
        let imported = workingDirectory.appendingPathComponent("b.mp4").path
        let existing = try SceneStore.importScene(from: packaged, videoPath: imported)

        let unreadable = packaged.appendingPathComponent(document.layers[0].imageFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path)
        }
        XCTAssertThrowsError(try SceneStore.importScene(from: packaged, videoPath: imported))

        XCTAssertEqual(try SceneStore.load(videoPath: imported), existing)
        for name in SceneStore.referencedFiles(of: existing) {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: SceneStore.folderURL(forVideoPath: imported).appendingPathComponent(name).path
            ))
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: workingDirectory.path)
            .filter { $0.hasSuffix(".import") }
        XCTAssertEqual(leftovers, [])
    }

    /// The baker writes loopSeconds × 60 frames, so a package cannot ask for more than
    /// the editor offers.
    func testLoopLengthFromAPackageIsCapped() throws {
        let json = #"{"canvasWidth":64,"canvasHeight":40,"layers":[],"loopSeconds":9223372036854775807}"#
        let document = try JSONDecoder().decode(SceneDocument.self, from: Data(json.utf8))
        XCTAssertEqual(document.loopSeconds, SceneDocument.loopSecondsChoices.max())
    }
}

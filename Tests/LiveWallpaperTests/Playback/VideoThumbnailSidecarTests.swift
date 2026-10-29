import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LiveWallpaper

final class VideoThumbnailSidecarTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() async throws {
        let unique = UUID().uuidString
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoThumbnailSidecarTests-\(unique)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    // MARK: - Sidecar URL Resolution

    func testSidecarURLMatching() throws {
        let videoURL = tempDirectory.appendingPathComponent("my-video.mp4")
        try Data("dummy-video".utf8).write(to: videoURL)

        // 1. When no sidecar exists, returns nil
        XCTAssertNil(VideoThumbnailGenerator.sidecarURL(for: videoURL.path))

        // 2. Generic "preview.jpg" in the same folder must NOT match (avoids flat Videos/ hijacking)
        let genericPreview = tempDirectory.appendingPathComponent("preview.jpg")
        try Data("dummy-generic".utf8).write(to: genericPreview)
        XCTAssertNil(VideoThumbnailGenerator.sidecarURL(for: videoURL.path))

        // 3. Different stem sidecar must NOT match
        let otherPreview = tempDirectory.appendingPathComponent("other-video.preview.jpg")
        try Data("dummy-other".utf8).write(to: otherPreview)
        XCTAssertNil(VideoThumbnailGenerator.sidecarURL(for: videoURL.path))

        // 4. Exact stem match "<videoStem>.preview.jpg" matches
        let expectedURL = VideoThumbnailGenerator.expectedSidecarURL(for: videoURL.path)
        XCTAssertEqual(expectedURL.path, tempDirectory.appendingPathComponent("my-video.preview.jpg").path)
        try Data("dummy-exact".utf8).write(to: expectedURL)
        XCTAssertEqual(VideoThumbnailGenerator.sidecarURL(for: videoURL.path)?.path, expectedURL.path)
    }

    // MARK: - Normalization and ImageIO

    func testSaveNormalizedPreviewStaticImage() throws {
        let sourceURL = tempDirectory.appendingPathComponent("source.png")
        let destinationURL = tempDirectory.appendingPathComponent("output.preview.jpg")

        let sourceImage = createSolidImage(color: .blue, size: CGSize(width: 800, height: 600))
        guard let tiff = sourceImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            XCTFail("Failed to encode test PNG")
            return
        }
        try pngData.write(to: sourceURL)

        let success = VideoThumbnailGenerator.saveNormalizedPreview(from: sourceURL, to: destinationURL)
        XCTAssertTrue(success)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))

        guard let outputImage = NSImage(contentsOf: destinationURL) else {
            XCTFail("Failed to load normalized JPEG")
            return
        }
        guard let rep = outputImage.representations.first else {
            XCTFail("Missing image representation")
            return
        }
        XCTAssertLessThanOrEqual(rep.pixelsWide, 480)
        XCTAssertLessThanOrEqual(rep.pixelsHigh, 480)

        // Verify color preserved
        let color = pixelColor(of: outputImage)
        XCTAssertGreaterThan(color.blueComponent, 0.7)
        XCTAssertLessThan(color.redComponent, 0.3)
    }

    func testSaveNormalizedPreviewAnimatedGIFChoosesBrightestFrame() throws {
        let sourceURL = tempDirectory.appendingPathComponent("animated.gif")
        let destinationURL = tempDirectory.appendingPathComponent("animated.preview.jpg")

        // 3 frames: 0: Black (fade-in), 1: Red (the only visible frame), 2: Black (fade-out)
        guard let gifData = createMultiFrameGIF(colors: [.black, .red, .black], size: CGSize(width: 200, height: 200)) else {
            XCTFail("Failed to build multi-frame test GIF")
            return
        }
        try gifData.write(to: sourceURL)

        let success = VideoThumbnailGenerator.saveNormalizedPreview(from: sourceURL, to: destinationURL)
        XCTAssertTrue(success)

        guard let outputImage = NSImage(contentsOf: destinationURL) else {
            XCTFail("Failed to load output image")
            return
        }

        // Red is the brightest frame, confirming both black fades were skipped
        let color = pixelColor(of: outputImage)
        XCTAssertGreaterThan(color.redComponent, 0.7, "Expected the brightest frame to be red, but got: \(color)")
        XCTAssertLessThan(color.greenComponent, 0.3)
        XCTAssertLessThan(color.blueComponent, 0.3)
    }

    func testSaveNormalizedPreviewInvalidSourceFailsGracefully() {
        let invalidURL = tempDirectory.appendingPathComponent("corrupted.dat")
        try? Data("not-an-image".utf8).write(to: invalidURL)
        let destinationURL = tempDirectory.appendingPathComponent("dest.jpg")

        let success = VideoThumbnailGenerator.saveNormalizedPreview(from: invalidURL, to: destinationURL)
        XCTAssertFalse(success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    // MARK: - Direct Sidecar Fast-path in Generator

    func testGenerateBestThumbnailUsesSidecarDirectly() async throws {
        let videoURL = tempDirectory.appendingPathComponent("test-fastpath.mp4")
        try Data("fake-video-bytes".utf8).write(to: videoURL)

        // Put a sidecar image beside the video
        let sidecarURL = VideoThumbnailGenerator.expectedSidecarURL(for: videoURL.path)
        let greenImage = createSolidImage(color: .green, size: CGSize(width: 100, height: 100))
        guard let tiff = greenImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpgData = bitmap.representation(using: .jpeg, properties: [:])
        else {
            XCTFail("Failed to make JPEG")
            return
        }
        try jpgData.write(to: sidecarURL)

        let loaded = await VideoThumbnailGenerator.generateBestThumbnail(path: videoURL.path)
        XCTAssertNotNil(loaded)
        if let loaded {
            let color = pixelColor(of: loaded)
            XCTAssertGreaterThan(color.greenComponent, 0.7)
        }
    }

    // MARK: - Cache Invalidation (mtime comparison)

    func testDiskThumbnailCacheInvalidatesWhenSidecarIsNewer() throws {
        let sourceURL = tempDirectory.appendingPathComponent("cache-check.mp4")
        try Data("video-content".utf8).write(to: sourceURL)

        let cacheFileURL = tempDirectory.appendingPathComponent("cached.jpg")
        let cachedImage = createSolidImage(color: .yellow, size: CGSize(width: 100, height: 100))
        guard let tiff = cachedImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpgData = bitmap.representation(using: .jpeg, properties: [:])
        else {
            XCTFail("Failed to make JPEG")
            return
        }
        try jpgData.write(to: cacheFileURL)

        let sourceAttrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let sourceSize = (sourceAttrs[.size] as! NSNumber).uint64Value
        let sourceMtime = (sourceAttrs[.modificationDate] as! Date).timeIntervalSince1970

        let entry = DiskThumbnailCache.Entry(
            fileName: cacheFileURL.lastPathComponent,
            sourcePath: sourceURL.path,
            sourceSize: sourceSize,
            sourceModifiedAt: sourceMtime,
            lastAccessAt: Date().timeIntervalSince1970
        )

        // 1. Without sidecar, cache is valid
        let resultWithoutSidecar = DiskThumbnailCache.loadThumbnailData(
            sourcePath: sourceURL.path,
            entry: entry,
            fileURL: cacheFileURL
        )
        if case .data(let data) = resultWithoutSidecar {
            XCTAssertFalse(data.isEmpty)
        } else {
            XCTFail("Expected .data, got \(resultWithoutSidecar)")
        }

        // 2. Create sidecar with mtime strictly NEWER than cache file
        let sidecarURL = VideoThumbnailGenerator.expectedSidecarURL(for: sourceURL.path)
        try jpgData.write(to: sidecarURL)

        let oldCacheDate = Date(timeIntervalSince1970: 1000)
        let newerSidecarDate = Date(timeIntervalSince1970: 2000)
        try FileManager.default.setAttributes([.modificationDate: oldCacheDate], ofItemAtPath: cacheFileURL.path)
        try FileManager.default.setAttributes([.modificationDate: newerSidecarDate], ofItemAtPath: sidecarURL.path)

        let resultWithNewerSidecar = DiskThumbnailCache.loadThumbnailData(
            sourcePath: sourceURL.path,
            entry: entry,
            fileURL: cacheFileURL
        )
        if case .invalidSource = resultWithNewerSidecar {
            // Success: old cache recognized as invalid
        } else {
            XCTFail("Expected .invalidSource when cacheMtime < sidecarMtime, got \(resultWithNewerSidecar)")
        }

        // 3. Update cache mtime to be NEWER than sidecar
        let freshestCacheDate = Date(timeIntervalSince1970: 3000)
        try FileManager.default.setAttributes([.modificationDate: freshestCacheDate], ofItemAtPath: cacheFileURL.path)

        let resultWithFreshCache = DiskThumbnailCache.loadThumbnailData(
            sourcePath: sourceURL.path,
            entry: entry,
            fileURL: cacheFileURL
        )
        if case .data = resultWithFreshCache {
            // Success: cache is up-to-date
        } else {
            XCTFail("Expected .data when cacheMtime >= sidecarMtime, got \(resultWithFreshCache)")
        }
    }

    // MARK: - Reconcile and Backfill

    func testPerformReconcileImportedThumbnails() throws {
        let appSupport = tempDirectory.appendingPathComponent("AppSupport", isDirectory: true)
        let weWallpapers = appSupport.appendingPathComponent("we-import/Wallpapers/we-789", isDirectory: true)
        try FileManager.default.createDirectory(at: weWallpapers, withIntermediateDirectories: true)

        let sourcePreview = weWallpapers.appendingPathComponent("preview.jpg")
        let magentaImage = createSolidImage(color: .magenta, size: CGSize(width: 200, height: 200))
        guard let tiff = magentaImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpgData = bitmap.representation(using: .jpeg, properties: [:])
        else {
            XCTFail("Failed to make JPEG")
            return
        }
        try jpgData.write(to: sourcePreview)

        let videoURL = tempDirectory.appendingPathComponent("wallpaper-test.mp4")
        try Data("video-data".utf8).write(to: videoURL)

        let imported: [String: String] = [
            "we-789": videoURL.path
        ]

        // Reconcile with ExternalWallpaper provided
        let external = ExternalWallpaper(
            id: "we-789",
            providerName: "WE",
            name: "Test",
            path: videoURL.path,
            thumbnailPath: sourcePreview.path,
            providerPID: 100
        )

        WallpaperModel.performReconcileImportedThumbnails(
            imported: imported,
            externalWallpapers: [external]
        )

        let expectedSidecar = VideoThumbnailGenerator.expectedSidecarURL(for: videoURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedSidecar.path))

        guard let loadedSidecar = NSImage(contentsOf: expectedSidecar) else {
            XCTFail("Failed to load generated sidecar")
            return
        }
        let color = pixelColor(of: loadedSidecar)
        XCTAssertGreaterThan(color.redComponent, 0.7)
        XCTAssertGreaterThan(color.blueComponent, 0.7)
    }

    // MARK: - Helpers

    private func createSolidImage(color: NSColor, size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    private func createMultiFrameGIF(colors: [NSColor], size: CGSize) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.gif.identifier as CFString,
            colors.count,
            nil
        ) else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        for color in colors {
            guard let ctx = CGContext(
                data: nil,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: Int(size.width) * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return nil
            }
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            guard let image = ctx.makeImage() else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func pixelColor(of image: NSImage) -> (redComponent: CGFloat, greenComponent: CGFloat, blueComponent: CGFloat) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return (0, 0, 0)
        }
        let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2) ?? .black
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        let converted = color.usingColorSpace(.deviceRGB) ?? color
        converted.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue)
    }
}

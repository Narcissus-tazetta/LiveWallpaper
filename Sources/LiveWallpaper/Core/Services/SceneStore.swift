import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where a scene lives: `wallpaper-<id>.scene/` next to its baked `wallpaper-<id>.mp4`,
/// holding `scene.json` and the layer images. Keeping the folder beside the video
/// makes the video path the scene's identity, so playlists, schedules, per-display
/// assignments and the rest keep working on scenes unchanged.
enum SceneStore {
    enum StoreError: LocalizedError {
        case unreadableImage(String)

        var errorDescription: String? {
            switch self {
            case let .unreadableImage(name):
                return String(format: NSLocalizedString("画像を読み込めませんでした: %@", comment: ""), name)
            }
        }
    }

    private static let documentFileName = "scene.json"

    static func folderURL(forVideoPath path: String) -> URL {
        URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("scene")
    }

    static func hasScene(videoPath: String) -> Bool {
        FileManager.default.fileExists(
            atPath: folderURL(forVideoPath: videoPath).appendingPathComponent(documentFileName).path
        )
    }

    /// nil when the video has no scene. A scene that exists but cannot be read throws.
    static func load(videoPath: String) throws -> SceneDocument? {
        let url = folderURL(forVideoPath: videoPath).appendingPathComponent(documentFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try JSONDecoder().decode(SceneDocument.self, from: Data(contentsOf: url))
    }

    /// The scene was saved after its video was last written.
    /// Dates scene.json after the video, so the video counts as out of date
    /// (isNewerThanVideo) until a real bake, across launches and library imports.
    static func markVideoOutOfDate(videoPath: String) throws {
        let videoDate = try FileManager.default.attributesOfItem(atPath: videoPath)[.modificationDate] as? Date ?? Date()
        try FileManager.default.setAttributes(
            [.modificationDate: videoDate.addingTimeInterval(1)],
            ofItemAtPath: folderURL(forVideoPath: videoPath).appendingPathComponent(documentFileName).path
        )
    }

    static func isNewerThanVideo(videoPath: String) -> Bool {
        let scene = folderURL(forVideoPath: videoPath).appendingPathComponent(documentFileName)
        do {
            let sceneDate = try FileManager.default.attributesOfItem(atPath: scene.path)[.modificationDate] as? Date
            let videoDate = try FileManager.default.attributesOfItem(atPath: videoPath)[.modificationDate] as? Date
            guard let sceneDate, let videoDate else {
                return false
            }
            // Setting a date (importScene) rounds it to the microsecond, which can land
            // just after the date copied; a real edit comes far later than that.
            return sceneDate.timeIntervalSince(videoDate) > 0.001
        } catch {
            AppLog.windowRefresh.error("scene date check failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func save(_ document: SceneDocument, videoPath: String) throws {
        try write(encode(document), videoPath: videoPath)
    }

    static func encode(_ document: SceneDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    /// Writes data from encode(_:) as the scene's scene.json, atomically. The partial
    /// file has a dot name: pruning on the main thread skips those, while it would
    /// delete the unnamed temporary file of `Data.write(options: .atomic)` mid-write.
    static func write(_ data: Data, videoPath: String) throws {
        let folder = folderURL(forVideoPath: videoPath)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent(".\(documentFileName).\(UUID().uuidString)")
        do {
            try data.write(to: partial)
            if rename(partial.path, folder.appendingPathComponent(documentFileName).path) != 0 {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSFilePathErrorKey: partial.path,
                    NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                ])
            }
        } catch {
            if FileManager.default.fileExists(atPath: partial.path) {
                do {
                    try FileManager.default.removeItem(at: partial)
                } catch let cleanupError {
                    AppLog.persistence.error(
                        "scene write cleanup failed: \(cleanupError.localizedDescription, privacy: .public)"
                    )
                }
            }
            throw error
        }
    }

    /// Copies the image into the scene folder and returns a layer for it plus the
    /// image's displayed size (EXIF orientation applied).
    static func importImage(at originalURL: URL, videoPath: String) throws -> (SceneLayer, CGSize) {
        // Copy what a symbolic link points at, not the link.
        let sourceURL = originalURL.resolvingSymlinksInPath()
        let size = try pixelSize(of: sourceURL)
        let folder = folderURL(forVideoPath: videoPath)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = sourceURL.deletingPathExtension().lastPathComponent
        // Renderers never use more than maxTextureEdge, and every renderer decodes the
        // file again: a 16000 px PNG took ~1.8 s per renderer, 4096 px a fraction.
        if max(size.width, size.height) > CGFloat(SceneRenderer.maxTextureEdge) {
            let (fileName, storedSize) = try writeDownscaled(sourceURL, maxEdge: SceneRenderer.maxTextureEdge, folder: folder)
            return (SceneLayer(name: name, imageFile: fileName), storedSize)
        }
        let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension.lowercased()
        let fileName = "layer-\(UUID().uuidString).\(ext)"
        try FileManager.default.copyItem(at: sourceURL, to: folder.appendingPathComponent(fileName))
        return (SceneLayer(name: name, imageFile: fileName), size)
    }

    /// Writes the image at most `maxEdge` on its long side, EXIF orientation applied.
    /// Images with transparency stay PNG; opaque ones become JPEG, which decodes fastest.
    private static func writeDownscaled(_ url: URL, maxEdge: Int, folder: URL) throws -> (String, CGSize) {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            throw StoreError.unreadableImage(url.lastPathComponent)
        }
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let fileName = "layer-\(UUID().uuidString).\(hasAlpha ? "png" : "jpg")"
        let type = (hasAlpha ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(
            folder.appendingPathComponent(fileName) as CFURL, type, 1, nil
        ) else {
            throw StoreError.unreadableImage(fileName)
        }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw StoreError.unreadableImage(fileName)
        }
        return (fileName, CGSize(width: image.width, height: image.height))
    }

    /// Saves a painted mask (1 byte per pixel) or flow map (RGBA) as a new file and
    /// returns its name. A new name each time keeps renderers from reusing a stale
    /// texture cached under the old one.
    static func writePaintImage(
        _ bytes: [UInt8],
        width: Int,
        height: Int,
        target: ScenePaintOverride.Target,
        videoPath: String
    ) throws -> String {
        let isMask = target.isGrey
        let fileName = "\(isMask ? "mask" : "flow")-\(UUID().uuidString).png"
        let url = folderURL(forVideoPath: videoPath).appendingPathComponent(fileName)
        let bytesPerPixel = isMask ? 1 : 4
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * bytesPerPixel,
                  bytesPerRow: width * bytesPerPixel,
                  space: CGColorSpace(name: isMask ? CGColorSpace.linearGray : CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: (isMask ? CGImageAlphaInfo.none : .noneSkipLast).rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else {
            throw StoreError.unreadableImage(fileName)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw StoreError.unreadableImage(fileName)
        }
        return fileName
    }

    /// Reads a painted file back at `width`×`height` in the layout writePaintImage uses.
    static func readPaintImage(
        _ fileName: String,
        width: Int,
        height: Int,
        target: ScenePaintOverride.Target,
        videoPath: String
    ) throws -> [UInt8] {
        let url = folderURL(forVideoPath: videoPath).appendingPathComponent(fileName)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw StoreError.unreadableImage(fileName)
        }
        let isMask = target.isGrey
        let bytesPerPixel = isMask ? 1 : 4
        var bytes = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let drew: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * bytesPerPixel,
                space: CGColorSpace(name: isMask ? CGColorSpace.linearGray : CGColorSpace.sRGB)!,
                bitmapInfo: (isMask ? CGImageAlphaInfo.none : .noneSkipLast).rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else {
            throw StoreError.unreadableImage(fileName)
        }
        return bytes
    }

    /// Saves a generated image (a cut-out, a filled background, a depth map) and
    /// returns its new file name.
    static func writeImage(_ image: CGImage, prefix: String, videoPath: String) throws -> String {
        let fileName = "\(prefix)-\(UUID().uuidString).png"
        let folder = folderURL(forVideoPath: videoPath)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(
            folder.appendingPathComponent(fileName) as CFURL, "public.png" as CFString, 1, nil
        ) else {
            throw StoreError.unreadableImage(fileName)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw StoreError.unreadableImage(fileName)
        }
        return fileName
    }

    /// Every file a scene reads, besides scene.json.
    static func referencedFiles(of document: SceneDocument) -> Set<String> {
        var files = Set<String>()
        for sound in document.sounds { files.formUnion(sound.files) }
        for material in (document.meshMaterials ?? []).compactMap({ $0 }) {
            files.formUnion(material.images.values.filter { SceneModelRenderer.layerObjectID($0) == nil })
        }
        for layer in document.layers {
            if layer.kind == .image {
                files.insert(layer.imageFile)
            }
            files.formUnion([layer.particles?.maskFile, layer.depthFile, layer.text?.fontFile, layer.videoFile].compactMap { $0 })
            if let graph = layer.renderGraph { files.formUnion(graph.images.values) }
            files.formUnion(layer.particleSystem?.textureFiles ?? [])
            for effect in layer.effects {
                if let graph = effect.renderGraph { files.formUnion(graph.images.values) }
                files.formUnion([effect.maskFile, effect.flowFile, effect.timeOffsetFile, effect.patternFile].compactMap { $0 })
            }
        }
        return files
    }

    /// Copies the scene of `videoPath` into `destination` (scene.json and the files it
    /// uses only).
    static func copyScene(videoPath: String, to destination: URL) throws {
        guard let document = try load(videoPath: videoPath) else {
            return
        }
        let folder = folderURL(forVideoPath: videoPath)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in referencedFiles(of: document).union([documentFileName]) {
            try FileManager.default.copyItem(
                at: folder.appendingPathComponent(name), to: destination.appendingPathComponent(name)
            )
        }
        let propURL = folder.appendingPathComponent("properties.json")
        if FileManager.default.fileExists(atPath: propURL.path) {
            try FileManager.default.copyItem(at: propURL, to: destination.appendingPathComponent("properties.json"))
        }
    }

    enum ImportError: LocalizedError {
        case unsafeFile(String)

        var errorDescription: String? {
            switch self {
            case let .unsafeFile(name):
                return String(format: NSLocalizedString("パッケージに不正なファイル参照が含まれています: %@", comment: ""), name)
            }
        }
    }

    /// Installs a scene from an unpacked package next to the imported video. The
    /// package comes from anyone: only plain files that scene.json names, with plain
    /// names, are copied.
    static func importScene(from source: URL, videoPath: String, videoIsOutOfDate: Bool = false) throws -> SceneDocument {
        let documentURL = source.appendingPathComponent(documentFileName)
        let document = try JSONDecoder().decode(SceneDocument.self, from: Data(contentsOf: documentURL))
        let root = source.resolvingSymlinksInPath().standardizedFileURL.path
        var names = referencedFiles(of: document).union([documentFileName])
        if FileManager.default.fileExists(atPath: source.appendingPathComponent("properties.json").path) {
            names.insert("properties.json")
        }
        for name in names {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                  !name.contains("\0")
            else {
                throw ImportError.unsafeFile(name)
            }
            let url = source.appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root + "/")
            else {
                throw ImportError.unsafeFile(name)
            }
        }
        // Staged beside the destination and swapped in whole: a copy that fails half way
        // must not leave a scene.json whose images are missing (restoreScenes loads it).
        let destination = folderURL(forVideoPath: videoPath)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).import")
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            for name in names {
                try FileManager.default.copyItem(
                    at: source.appendingPathComponent(name), to: staging.appendingPathComponent(name)
                )
            }
            // The video imported beside it already shows this scene. Dated like it,
            // scene.json only becomes newer than the video (isNewerThanVideo) once edited.
            // A scene installed before its first bake has no video yet.
            if FileManager.default.fileExists(atPath: videoPath),
               let videoDate = try FileManager.default.attributesOfItem(atPath: videoPath)[.modificationDate] as? Date
            {
                // A video that is only a stand-in (videoIsOutOfDate) stays out of date.
                try FileManager.default.setAttributes(
                    [.modificationDate: videoIsOutOfDate ? videoDate.addingTimeInterval(1) : videoDate],
                    ofItemAtPath: staging.appendingPathComponent(documentFileName).path
                )
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        } catch {
            if FileManager.default.fileExists(atPath: staging.path) {
                do {
                    try FileManager.default.removeItem(at: staging)
                } catch let cleanupError {
                    AppLog.persistence.error(
                        "scene import cleanup failed: \(cleanupError.localizedDescription, privacy: .public)"
                    )
                }
            }
            throw error
        }
        return document
    }

    static func removeImage(_ fileName: String, videoPath: String) throws {
        let url = folderURL(forVideoPath: videoPath).appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }

    static func imageURL(_ layer: SceneLayer, videoPath: String) -> URL {
        folderURL(forVideoPath: videoPath).appendingPathComponent(layer.imageFile)
    }

    /// A single-frame image becomes a scene; animated ones keep going through
    /// AnimatedImageTranscoder.
    static func isStillImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else {
            return false
        }
        return CGImageSourceGetCount(source) == 1
    }

    static func pixelSize(of url: URL) throws -> CGSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else {
            throw StoreError.unreadableImage(url.lastPathComponent)
        }
        // Orientations 5–8 are rotated by 90°.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }
}

import Accelerate
import CoreGraphics
import CoreML
import CryptoKit
import Foundation
import ImageIO
import Vision

/// On-device image analysis for scenes: splitting a subject from its background,
/// and estimating depth for the depth parallax.
enum SceneAI {
    enum AIError: LocalizedError {
        case unreadableImage(String)
        case noSubject
        case unsupportedOS
        case downloadFailed(String)
        case modelCorrupted(String)
        case noDepthOutput

        var errorDescription: String? {
            switch self {
            case let .unreadableImage(name):
                return String(format: NSLocalizedString("画像を読み込めませんでした: %@", comment: ""), name)
            case .noSubject:
                return NSLocalizedString("切り抜ける被写体が見つかりませんでした。", comment: "")
            case .unsupportedOS:
                return NSLocalizedString("被写体の切り抜きは macOS 14 以降で使えます。", comment: "")
            case let .downloadFailed(message):
                return String(format: NSLocalizedString("奥行きを推定するモデルをダウンロードできませんでした: %@", comment: ""), message)
            case let .modelCorrupted(name):
                return String(format: NSLocalizedString("ダウンロードしたモデルが壊れています: %@", comment: ""), name)
            case .noDepthOutput:
                return NSLocalizedString("奥行きを推定できませんでした。", comment: "")
            }
        }
    }

    /// Longest edge analysed and written; matches what the renderer decodes.
    static let maxEdge = 4096
    /// Depth and the hole fill are smooth, so they are worked out at this size.
    private static let smoothEdge = 1024

    // MARK: - Foreground

    struct Separation {
        /// RGBA, straight alpha: the subject cut out.
        let foreground: CGImage
        /// The original with the subject's place filled in from its surroundings.
        let background: CGImage
    }

    static var canSeparateForeground: Bool {
        if #available(macOS 14, *) {
            return true
        }
        return false
    }

    static func separateForeground(imageURL: URL) throws -> Separation {
        guard #available(macOS 14, *) else {
            throw AIError.unsupportedOS
        }
        let image = try decode(imageURL, maxEdge: maxEdge)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw AIError.noSubject
        }
        let maskBuffer = try observation.generateScaledMaskForImage(
            forInstances: observation.allInstances, from: handler
        )
        let width = image.width
        let height = image.height
        let mask = readFloatPlane(maskBuffer, width: width, height: height)
        var pixels = rgba(of: image)

        // Foreground: the original colours with the mask as alpha.
        var foreground = pixels
        for index in 0 ..< width * height {
            foreground[index * 4 + 3] = UInt8((min(max(mask[index], 0), 1) * 255).rounded())
        }

        // Background: grow the hole a little so the subject's edge does not linger,
        // then fill it from the surroundings.
        let grow = max(Int(Double(max(width, height)) * 0.012), 2)
        let hole = dilate(mask.map { $0 > 0.2 ? 1 : 0 }, width: width, height: height, radius: grow)
        fillHoles(&pixels, hole: hole, width: width, height: height)

        return try Separation(
            foreground: makeImage(foreground, width: width, height: height, alpha: .last),
            background: makeImage(pixels, width: width, height: height, alpha: .noneSkipLast)
        )
    }

    /// Splits off a painted area: the area with the mask as alpha, and the picture
    /// with that place filled in from its surroundings. A picture that is already a
    /// cut-out keeps its own outline in both.
    static func separateArea(imageURL: URL, maskURL: URL) throws -> Separation {
        let image = try decode(imageURL, maxEdge: maxEdge)
        let width = image.width
        let height = image.height
        guard let maskSource = CGImageSourceCreateWithURL(maskURL as CFURL, nil),
              let maskImage = CGImageSourceCreateImageAtIndex(maskSource, 0, nil)
        else {
            throw AIError.unreadableImage(maskURL.lastPathComponent)
        }
        var mask = [UInt8](repeating: 0, count: width * height)
        mask.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpace(name: CGColorSpace.linearGray)!, bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
            context?.interpolationQuality = .high
            context?.draw(maskImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var pixels = straightRGBA(of: image)
        let alpha = (0 ..< width * height).map { pixels[$0 * 4 + 3] }

        var area = pixels
        for index in 0 ..< width * height {
            area[index * 4 + 3] = UInt8((Int(alpha[index]) * Int(mask[index]) + 127) / 255)
        }

        // Only where the area covers the picture completely: under its soft edge the
        // original stays, so the two layers add up to the original when at rest.
        var hole = mask.map { $0 >= 250 ? UInt8(1) : 0 }
        // Transparent pixels hold no colour to spread.
        for index in 0 ..< width * height where alpha[index] == 0 {
            hole[index] = 1
        }
        fillHoles(&pixels, hole: hole, width: width, height: height)
        for index in 0 ..< width * height {
            pixels[index * 4 + 3] = alpha[index]
        }

        return try Separation(
            foreground: makeImage(area, width: width, height: height, alpha: .last),
            background: makeImage(pixels, width: width, height: height, alpha: .last)
        )
    }

    // MARK: - Depth

    /// Apple's Core ML conversion of Depth Anything V2 Small (Apache-2.0), pinned to
    /// a revision and checked against its published hashes.
    private static let modelRevision = "cfef6f6f2a70783dedc0bfae40cecbc2052285d3"
    private static let modelName = "DepthAnythingV2SmallF16"
    private static let modelFiles: [(path: String, sha256: String?)] = [
        ("Manifest.json", "2883ae290c48fe916dc5ececac03a7d847fa277165a49ef5652fa1d2b9cb55f7"),
        ("Data/com.apple.CoreML/model.mlmodel", "44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042"),
        ("Data/com.apple.CoreML/weights/weight.bin", "fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed")
    ]
    /// Shown before downloading.
    static let modelDownloadMegabytes = 50

    private static var modelsDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LiveWallpaper/Models", isDirectory: true)
    }

    private static var compiledModelURL: URL? {
        modelsDirectory?.appendingPathComponent("\(modelName).mlmodelc", isDirectory: true)
    }

    static var isDepthModelInstalled: Bool {
        compiledModelURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// Downloads, verifies and compiles the depth model once.
    static func installDepthModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let modelsDirectory, let compiledModelURL else {
            throw AIError.downloadFailed("Application Support")
        }
        if FileManager.default.fileExists(atPath: compiledModelURL.path) {
            return
        }
        let staging = modelsDirectory.appendingPathComponent("download-\(UUID().uuidString)", isDirectory: true)
        let package = staging.appendingPathComponent("\(modelName).mlpackage", isDirectory: true)
        defer {
            do {
                if FileManager.default.fileExists(atPath: staging.path) {
                    try FileManager.default.removeItem(at: staging)
                }
            } catch {
                AppLog.windowRefresh.error("model staging cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let base = "https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/\(modelRevision)/\(modelName).mlpackage/"
        for (index, file) in modelFiles.enumerated() {
            guard let url = URL(string: base + file.path) else {
                throw AIError.downloadFailed(file.path)
            }
            let destination = package.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let (downloaded, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw AIError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) \(file.path)")
            }
            try FileManager.default.moveItem(at: downloaded, to: destination)
            if let expected = file.sha256 {
                let digest = try SHA256.hash(data: Data(contentsOf: destination, options: .mappedIfSafe))
                    .map { String(format: "%02x", $0) }.joined()
                guard digest == expected else {
                    throw AIError.modelCorrupted(file.path)
                }
            }
            progress(Double(index + 1) / Double(modelFiles.count + 1))
        }
        let compiled = try await MLModel.compileModel(at: package)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: compiled, to: compiledModelURL)
        progress(1)
    }

    /// A grayscale depth map (white = near) at most `smoothEdge` long, in the image's
    /// proportions.
    static func estimateDepth(imageURL: URL) throws -> CGImage {
        guard let compiledModelURL else {
            throw AIError.noDepthOutput
        }
        let image = try decode(imageURL, maxEdge: maxEdge)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try VNCoreMLModel(for: MLModel(contentsOf: compiledModelURL, configuration: configuration))
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let buffer = (request.results?.first as? VNPixelBufferObservation)?.pixelBuffer else {
            throw AIError.noDepthOutput
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let values = readFloatPlane(buffer, width: width, height: height)
        // Relative inverse depth: larger is nearer. Spread it over the full range.
        let sorted = values.filter(\.isFinite).sorted()
        guard let low = sorted.isEmpty ? nil : sorted[sorted.count / 100],
              let high = sorted.isEmpty ? nil : sorted[sorted.count * 99 / 100], high > low
        else {
            throw AIError.noDepthOutput
        }
        let gray = values.map { value -> UInt8 in
            UInt8((min(max((value - low) / (high - low), 0), 1) * 255).rounded())
        }
        let small = try makeGray(gray, width: width, height: height)

        let scale = min(1, Double(smoothEdge) / Double(max(image.width, image.height)))
        let outWidth = max(Int(Double(image.width) * scale), 8)
        let outHeight = max(Int(Double(image.height) * scale), 8)
        guard let context = CGContext(
            data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8, bytesPerRow: outWidth,
            space: CGColorSpace(name: CGColorSpace.linearGray)!, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw AIError.noDepthOutput
        }
        context.interpolationQuality = .high
        context.draw(small, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
        guard let resized = context.makeImage() else {
            throw AIError.noDepthOutput
        }
        return resized
    }

    // MARK: - Pixels

    static func decode(_ url: URL, maxEdge: Int) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            throw AIError.unreadableImage(url.lastPathComponent)
        }
        return image
    }

    /// Straight-alpha RGBA bytes in sRGB.
    private static func rgba(of image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    /// Straight-alpha RGBA bytes in sRGB, keeping the picture's transparency.
    private static func straightRGBA(of image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        for index in 0 ..< width * height {
            let a = Int(bytes[index * 4 + 3])
            guard a > 0, a < 255 else {
                continue
            }
            for channel in 0 ..< 3 {
                bytes[index * 4 + channel] = UInt8(min((Int(bytes[index * 4 + channel]) * 255 + a / 2) / a, 255))
            }
        }
        return bytes
    }

    /// Reads a one-channel float32 or float16 buffer, resampling to the requested size.
    static func readFloatPlane(_ buffer: CVPixelBuffer, width: Int, height: Int) -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let sourceWidth = CVPixelBufferGetWidth(buffer)
        let sourceHeight = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return [Float](repeating: 0, count: width * height)
        }
        let isHalf = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent16Half
        var halfPlane: [Float] = []
        if isHalf {
            // Swift Float16 is unavailable on Intel; vImage handles the same IEEE-754 pixels on both architectures.
            halfPlane = [Float](repeating: 0, count: sourceWidth * sourceHeight)
            halfPlane.withUnsafeMutableBytes { bytes in
                var source = vImage_Buffer(data: base, height: vImagePixelCount(sourceHeight),
                                           width: vImagePixelCount(sourceWidth), rowBytes: rowBytes)
                var destination = vImage_Buffer(data: bytes.baseAddress!, height: vImagePixelCount(sourceHeight),
                                                width: vImagePixelCount(sourceWidth), rowBytes: sourceWidth * MemoryLayout<Float>.stride)
                let status = vImageConvert_Planar16FtoPlanarF(&source, &destination, vImage_Flags(kvImageDoNotTile))
                precondition(status == kvImageNoError, "Float16 plane conversion failed: \(status)")
            }
        }
        func value(_ x: Int, _ y: Int) -> Float {
            if isHalf {
                return halfPlane[y * sourceWidth + x]
            }
            let row = base.advanced(by: y * rowBytes)
            return row.assumingMemoryBound(to: Float.self)[x]
        }
        var out = [Float](repeating: 0, count: width * height)
        for y in 0 ..< height {
            let sy = min(y * sourceHeight / height, sourceHeight - 1)
            for x in 0 ..< width {
                out[y * width + x] = value(min(x * sourceWidth / width, sourceWidth - 1), sy)
            }
        }
        return out
    }

    private static func dilate(_ mask: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        // Separable max filter.
        var horizontal = [UInt8](repeating: 0, count: mask.count)
        for y in 0 ..< height {
            var lastSet = -radius - 1
            var nextSet = [Int](repeating: Int.max, count: width + 1)
            for x in stride(from: width - 1, through: 0, by: -1) {
                nextSet[x] = mask[y * width + x] != 0 ? x : nextSet[x + 1]
            }
            for x in 0 ..< width {
                if mask[y * width + x] != 0 {
                    lastSet = x
                }
                if x - lastSet <= radius || nextSet[x] - x <= radius {
                    horizontal[y * width + x] = 1
                }
            }
        }
        var out = [UInt8](repeating: 0, count: mask.count)
        for x in 0 ..< width {
            var lastSet = -radius - 1
            var nextSet = [Int](repeating: Int.max, count: height + 1)
            for y in stride(from: height - 1, through: 0, by: -1) {
                nextSet[y] = horizontal[y * width + x] != 0 ? y : nextSet[y + 1]
            }
            for y in 0 ..< height {
                if horizontal[y * width + x] != 0 {
                    lastSet = y
                }
                if y - lastSet <= radius || nextSet[y] - y <= radius {
                    out[y * width + x] = 1
                }
            }
        }
        return out
    }

    /// Push-pull fill: averages the known pixels down a pyramid until no gaps are
    /// left, then brings the averages back up into the holes only. Worked out at a
    /// reduced size (the fill is smooth anyway) and blended back at full size.
    private static func fillHoles(_ pixels: inout [UInt8], hole: [UInt8], width: Int, height: Int) {
        let scale = min(1, Double(smoothEdge) / Double(max(width, height)))
        let w = max(Int(Double(width) * scale), 1)
        let h = max(Int(Double(height) * scale), 1)
        // Downsample colour (weighted by "known") and weight.
        var color = [Float](repeating: 0, count: w * h * 3)
        var weight = [Float](repeating: 0, count: w * h)
        for y in 0 ..< height {
            let sy = min(y * h / height, h - 1)
            for x in 0 ..< width where hole[y * width + x] == 0 {
                let sx = min(x * w / width, w - 1)
                let target = sy * w + sx
                let source = (y * width + x) * 4
                color[target * 3] += Float(pixels[source])
                color[target * 3 + 1] += Float(pixels[source + 1])
                color[target * 3 + 2] += Float(pixels[source + 2])
                weight[target] += 1
            }
        }
        let filled = pushPull(color: color, weight: weight, width: w, height: h)
        for y in 0 ..< height {
            for x in 0 ..< width where hole[y * width + x] != 0 {
                // Bilinear from the small fill.
                let fx = (Float(x) + 0.5) * Float(w) / Float(width) - 0.5
                let fy = (Float(y) + 0.5) * Float(h) / Float(height) - 0.5
                let x0 = min(max(Int(fx.rounded(.down)), 0), w - 1)
                let y0 = min(max(Int(fy.rounded(.down)), 0), h - 1)
                let x1 = min(x0 + 1, w - 1)
                let y1 = min(y0 + 1, h - 1)
                let tx = min(max(fx - Float(x0), 0), 1)
                let ty = min(max(fy - Float(y0), 0), 1)
                let index = (y * width + x) * 4
                for channel in 0 ..< 3 {
                    let a = filled[(y0 * w + x0) * 3 + channel] * (1 - tx) + filled[(y0 * w + x1) * 3 + channel] * tx
                    let b = filled[(y1 * w + x0) * 3 + channel] * (1 - tx) + filled[(y1 * w + x1) * 3 + channel] * tx
                    pixels[index + channel] = UInt8(min(max(a * (1 - ty) + b * ty, 0), 255).rounded())
                }
                pixels[index + 3] = 255
            }
        }
    }

    /// Returns averaged colours for every pixel; `color` is weighted by `weight`.
    private static func pushPull(color: [Float], weight: [Float], width: Int, height: Int) -> [Float] {
        if width <= 1, height <= 1 {
            let w = max(weight[0], 1e-6)
            return [color[0] / w, color[1] / w, color[2] / w]
        }
        let halfWidth = max((width + 1) / 2, 1)
        let halfHeight = max((height + 1) / 2, 1)
        var smallColor = [Float](repeating: 0, count: halfWidth * halfHeight * 3)
        var smallWeight = [Float](repeating: 0, count: halfWidth * halfHeight)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let target = (y / 2) * halfWidth + x / 2
                let source = y * width + x
                smallWeight[target] += weight[source]
                for channel in 0 ..< 3 {
                    smallColor[target * 3 + channel] += color[source * 3 + channel]
                }
            }
        }
        let coarse = pushPull(color: smallColor, weight: smallWeight, width: halfWidth, height: halfHeight)
        var out = [Float](repeating: 0, count: width * height * 3)
        for y in 0 ..< height {
            // Bilinear position in the coarser level; nearest would leave blocks.
            let fy = min(max((Float(y) + 0.5) / 2 - 0.5, 0), Float(halfHeight - 1))
            let y0 = Int(fy)
            let y1 = min(y0 + 1, halfHeight - 1)
            let ty = fy - Float(y0)
            for x in 0 ..< width {
                let fx = min(max((Float(x) + 0.5) / 2 - 0.5, 0), Float(halfWidth - 1))
                let x0 = Int(fx)
                let x1 = min(x0 + 1, halfWidth - 1)
                let tx = fx - Float(x0)
                let source = y * width + x
                // Fully known pixels keep their own average; gaps take the coarser one.
                let own = min(weight[source], 1)
                for channel in 0 ..< 3 {
                    let top = coarse[(y0 * halfWidth + x0) * 3 + channel] * (1 - tx)
                        + coarse[(y0 * halfWidth + x1) * 3 + channel] * tx
                    let bottom = coarse[(y1 * halfWidth + x0) * 3 + channel] * (1 - tx)
                        + coarse[(y1 * halfWidth + x1) * 3 + channel] * tx
                    let fromCoarse = top * (1 - ty) + bottom * ty
                    let mine = weight[source] > 0 ? color[source * 3 + channel] / weight[source] : 0
                    out[source * 3 + channel] = mine * own + fromCoarse * (1 - own)
                }
            }
        }
        return out
    }

    private static func makeImage(_ bytes: [UInt8], width: Int, height: Int, alpha: CGImageAlphaInfo) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              )
        else {
            throw AIError.noDepthOutput
        }
        return image
    }

    private static func makeGray(_ bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                  space: CGColorSpace(name: CGColorSpace.linearGray)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              )
        else {
            throw AIError.noDepthOutput
        }
        return image
    }
}

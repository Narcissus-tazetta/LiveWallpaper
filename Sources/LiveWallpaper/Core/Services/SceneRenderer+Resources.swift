import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Metal
import simd

extension SceneRenderer {
    // MARK: - Resources

    func ensureAccumulation(width: Int, height: Int, format: MTLPixelFormat) throws {
        if let first = accumulation.first, first.width == width, first.height == height,
           first.pixelFormat == format
        {
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let first = device.makeTexture(descriptor: descriptor),
              let second = device.makeTexture(descriptor: descriptor)
        else {
            throw RendererError.textureAllocationFailed
        }
        accumulation = [first, second]
    }

    /// Keyed by the file's content, not its name: scenes ship the same image under several
    /// names (and layers and graphs reference it separately), and each copy would otherwise
    /// hold its own decoded texture. The variant is the decode mode, so only textures that
    /// decode identically are shared. Content also covers an imported package replacing a
    /// scene folder with files of the same names.
    static func cachedTexture(
        url: URL,
        variant: String,
        decode: (URL) throws -> MTLTexture
    ) throws -> MTLTexture {
        let key = try variant + "|" + contentDigest(of: url)
        textureCacheLock.lock()
        let cached = textureCache[key]?.texture
        textureCacheLock.unlock()
        if let cached {
            return cached
        }
        let texture = try decode(url)
        textureCacheLock.lock()
        textureCache = textureCache.filter { $0.value.texture != nil }
        textureCache[key] = TextureCacheEntry(texture)
        textureCacheLock.unlock()
        return texture
    }

    private static let digestLock = NSLock()
    private nonisolated(unsafe) static var digests: [String: String] = [:]

    /// Hashing reads the whole file, so the result is remembered per file identity.
    private static func contentDigest(of url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let identity = [
            url.standardizedFileURL.path,
            String(values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0),
            String(values.fileSize ?? 0)
        ].joined(separator: "|")
        digestLock.lock()
        let known = digests[identity]
        digestLock.unlock()
        if let known {
            return known
        }
        let digest = try SHA256.hash(data: Data(contentsOf: url, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        digestLock.lock()
        digests[identity] = digest
        digestLock.unlock()
        return digest
    }

    func fileURL(_ name: String) -> URL {
        SceneStore.folderURL(forVideoPath: videoPath).appendingPathComponent(name)
    }

    /// Decodes into sRGB RGBA8 so the shader knows exactly what it samples, whatever
    /// the file's color space or alpha layout. Flow maps are data: an sRGB file read
    /// into an sRGB context comes back unchanged, and they are never premultiplied.
    enum ImageAlpha { case premultiplied, straightDropped, straightKept }

    static func decodeRGBA(
        url: URL,
        device: MTLDevice,
        alpha mode: ImageAlpha = .premultiplied
    ) throws -> MTLTexture {
        let image = try decodeImage(url: url)
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let alpha: CGImageAlphaInfo = mode == .straightDropped ? .noneSkipLast : .premultipliedLast
        let drew: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: alpha.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else {
            throw RendererError.imageDecodeFailed(url.lastPathComponent)
        }
        if mode == .straightKept {
            for pixel in stride(from: 0, to: bytes.count, by: 4)
                where bytes[pixel + 3] != 0 && bytes[pixel + 3] != 255
            {
                let a = Int(bytes[pixel + 3])
                for channel in 0 ..< 3 {
                    bytes[pixel + channel] = UInt8(min(
                        255,
                        (Int(bytes[pixel + channel]) * 255 + a / 2) / a
                    ))
                }
            }
        }
        return try makeTexture(
            device: device,
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            bytes: bytes
        )
    }

    static func decodeMask(url: URL, device: MTLDevice) throws -> MTLTexture {
        let image = try decodeImage(url: url)
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drew: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpace(name: CGColorSpace.linearGray)!,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else {
            throw RendererError.imageDecodeFailed(url.lastPathComponent)
        }
        return try makeTexture(
            device: device,
            pixelFormat: .r8Unorm,
            width: width,
            height: height,
            bytes: bytes
        )
    }

    static func decodeImage(url: URL) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxTextureEdge,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            throw RendererError.imageDecodeFailed(url.lastPathComponent)
        }
        return image
    }

    static func makeTexture(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        bytes: [UInt8]
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RendererError.textureAllocationFailed
        }
        let bytesPerPixel = pixelFormat == .r8Unorm ? 1 : 4
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: bytes, bytesPerRow: width * bytesPerPixel
        )
        return texture
    }

    static func makeSolidTexture(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        bytes: [UInt8]
    ) throws -> MTLTexture {
        try makeTexture(device: device, pixelFormat: pixelFormat, width: 1, height: 1, bytes: bytes)
    }

    /// Compiled from source at runtime: SwiftPM cannot build .metal files, and this
    /// keeps macOS 13 support (runtime CIKernel sources need macOS 15).
    static func makePipeline() throws -> Pipeline {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }
        if let sharedPipeline {
            return sharedPipeline
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else {
            throw RendererError.metalUnavailable
        }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            throw RendererError.shaderCompilationFailed(error.localizedDescription)
        }
        func state(
            vertex: String = "scene_vertex",
            fragment: String,
            format: MTLPixelFormat,
            additive: Bool? = nil
        ) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            if let additive {
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        var compositeFetch: MTLRenderPipelineState?
        var compositeFetchWide: MTLRenderPipelineState?
        if device.supportsFamily(.apple1) {
            let fetchLibrary = try device.makeLibrary(source: fetchShaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = fetchLibrary.makeFunction(name: "scene_vertex")
            descriptor.fragmentFunction = fetchLibrary.makeFunction(name: "scene_composite_fetch")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            compositeFetch = try device.makeRenderPipelineState(descriptor: descriptor)
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float
            compositeFetchWide = try device.makeRenderPipelineState(descriptor: descriptor)
        }
        let pipeline = try Pipeline(
            device: device, queue: queue,
            composite: state(fragment: "scene_composite", format: .bgra8Unorm),
            capture: state(fragment: "scene_capture", format: .rgba8Unorm),
            effect: state(fragment: "scene_effect", format: .rgba8Unorm),
            particlesOver: state(
                vertex: "particle_vertex",
                fragment: "particle_fragment",
                format: .rgba8Unorm,
                additive: false
            ),
            particlesAdd: state(
                vertex: "particle_vertex",
                fragment: "particle_fragment",
                format: .rgba8Unorm,
                additive: true
            ),
            particleSystemOver: state(
                vertex: "particle_system_vertex",
                fragment: "particle_system_fragment",
                format: .rgba8Unorm,
                additive: false
            ),
            particleSystemAdd: state(
                vertex: "particle_system_vertex",
                fragment: "particle_system_fragment",
                format: .rgba8Unorm,
                additive: true
            ),
            particleSystemOverWide: state(
                vertex: "particle_system_vertex",
                fragment: "particle_system_fragment",
                format: .rgba16Float,
                additive: false
            ),
            particleSystemAddWide: state(
                vertex: "particle_system_vertex",
                fragment: "particle_system_fragment",
                format: .rgba16Float,
                additive: true
            ),
            compositeFetch: compositeFetch,
            compositeWide: state(fragment: "scene_composite", format: .rgba16Float),
            compositeFetchWide: compositeFetchWide,
            library: library
        )
        sharedPipeline = pipeline
        return pipeline
    }
}

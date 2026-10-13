@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import Metal

/// Renders one loop of an animated scene into a video. Every effect repeats a whole
/// number of times per loop, so frame N (= frame 0) is left out and the video loops
/// without a seam.
enum SceneVideoBaker {
    enum BakeError: LocalizedError {
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case let .writerFailed(message):
                return message
            }
        }
    }

    /// A 60 s loop at 4K bakes in about a minute and ~100 MB (measured on M5).
    static let framesPerSecond = 60

    /// Longest edge of the baked video; the lock screen does not need more.
    static let maxEdge = 3840

    static func bake(
        document: SceneDocument,
        videoPath: String,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            if document.isAnimated {
                try await render(document: document, videoPath: videoPath, outputURL: outputURL, progress: progress)
            } else {
                try await renderStill(document: document, videoPath: videoPath, outputURL: outputURL)
            }
        }
        try await withTaskCancellationHandler {
            do {
                try await task.value
                try Task.checkCancellation()
            } catch {
                // The still-image transcoder uses its own cancellation error.
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            task.cancel()
        }
    }

    private static func renderStill(document: SceneDocument, videoPath: String, outputURL: URL) async throws {
        let image = try SceneRenderer(document: document, videoPath: videoPath).renderStill()
        let temporaryBase = outputURL.deletingLastPathComponent().appendingPathComponent(".scene-\(UUID().uuidString)")
        let stillURL = temporaryBase.appendingPathExtension("png")
        let videoURL = temporaryBase.appendingPathExtension("mp4")
        defer {
            removeIfPresent(stillURL)
            removeIfPresent(videoURL)
        }
        guard let destination = CGImageDestinationCreateWithURL(stillURL as CFURL, "public.png" as CFString, 1, nil) else {
            throw SceneStore.StoreError.unreadableImage(stillURL.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SceneStore.StoreError.unreadableImage(stillURL.lastPathComponent)
        }
        try Task.checkCancellation()
        try await AnimatedImageTranscoder.transcode(imageURL: stillURL, to: videoURL)
        try Task.checkCancellation()
        try installVideo(videoURL, at: outputURL)
    }

    private static func render(
        document: SceneDocument,
        videoPath: String,
        outputURL: URL,
        progress: @Sendable (Double) -> Void
    ) async throws {
        let renderer = try SceneRenderer(document: document, videoPath: videoPath)
        // Its own queue: on the shared one, every live preview frame waited behind a
        // full-resolution bake frame and stalled the main thread in nextDrawable.
        guard let commandQueue = renderer.device.makeCommandQueue() else {
            throw BakeError.writerFailed("Cannot create a command queue")
        }
        let (width, height) = SceneRenderer.outputSize(for: document, maxEdge: maxEdge)
        let fps = framesPerSecond
        let frameCount = max(document.loopSeconds, 1) * fps

        let tmpURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp.mp4")
        defer { removeIfPresent(tmpURL) }
        let writer = try AVAssetWriter(outputURL: tmpURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(4_000_000, Int(Double(width * height * fps) * 0.03)),
                AVVideoExpectedSourceFrameRateKey: fps
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ]
        )
        guard writer.canAdd(input) else {
            throw BakeError.writerFailed(writer.error?.localizedDescription ?? "Cannot add video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw BakeError.writerFailed(writer.error?.localizedDescription ?? "Cannot start writing")
        }
        writer.startSession(atSourceTime: .zero)

        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, renderer.device, nil, &textureCache)
        do {
            guard let textureCache, let pool = adaptor.pixelBufferPool else {
                throw BakeError.writerFailed("No pixel buffer pool")
            }
            for frame in 0 ..< frameCount {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                var pixelBuffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
                var metalTexture: CVMetalTexture?
                if let pixelBuffer {
                    CVMetalTextureCacheCreateTextureFromImage(
                        nil, textureCache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &metalTexture
                    )
                }
                guard let pixelBuffer, let metalTexture, let texture = CVMetalTextureGetTexture(metalTexture),
                      let commandBuffer = commandQueue.makeCommandBuffer()
                else {
                    throw BakeError.writerFailed("Cannot allocate frame \(frame)")
                }
                let time = Double(frame) / Double(fps)
                try renderer.encode(into: texture, commandBuffer: commandBuffer, input: SceneFrameInput(time: time))
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                if let error = commandBuffer.error {
                    throw error
                }
                guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))) else {
                    throw BakeError.writerFailed(writer.error?.localizedDescription ?? "Cannot append frame \(frame)")
                }
                progress(Double(frame + 1) / Double(frameCount))
            }
        } catch {
            writer.cancelWriting()
            removeIfPresent(tmpURL)
            throw error
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(fps)))
        await writer.finishWriting()
        guard writer.status == .completed else {
            removeIfPresent(tmpURL)
            throw BakeError.writerFailed(writer.error?.localizedDescription ?? "Writing did not complete")
        }
        try Task.checkCancellation()
        try installVideo(tmpURL, at: outputURL)
    }

    private static func installVideo(_ tmpURL: URL, at outputURL: URL) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tmpURL)
        } else {
            try FileManager.default.moveItem(at: tmpURL, to: outputURL)
        }
    }

    private static func removeIfPresent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            AppLog.windowRefresh.error("bake cleanup failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

@preconcurrency import AVFoundation
import CoreVideo
import Foundation
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
        // Below the editor's own work, so sliders stay smooth while a loop bakes.
        try await Task.detached(priority: .utility) {
            try await render(document: document, videoPath: videoPath, outputURL: outputURL, progress: progress)
        }.value
    }

    private static func render(
        document: SceneDocument,
        videoPath: String,
        outputURL: URL,
        progress: @Sendable (Double) -> Void
    ) async throws {
        let renderer = try SceneRenderer(document: document, videoPath: videoPath)
        let (width, height) = SceneRenderer.outputSize(for: document, maxEdge: maxEdge)
        let fps = framesPerSecond
        let frameCount = max(document.loopSeconds, 1) * fps

        let tmpURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp.mp4")
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
                      let commandBuffer = renderer.commandQueue.makeCommandBuffer()
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

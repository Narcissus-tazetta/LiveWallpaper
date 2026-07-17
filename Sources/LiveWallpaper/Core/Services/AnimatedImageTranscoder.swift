import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// アニメ画像(GIF / APNG / アニメWebP)をループ再生用のmp4動画へ変換するサービス。
/// WallpaperModel非依存。変換後は既存の動画パイプラインがそのまま扱える。
enum AnimatedImageTranscoder {
    struct Options: Sendable {
        /// エンコーダ保護のための長辺キャップ(超える場合はアスペクト維持で縮小)
        var maxLongEdge: CGFloat = 3840
        /// AVPlayerLooperがサブ秒アイテムを高速回転しないよう、短いアニメは繰り返してこの長さ以上にする
        var minimumOutputDuration: Double = 2.0
        /// 単一フレーム(静止画)を保持する動画の長さ
        var singleFrameHoldDuration: Double = 4.0
    }

    enum TranscodeError: Error {
        case unreadableImage
        case zeroFrames
        case frameDecodeFailed(index: Int)
        case writerSetupFailed(underlying: Error?)
        case writerFailed(underlying: Error?)
        case cancelled
    }

    private static let supportedExtensions: Set<String> = ["gif", "png", "apng", "webp"]

    /// 拡張子ベースの軽量判定(UIゲート用)。深い検証はtranscodeが行う。
    static func isSupportedImageExtension(_ ext: String) -> Bool {
        supportedExtensions.contains(ext.lowercased())
    }

    /// HEVCで変換を試み、writer系の失敗時はH.264で全体を1回リトライする。
    static func transcode(
        imageURL: URL,
        to outputURL: URL,
        options: Options = Options(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        do {
            try await transcodeOnce(
                imageURL: imageURL,
                outputURL: outputURL,
                codec: .hevc,
                options: options,
                progress: progress
            )
        } catch let error as TranscodeError {
            switch error {
            case .writerSetupFailed, .writerFailed:
                try await transcodeOnce(
                    imageURL: imageURL,
                    outputURL: outputURL,
                    codec: .h264,
                    options: options,
                    progress: progress
                )
            default:
                throw error
            }
        }
    }

    // MARK: - Core

    private struct FrameAppend {
        let frameIndex: Int
        let time: Double
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func cancel() {
            lock.lock()
            value = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private static let decodeOptions =
        [kCGImageSourceShouldCacheImmediately: false] as CFDictionary

    private static func transcodeOnce(
        imageURL: URL,
        outputURL: URL,
        codec: AVVideoCodecType,
        options: Options,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        guard let source = CGImageSourceCreateWithURL(
            imageURL as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw TranscodeError.unreadableImage
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else {
            throw TranscodeError.zeroFrames
        }
        guard let firstFrame = CGImageSourceCreateImageAtIndex(source, 0, decodeOptions) else {
            throw TranscodeError.unreadableImage
        }

        let canvas = canvasSize(for: firstFrame, maxLongEdge: options.maxLongEdge)
        let delays = (0..<frameCount).map { frameDelay(source: source, index: $0) }
        let (appends, sessionEnd) = buildSchedule(
            frameCount: frameCount,
            delays: delays,
            options: options
        )

        let tmpURL = outputURL.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: tmpURL)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: tmpURL, fileType: .mp4)
        } catch {
            throw TranscodeError.writerSetupFailed(underlying: error)
        }

        let singleSequenceDuration = max(delays.reduce(0, +), 0.02)
        let averageFPS = min(max(Double(frameCount) / singleSequenceDuration, 1), 60)
        let width = Int(canvas.width)
        let height = Int(canvas.height)
        let settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(
                    2_000_000,
                    Int(Double(width * height) * averageFPS * 0.08)
                )
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
        )

        guard writer.canAdd(input) else {
            throw TranscodeError.writerSetupFailed(underlying: writer.error)
        }
        writer.add(input)
        guard writer.startWriting() else {
            try? FileManager.default.removeItem(at: tmpURL)
            throw TranscodeError.writerSetupFailed(underlying: writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        do {
            try await appendFrames(
                source: source,
                appends: appends,
                canvas: canvas,
                writer: writer,
                input: input,
                adaptor: adaptor,
                progress: progress
            )
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: tmpURL)
            throw error
        }

        writer.endSession(atSourceTime: CMTime(seconds: sessionEnd, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: tmpURL)
            throw TranscodeError.writerFailed(underlying: writer.error)
        }

        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: outputURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw TranscodeError.writerFailed(underlying: error)
        }
    }

    private static func appendFrames(
        source: CGImageSource,
        appends: [FrameAppend],
        canvas: CGSize,
        writer: AVAssetWriter,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let cancelFlag = CancelFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let queue = DispatchQueue(label: "com.sakana.livewallpaper.animated-transcode")
                var cursor = 0
                var finished = false
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData {
                        if finished {
                            return
                        }
                        if cancelFlag.isCancelled {
                            finished = true
                            input.markAsFinished()
                            continuation.resume(throwing: TranscodeError.cancelled)
                            return
                        }
                        if cursor >= appends.count {
                            finished = true
                            input.markAsFinished()
                            continuation.resume()
                            return
                        }

                        let step = appends[cursor]
                        var appendError: TranscodeError?
                        autoreleasepool {
                            guard let image = CGImageSourceCreateImageAtIndex(
                                source,
                                step.frameIndex,
                                decodeOptions
                            ) else {
                                appendError = .frameDecodeFailed(index: step.frameIndex)
                                return
                            }
                            guard let buffer = makePixelBuffer(adaptor: adaptor, canvas: canvas),
                                  draw(image, into: buffer, canvas: canvas)
                            else {
                                appendError = .writerFailed(underlying: writer.error)
                                return
                            }
                            let time = CMTime(seconds: step.time, preferredTimescale: 600)
                            if adaptor.append(buffer, withPresentationTime: time) == false {
                                appendError = .writerFailed(underlying: writer.error)
                            }
                        }
                        if let appendError {
                            finished = true
                            input.markAsFinished()
                            continuation.resume(throwing: appendError)
                            return
                        }

                        cursor += 1
                        progress?(Double(cursor) / Double(appends.count))
                    }
                }
            }
        } onCancel: {
            cancelFlag.cancel()
        }
    }

    // MARK: - Frame metadata

    /// 拡張子ではなく実際のプロパティ辞書をプローブしてディレイを取得する
    /// (拡張子が.apngでも中身はPNG辞書、といったズレに強くするため)。
    private static func frameDelay(source: CGImageSource, index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any]
        else {
            return normalizedDelay(nil)
        }
        let candidates: [(dictionary: CFString, unclamped: CFString, clamped: CFString)] = [
            (kCGImagePropertyGIFDictionary,
             kCGImagePropertyGIFUnclampedDelayTime,
             kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary,
             kCGImagePropertyAPNGUnclampedDelayTime,
             kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary,
             kCGImagePropertyWebPUnclampedDelayTime,
             kCGImagePropertyWebPDelayTime),
        ]
        for candidate in candidates {
            guard let dictionary = properties[candidate.dictionary] as? [CFString: Any] else {
                continue
            }
            let raw = (dictionary[candidate.unclamped] as? Double)
                ?? (dictionary[candidate.clamped] as? Double)
            return normalizedDelay(raw)
        }
        return normalizedDelay(nil)
    }

    /// ブラウザ互換のディレイ正規化: 欠損または10ms以下は100ms、下限は20ms。
    private static func normalizedDelay(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite, raw > 0.010 else {
            return 0.100
        }
        return max(raw, 0.020)
    }

    private static func buildSchedule(
        frameCount: Int,
        delays: [Double],
        options: Options
    ) -> (appends: [FrameAppend], sessionEnd: Double) {
        if frameCount == 1 {
            // 2サンプル書くことでゼロ長サンプルの縁を踏まない
            return (
                [
                    FrameAppend(frameIndex: 0, time: 0),
                    FrameAppend(frameIndex: 0, time: options.singleFrameHoldDuration / 2),
                ],
                options.singleFrameHoldDuration
            )
        }

        let total = max(delays.reduce(0, +), 0.02)
        let passes = total >= options.minimumOutputDuration
            ? 1
            : max(1, Int(ceil(options.minimumOutputDuration / total)))
        var appends: [FrameAppend] = []
        appends.reserveCapacity(frameCount * passes)
        var time = 0.0
        for _ in 0..<passes {
            for index in 0..<frameCount {
                appends.append(FrameAppend(frameIndex: index, time: time))
                time += delays[index]
            }
        }
        return (appends, time)
    }

    // MARK: - Pixels

    /// H.264/HEVCの偶数寸法要件を満たすよう+1px切り上げ、長辺をキャップする。
    private static func canvasSize(for image: CGImage, maxLongEdge: CGFloat) -> CGSize {
        var width = CGFloat(image.width)
        var height = CGFloat(image.height)
        let longEdge = max(width, height)
        if longEdge > maxLongEdge, longEdge > 0 {
            let scale = maxLongEdge / longEdge
            width = (width * scale).rounded()
            height = (height * scale).rounded()
        }
        var evenWidth = max(Int(width), 2)
        var evenHeight = max(Int(height), 2)
        if evenWidth % 2 != 0 { evenWidth += 1 }
        if evenHeight % 2 != 0 { evenHeight += 1 }
        return CGSize(width: evenWidth, height: evenHeight)
    }

    private static func makePixelBuffer(
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        canvas: CGSize
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        if buffer == nil {
            CVPixelBufferCreate(
                nil,
                Int(canvas.width),
                Int(canvas.height),
                kCVPixelFormatType_32BGRA,
                [
                    kCVPixelBufferCGImageCompatibilityKey: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                ] as CFDictionary,
                &buffer
            )
        }
        return buffer
    }

    /// フレームを不透明黒の上に合成してキャンバス全面へ描画する
    /// (透過GIF対策。奇数寸法パディング分の≤1pxストレッチは不可視)。
    private static func draw(_ image: CGImage, into pixelBuffer: CVPixelBuffer, canvas: CGSize) -> Bool {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: Int(canvas.width),
            height: Int(canvas.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return false
        }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: canvas))
        context.draw(image, in: CGRect(origin: .zero, size: canvas))
        return true
    }
}

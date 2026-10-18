import AVFoundation
import CoreVideo
import Metal

/// The frames of a looping video layer as Metal textures. Decoding runs on its own
/// queue: forward from the last frame, with a new read for a jump back (the editor
/// scrubbing) or far ahead, and the next loop's first frame read before the end so
/// the wrap does not wait for a new reader (~50 ms for a 2000-pixel H.264).
final class SceneVideoFrames: @unchecked Sendable {
    enum FramesError: LocalizedError {
        case noVideoTrack(String)
        case readFailed(String, String)

        var errorDescription: String? {
            switch self {
            case let .noVideoTrack(name):
                return "Scene video \(name) has no video track"
            case let .readFailed(name, reason):
                return "Scene video \(name) cannot be read: \(reason)"
            }
        }
    }

    private struct Read {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let start: Double
        /// The next decoded sample, not shown yet.
        var pending: CMSampleBuffer?
        /// The last sample shown from this read; nil until its first.
        var shownTime: Double?
        var isFinished = false
    }

    struct Frame {
        let texture: MTLTexture
        /// Keeps the decoder from reusing the pixel buffer while the GPU may read it.
        let backing: CVMetalTexture
    }

    /// Seconds; frames repeat with this period.
    let duration: Double
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let textureCache: CVMetalTextureCache
    private let queue = DispatchQueue(label: "SceneVideoFrames", qos: .userInitiated)
    // Only touched on `queue`.
    private var read: Read?
    private var nextLoop: Read?
    private var hasReportedFailure = false
    // Read and written under `lock`.
    private let lock = NSLock()
    private var published: Frame?
    private var requested: Double?
    private var isDecoding = false
    /// Decoding ahead from the current frame is cheaper than a new read up to here.
    private static let maximumForwardDecode = 1.0

    /// The newest decoded frame; nil before the first.
    var frame: Frame? {
        lock.lock()
        defer { lock.unlock() }
        return published
    }

    private init(asset: AVURLAsset, track: AVAssetTrack, duration: Double, textureCache: CVMetalTextureCache) {
        self.asset = asset
        self.track = track
        self.duration = duration
        self.textureCache = textureCache
    }

    static func load(url: URL, device: MTLDevice) async throws -> SceneVideoFrames {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw FramesError.noVideoTrack(url.lastPathComponent)
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw FramesError.readFailed(url.lastPathComponent, "duration \(duration)")
        }
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw FramesError.readFailed(url.lastPathComponent, "texture cache \(status)")
        }
        return SceneVideoFrames(asset: asset, track: track, duration: duration, textureCache: cache)
    }

    /// Decodes the frame at `time` (any value; the video loops) before returning.
    /// For a fixed sequence of frames (a bake).
    func advance(to time: Double) throws {
        try queue.sync { try decode(to: local(time)) }
    }

    /// Starts decoding toward `time` and returns at once; `frame` shows the newest
    /// result, about one request behind. Requests made while decoding coalesce.
    func request(_ time: Double) {
        lock.lock()
        requested = local(time)
        let start = !isDecoding
        isDecoding = true
        lock.unlock()
        guard start else { return }
        queue.async { [self] in
            while true {
                lock.lock()
                guard let target = requested else {
                    isDecoding = false
                    lock.unlock()
                    return
                }
                requested = nil
                lock.unlock()
                do {
                    try decode(to: target)
                    try prepareNextLoop()
                } catch {
                    // The last frame stays; the error repeats every frame, so it is logged once.
                    if !hasReportedFailure {
                        hasReportedFailure = true
                        AppLog.windowRefresh.error("scene video decode failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    private func local(_ time: Double) -> Double {
        time.truncatingRemainder(dividingBy: duration).magnitude
    }

    private func decode(to local: Double) throws {
        if let current = read, local >= current.shownTime ?? current.start,
           local - (current.shownTime ?? current.start) <= Self.maximumForwardDecode
        {
            // Keep reading in order.
        } else if let prepared = nextLoop, local < (read?.shownTime ?? .infinity), local <= Self.maximumForwardDecode {
            read?.reader.cancelReading()
            read = prepared
            nextLoop = nil
        } else {
            read?.reader.cancelReading()
            read = try startReading(at: local)
        }
        while var current = read {
            guard let sample = try nextSample(&current) else {
                read = current
                break
            }
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            // The first sample of a read is shown even when it starts a little after
            // `local` (a read begins at a frame boundary).
            // The remainder that loops the time lands just short of a frame's start
            // (2.3 mod 2 = 0.29999...), which must still show that frame.
            guard start <= local + 1e-6 || current.shownTime == nil else {
                current.pending = sample
                read = current
                break
            }
            try show(sample)
            current.shownTime = start
            read = current
        }
    }

    /// Near the end of a read, opens the next loop's read at 0 and decodes its first frame.
    private func prepareNextLoop() throws {
        guard nextLoop == nil, let current = read, current.isFinished || (current.shownTime ?? 0) > duration - 0.5 else { return }
        var next = try startReading(at: 0)
        next.pending = try nextSample(&next)
        nextLoop = next
    }

    private func startReading(at time: Double) throws -> Read {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw FramesError.readFailed(asset.url.lastPathComponent, error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: time, preferredTimescale: 600), end: .positiveInfinity)
        guard reader.startReading() else {
            throw FramesError.readFailed(asset.url.lastPathComponent, reader.error?.localizedDescription ?? "cannot start")
        }
        return Read(reader: reader, output: output, start: time)
    }

    private func nextSample(_ read: inout Read) throws -> CMSampleBuffer? {
        if let pending = read.pending {
            read.pending = nil
            return pending
        }
        guard !read.isFinished else { return nil }
        if let sample = read.output.copyNextSampleBuffer() {
            return sample
        }
        if read.reader.status == .failed {
            throw FramesError.readFailed(asset.url.lastPathComponent, read.reader.error?.localizedDescription ?? "decode failed")
        }
        // The end of the file: the last frame stays until the loop wraps.
        read.isFinished = true
        return nil
    }

    private func show(_ sample: CMSampleBuffer) throws {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
            return
        }
        var backing: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &backing
        )
        guard status == kCVReturnSuccess, let backing, let texture = CVMetalTextureGetTexture(backing) else {
            throw FramesError.readFailed(asset.url.lastPathComponent, "frame texture \(status)")
        }
        lock.lock()
        published = Frame(texture: texture, backing: backing)
        lock.unlock()
    }
}

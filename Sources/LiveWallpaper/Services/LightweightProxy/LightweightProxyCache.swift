import AVFoundation
import AppKit

@MainActor
final class LightweightProxyCache {
    enum ProxyGenerationState: Equatable {
        case idle
        case generating
        case ready
        case failed
    }

    enum GenerationResult {
        case ready(URL)
        case passthrough
        case cancelled
        case failed
    }

    enum InitializationState {
        case idle
        case loading
        case ready
    }

    struct Entry: Codable, SourceTrackedCacheEntry {
        var fileName: String?
        var isPassthrough: Bool
        var sourceSize: UInt64
        var sourceModifiedAt: TimeInterval
        var lastAccessAt: TimeInterval
    }

    struct Metadata: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    struct SizedEntry {
        var path: String
        var entry: Entry
        var bytes: UInt64
    }

    final class ActiveGeneration {
        let path: String
        var session: AVAssetExportSession?
        var task: Task<Void, Never>?

        init(path: String) {
            self.path = path
        }
    }

    // Bumped from 1: earlier proxies were transcoded with a mis-scaled video
    // composition transform (renderSize was shrunk without scaling the layer
    // instruction transform), which cropped/zoomed into the frame instead of
    // scaling it down. Bumping this discards those bad cached proxies so they
    // get regenerated with the fix.
    nonisolated static let metadataVersion = 2
    nonisolated static let metadataFileName = "metadata.json"
    /// Target long edge, in pixels, for the transcoded proxy. Sources at or below this
    /// (and at or below the frame-rate cap) are treated as passthrough — see +Generation.swift.
    nonisolated static let targetLongEdge: CGFloat = 1280
    nonisolated static let targetFrameRate: Float = 30

    let maxDiskBytes: UInt64 = 2 * 1024 * 1024 * 1024
    let ioQueue = DispatchQueue(label: "LiveWallpaper.lightweightProxyCache.io", qos: .utility)

    var initializationState: InitializationState = .idle
    var metadata: Metadata = .init(version: 1, entries: [:])
    var metadataDirty: Bool = false
    var metadataFlushWorkItem: DispatchWorkItem?
    let metadataFlushDelay: TimeInterval = 2.0
    var willTerminateObserver: NSObjectProtocol?
    var pendingGenerationRequest: (path: String, completion: (GenerationResult) -> Void)?
    var activeGeneration: ActiveGeneration?

    deinit {
        if let observer = willTerminateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func cachedProxyURL(for path: String) -> URL? {
        ensureInitialized()
        guard initializationState == .ready else {
            return nil
        }
        guard let entry = metadata.entries[path], !entry.isPassthrough else {
            return nil
        }
        guard SourceValidityCheck.isValid(path: path, entry: entry) else {
            return nil
        }
        guard let fileName = entry.fileName,
              let fileURL = Self.dataDirectoryURL()?.appendingPathComponent(fileName),
              FileManager.default.fileExists(atPath: fileURL.path)
        else {
            return nil
        }
        touch(path)
        return fileURL
    }

    func cancelActiveGeneration() {
        pendingGenerationRequest = nil
        guard let active = activeGeneration else {
            return
        }
        active.session?.cancelExport()
        active.task?.cancel()
        activeGeneration = nil
    }

    func generateProxyIfNeeded(for path: String, completion: @escaping (GenerationResult) -> Void) {
        ensureInitialized()
        guard initializationState == .ready else {
            pendingGenerationRequest = (path, completion)
            return
        }

        if let cached = cachedProxyURL(for: path) {
            completion(.ready(cached))
            return
        }
        if let entry = metadata.entries[path],
           entry.isPassthrough,
           SourceValidityCheck.isValid(path: path, entry: entry)
        {
            completion(.passthrough)
            return
        }
        guard activeGeneration?.path != path else {
            return
        }
        cancelActiveGeneration()

        let active = ActiveGeneration(path: path)
        activeGeneration = active
        active.task = Task { [weak self] in
            guard let self else {
                return
            }
            let result = await self.performGeneration(path: path, activeGeneration: active)
            if self.activeGeneration === active {
                self.activeGeneration = nil
            }
            completion(result)
        }
    }
}

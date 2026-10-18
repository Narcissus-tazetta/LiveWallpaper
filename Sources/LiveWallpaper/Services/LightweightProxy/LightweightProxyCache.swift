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
        var completions: [(GenerationResult) -> Void] = []
        var isCancelled = false
        var session: AVAssetExportSession?
        var task: Task<Void, Never>?

        init(path: String) {
            self.path = path
        }
    }

    // Bump whenever the encoding of proxies changes (e.g. a fixed scaling transform,
    // keeping HDR sources HDR): a version mismatch wipes the cached files so they get
    // regenerated, instead of serving proxies made under the old scheme.
    nonisolated static let metadataVersion = 4
    nonisolated static let metadataFileName = "metadata.json"
    /// Target long edge, in pixels, for the transcoded proxy. Sources at or below this
    /// (and at or below the frame-rate cap) are treated as passthrough — see +Generation.swift.
    nonisolated static let targetLongEdge: CGFloat = 1280
    nonisolated static let targetFrameRate: Float = 30

    let rootDirectory: URL?
    var dataDirectory: URL? {
        rootDirectory?.appendingPathComponent("data", isDirectory: true)
    }

    var metadataURL: URL? {
        rootDirectory?.appendingPathComponent(Self.metadataFileName)
    }

    init(rootDirectory: URL? = LightweightProxyCache.rootDirectoryURL()) {
        self.rootDirectory = rootDirectory
    }

    let maxDiskBytes: UInt64 = 2 * 1024 * 1024 * 1024
    let ioQueue = DispatchQueue(label: "LiveWallpaper.lightweightProxyCache.io", qos: .utility)

    var initializationState: InitializationState = .idle
    var metadata: Metadata = .init(version: 1, entries: [:])
    var metadataDirty: Bool = false
    var metadataFlushWorkItem: DispatchWorkItem?
    let metadataFlushDelay: TimeInterval = 2.0
    var willTerminateObserver: NSObjectProtocol?
    var pendingGenerationRequests: [(path: String, completions: [(GenerationResult) -> Void])] = []
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
              let fileURL = dataDirectory?.appendingPathComponent(fileName),
              FileManager.default.fileExists(atPath: fileURL.path)
        else {
            return nil
        }
        touch(path)
        return fileURL
    }

    func cancelActiveGeneration() {
        retainGenerationRequests(for: [])
    }

    func retainGenerationRequests(for paths: Set<String>) {
        let removed = pendingGenerationRequests.filter { !paths.contains($0.path) }
        pendingGenerationRequests.removeAll { !paths.contains($0.path) }
        var completions = removed.flatMap(\.completions)
        if let active = activeGeneration, !paths.contains(active.path) {
            completions += active.completions
            active.completions = []
            active.isCancelled = true
            active.session?.cancelExport()
            active.task?.cancel()
        }
        // An export must finish cancelling before the next one reuses its .tmp file.
        for completion in completions {
            completion(.cancelled)
        }
    }

    func generateProxyIfNeeded(for path: String, completion: @escaping (GenerationResult) -> Void) {
        if let active = activeGeneration, active.path == path, !active.isCancelled {
            active.completions.append(completion)
            return
        }
        if let index = pendingGenerationRequests.firstIndex(where: { $0.path == path }) {
            pendingGenerationRequests[index].completions.append(completion)
        } else {
            pendingGenerationRequests.append((path, [completion]))
        }
        ensureInitialized()
        startNextGeneration()
    }

    func startNextGeneration() {
        guard initializationState == .ready, activeGeneration == nil,
              !pendingGenerationRequests.isEmpty else { return }
        let request = pendingGenerationRequests.removeFirst()
        let active = ActiveGeneration(path: request.path)
        active.completions = request.completions
        activeGeneration = active
        active.task = Task { [weak self] in
            guard let self else { return }
            let result: GenerationResult
            if active.isCancelled {
                result = .cancelled
            } else if let cached = cachedProxyURL(for: active.path) {
                result = .ready(cached)
            } else if let entry = metadata.entries[active.path], entry.isPassthrough,
                      SourceValidityCheck.isValid(path: active.path, entry: entry)
            {
                result = .passthrough
            } else {
                result = await performGeneration(path: active.path, activeGeneration: active)
            }
            let completions = active.completions
            activeGeneration = nil
            for completion in completions {
                completion(active.isCancelled ? .cancelled : result)
            }
            startNextGeneration()
        }
    }
}

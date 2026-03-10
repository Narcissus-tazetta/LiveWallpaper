import AppKit
import AVFoundation
import CryptoKit
import QuickLookThumbnailing

@MainActor
final class DiskThumbnailCache: ObservableObject {
    private struct Entry: Codable {
        var fileName: String
        var sourcePath: String
        var sourceSize: UInt64
        var sourceModifiedAt: TimeInterval
        var lastAccessAt: TimeInterval
    }

    private struct Metadata: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    private struct SizedEntry {
        var path: String
        var entry: Entry
        var bytes: UInt64
    }

    @Published private(set) var revision: Int = 0

    private let maxInMemoryCount: Int = 90
    private let maxDiskBytes: UInt64 = 500 * 1024 * 1024
    private let maxConcurrentGenerations: Int = 2
    private let metadataFileName = "metadata.json"

    private var inMemoryImages: [String: NSImage] = [:]
    private var inMemoryLastAccess: [String: TimeInterval] = [:]
    private var visiblePaths: Set<String> = []
    private var pendingQueue: [String] = []
    private var inFlight: Set<String> = []
    private var metadata: Metadata = .init(version: 1, entries: [:])
    private var initialized: Bool = false

    func image(for path: String) -> NSImage? {
        ensureInitialized()

        if let cached = inMemoryImages[path] {
            touch(path)
            return cached
        }

        guard let entry = metadata.entries[path] else {
            return nil
        }

        guard isSourceValid(path: path, entry: entry) else {
            removeEntry(path)
            return nil
        }

        let fileURL = dataDirectoryURL().appendingPathComponent(entry.fileName)
        guard let image = NSImage(contentsOf: fileURL) else {
            removeEntry(path)
            return nil
        }

        inMemoryImages[path] = image
        touch(path)
        trimInMemoryIfNeeded()
        bumpRevision()
        return image
    }

    func setVisible(path: String, isVisible: Bool) {
        ensureInitialized()

        if isVisible {
            visiblePaths.insert(path)
            request(path: path)
            return
        }

        visiblePaths.remove(path)
        if let index = pendingQueue.firstIndex(of: path) {
            pendingQueue.remove(at: index)
        }
    }

    func request(path: String) {
        ensureInitialized()

        guard inMemoryImages[path] == nil else {
            touch(path)
            return
        }

        if image(for: path) != nil {
            return
        }

        guard FileManager.default.fileExists(atPath: path) else {
            return
        }
        guard !inFlight.contains(path) else {
            return
        }
        guard !pendingQueue.contains(path) else {
            return
        }

        pendingQueue.append(path)
        processQueue()
    }

    func processQueue() {
        ensureInitialized()

        while inFlight.count < maxConcurrentGenerations, !pendingQueue.isEmpty {
            let path = pendingQueue.removeFirst()
            guard visiblePaths.contains(path) else {
                continue
            }
            guard inMemoryImages[path] == nil else {
                touch(path)
                continue
            }
            guard FileManager.default.fileExists(atPath: path) else {
                continue
            }

            inFlight.insert(path)
            generate(path: path)
        }
    }

    func prewarm(paths: [String]) {
        ensureInitialized()
        for path in paths {
            guard inMemoryImages[path] == nil else {
                continue
            }
            _ = image(for: path)
        }
    }

    func prune(validPaths: Set<String>) {
        ensureInitialized()

        let stale = Set(metadata.entries.keys).subtracting(validPaths)
        for path in stale {
            removeEntry(path)
        }

        inMemoryImages = inMemoryImages.filter { validPaths.contains($0.key) }
        inMemoryLastAccess = inMemoryLastAccess.filter { validPaths.contains($0.key) }
        visiblePaths = visiblePaths.filter { validPaths.contains($0) }
        pendingQueue = pendingQueue.filter { validPaths.contains($0) }
        inFlight = inFlight.filter { validPaths.contains($0) }

        persistMetadata()
        trimDiskIfNeeded()
        bumpRevision()
    }

    func clear() {
        ensureInitialized()

        let fileManager = FileManager.default
        let base = rootDirectoryURL()

        do {
            if fileManager.fileExists(atPath: base.path) {
                try fileManager.removeItem(at: base)
            }
            try fileManager.createDirectory(at: dataDirectoryURL(), withIntermediateDirectories: true)
        } catch {
            return
        }

        metadata = .init(version: 1, entries: [:])
        inMemoryImages.removeAll()
        inMemoryLastAccess.removeAll()
        visiblePaths.removeAll()
        pendingQueue.removeAll()
        inFlight.removeAll()
        persistMetadata()
        bumpRevision()
    }

    private func ensureInitialized() {
        guard !initialized else {
            return
        }
        initialized = true

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: dataDirectoryURL(), withIntermediateDirectories: true)
        } catch {
            metadata = .init(version: 1, entries: [:])
            return
        }

        let metadataURL = metadataFileURL()
        if let data = try? Data(contentsOf: metadataURL),
           let decoded = try? JSONDecoder().decode(Metadata.self, from: data),
           decoded.version == 1
        {
            metadata = decoded
        } else {
            metadata = .init(version: 1, entries: [:])
            persistMetadata()
        }
    }

    private func generate(path: String) {
        let url = URL(fileURLWithPath: path)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 480, height: 270),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let self else {
                return
            }

            if let cgImage = representation?.cgImage {
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                DispatchQueue.main.async {
                    self.finishGeneration(path: path, image: image)
                }
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let fallback = Self.generateFallbackThumbnail(path: path)
                DispatchQueue.main.async {
                    self.finishGeneration(path: path, image: fallback)
                }
            }
        }
    }

    private func finishGeneration(path: String, image: NSImage?) {
        if let image, visiblePaths.contains(path) {
            inMemoryImages[path] = image
            touch(path)
            trimInMemoryIfNeeded()
            writeToDisk(path: path, image: image)
        }

        inFlight.remove(path)
        processQueue()
        bumpRevision()
    }

    private nonisolated static func generateFallbackThumbnail(path: String) -> NSImage? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 420, height: 236)
        let candidates = [0.2, 1.0]

        for seconds in candidates {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }

        return nil
    }

    private func writeToDisk(path: String, image: NSImage) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attributes[.size] as? NSNumber,
              let modifiedDate = attributes[.modificationDate] as? Date,
              let data = imageData(image)
        else {
            return
        }

        let fileName = "\(hashed(path)).jpg"
        let fileURL = dataDirectoryURL().appendingPathComponent(fileName)

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return
        }

        metadata.entries[path] = Entry(
            fileName: fileName,
            sourcePath: path,
            sourceSize: fileSize.uint64Value,
            sourceModifiedAt: modifiedDate.timeIntervalSince1970,
            lastAccessAt: Date().timeIntervalSince1970
        )
        persistMetadata()
        trimDiskIfNeeded()
    }

    private func imageData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    private func isSourceValid(path: String, entry: Entry) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attributes[.size] as? NSNumber,
              let modifiedDate = attributes[.modificationDate] as? Date
        else {
            return false
        }

        let sizeMatches = fileSize.uint64Value == entry.sourceSize
        let mtimeMatches = abs(modifiedDate.timeIntervalSince1970 - entry.sourceModifiedAt) < 0.001
        return sizeMatches && mtimeMatches
    }

    private func touch(_ path: String) {
        let now = Date().timeIntervalSince1970
        inMemoryLastAccess[path] = now
        if var entry = metadata.entries[path] {
            entry.lastAccessAt = now
            metadata.entries[path] = entry
            persistMetadata()
        }
    }

    private func removeEntry(_ path: String) {
        guard let entry = metadata.entries.removeValue(forKey: path) else {
            return
        }

        let fileURL = dataDirectoryURL().appendingPathComponent(entry.fileName)
        try? FileManager.default.removeItem(at: fileURL)

        inMemoryImages.removeValue(forKey: path)
        inMemoryLastAccess.removeValue(forKey: path)
        if let index = pendingQueue.firstIndex(of: path) {
            pendingQueue.remove(at: index)
        }
        inFlight.remove(path)
        visiblePaths.remove(path)
        persistMetadata()
    }

    private func trimInMemoryIfNeeded() {
        if inMemoryImages.count <= maxInMemoryCount {
            return
        }

        let removeCount = inMemoryImages.count - maxInMemoryCount
        let removable = inMemoryLastAccess.keys
            .filter { !visiblePaths.contains($0) }
            .sorted { (inMemoryLastAccess[$0] ?? .leastNormalMagnitude) < (inMemoryLastAccess[$1] ?? .leastNormalMagnitude) }

        for key in removable.prefix(removeCount) {
            inMemoryImages.removeValue(forKey: key)
            inMemoryLastAccess.removeValue(forKey: key)
        }
    }

    private func trimDiskIfNeeded() {
        let fileManager = FileManager.default
        var sizedEntries: [SizedEntry] = []
        var totalSize: UInt64 = 0

        for (path, entry) in metadata.entries {
            let fileURL = dataDirectoryURL().appendingPathComponent(entry.fileName)
            guard let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
                  let size = attrs[.size] as? NSNumber
            else {
                continue
            }
            let bytes = size.uint64Value
            totalSize += bytes
            sizedEntries.append(SizedEntry(path: path, entry: entry, bytes: bytes))
        }

        if totalSize <= maxDiskBytes {
            return
        }

        let sorted = sizedEntries.sorted { $0.entry.lastAccessAt < $1.entry.lastAccessAt }
        var overflow = totalSize - maxDiskBytes

        for item in sorted {
            if overflow == 0 {
                break
            }
            let fileURL = dataDirectoryURL().appendingPathComponent(item.entry.fileName)
            try? fileManager.removeItem(at: fileURL)
            metadata.entries.removeValue(forKey: item.path)
            inMemoryImages.removeValue(forKey: item.path)
            inMemoryLastAccess.removeValue(forKey: item.path)
            if overflow > item.bytes {
                overflow -= item.bytes
            } else {
                overflow = 0
            }
        }

        persistMetadata()
    }

    private func persistMetadata() {
        guard let data = try? JSONEncoder().encode(metadata) else {
            return
        }
        try? data.write(to: metadataFileURL(), options: .atomic)
    }

    private func rootDirectoryURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("LiveWallpaper", isDirectory: true)
            .appendingPathComponent("ThumbnailCache", isDirectory: true)
    }

    private func dataDirectoryURL() -> URL {
        rootDirectoryURL().appendingPathComponent("data", isDirectory: true)
    }

    private func metadataFileURL() -> URL {
        rootDirectoryURL().appendingPathComponent(metadataFileName)
    }

    private func hashed(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func bumpRevision() {
        revision += 1
    }
}

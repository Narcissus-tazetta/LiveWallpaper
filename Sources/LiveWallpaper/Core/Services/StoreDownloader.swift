import CryptoKit
import Foundation

/// Fetches a Store package to a temporary file, reporting progress and stopping once the
/// body crosses the size cap, then verifies its checksum off the main actor.
enum StoreDownloader {
    static func download(
        from url: URL,
        session: URLSession,
        maxBytes: Int64,
        expectedSHA256: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let observer = ProgressObserver(maxBytes: maxBytes, progress: progress)
        let downloaded: URL
        let response: URLResponse
        do {
            (downloaded, response) = try await session.download(from: url, delegate: observer)
        } catch let error as URLError where error.code == .cancelled {
            if let received = observer.oversizedBytes {
                throw StoreClientError.fileTooLarge(
                    sizeBytes: Int(received),
                    maxBytes: Int(maxBytes)
                )
            }
            throw error
        }
        // The async download API leaves its .tmp file for the caller to remove; renaming it
        // gives the importer a package extension and every failure path below one file to
        // clean up.
        let owned = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).lwpkg")
        try FileManager.default.moveItem(at: downloaded, to: owned)
        do {
            guard let http = response as? HTTPURLResponse,
                  (200 ..< 300).contains(http.statusCode)
            else {
                throw StoreClientError.invalidResponse
            }
            let size = try owned.regularFileSize()
            guard size <= maxBytes else {
                throw StoreClientError.fileTooLarge(sizeBytes: size, maxBytes: Int(maxBytes))
            }
            let actual = try await BlockingWork.run { try sha256Hex(ofFileAt: owned) }
            guard actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
                throw StoreClientError.checksumMismatch
            }
            return owned
        } catch {
            BlockingWork.removeInBackground(owned)
            throw error
        }
    }

    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private final class ProgressObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let maxBytes: Int64
        private let progress: @Sendable (Double) -> Void
        private let lock = NSLock()
        private var observation: NSKeyValueObservation?
        private var oversized: Int64?

        init(maxBytes: Int64, progress: @escaping @Sendable (Double) -> Void) {
            self.maxBytes = maxBytes
            self.progress = progress
        }

        var oversizedBytes: Int64? {
            lock.withLock { oversized }
        }

        func urlSession(_: URLSession, didCreateTask task: URLSessionTask) {
            let maxBytes = maxBytes
            let progress = progress
            let observation = task.progress.observe(\.fractionCompleted) { [
                weak self,
                weak task
            ] value, _ in
                guard let task else { return }
                // A server that lies about (or omits) Content-Length would otherwise fill
                // the disk before the size check after the download could run.
                let received = task.countOfBytesReceived
                let expected = task.countOfBytesExpectedToReceive
                if received > maxBytes || expected > maxBytes {
                    self?.lock.withLock { self?.oversized = max(received, expected) }
                    task.cancel()
                    return
                }
                progress(value.fractionCompleted)
            }
            lock.withLock { self.observation = observation }
        }
    }
}

import Foundation

/// Runs blocking file and process work away from the main actor.
///
/// GCD rather than `Task.detached`: a multi-gigabyte copy or an `unzip` can block for
/// minutes, and parking that long on a Swift concurrency thread starves the small
/// cooperative pool every other task in the app shares.
enum BlockingWork {
    static func run<T>(
        qos: DispatchQoS.QoSClass = .userInitiated,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await run(on: .global(qos: qos), work)
    }

    /// On a serial queue, calls run one after another in the order they were made.
    static func run<T>(
        on queue: DispatchQueue,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// Deletes a scratch directory without holding up the caller.
    static func removeInBackground(_ url: URL) {
        DispatchQueue.global(qos: .utility).async {
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                return
            } catch {
                AppLog.persistence.error(
                    "failed to remove scratch directory \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}

/// Runs a command-line tool to completion and keeps what it printed to stderr, so a
/// failure can be traced instead of only reporting an exit status.
enum ProcessRunner {
    struct Failure: LocalizedError {
        let executable: String
        let arguments: [String]
        let status: Int32
        let standardError: String

        var errorDescription: String? {
            let detail = standardError.isEmpty ? "" : ": \(standardError)"
            return "\(executable) exited with status \(status)\(detail)"
        }
    }

    /// The tail kept from stderr. Tools like unzip print one line per bad entry, and the
    /// last lines are the ones that explain why it stopped.
    static let keptStandardErrorBytes = 4096

    /// Blocks the calling thread. Call from `BlockingWork.run` or another background queue.
    static func runSynchronously(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        // Drained before waiting: a child that fills the pipe buffer (64 KB) would
        // otherwise block on write while we block on its exit.
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let tail = errorData.suffix(keptStandardErrorBytes)
            let message = String(decoding: tail, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(
                executable: executable,
                arguments: arguments,
                status: process.terminationStatus,
                standardError: message
            )
        }
    }

    static func run(_ executable: String, arguments: [String]) async throws {
        try await BlockingWork.run {
            try runSynchronously(executable, arguments: arguments)
        }
    }
}

/// Carries a FileManager into `BlockingWork.run`. FileManager is not marked Sendable, though
/// Apple documents its methods as safe to call from any thread.
struct SendableFileManager: @unchecked Sendable {
    let manager: FileManager
}

import Foundation

/// Unchecked because FileManager is not marked Sendable, though Apple documents it as safe
/// to call from any thread; the only stored property is immutable.
final class PackageArchiveWriter: @unchecked Sendable {
    enum ArchiveError: LocalizedError {
        case zipCreationFailed(ProcessRunner.Failure)
        case moveFailed(Error)

        var errorDescription: String? {
            switch self {
            case let .zipCreationFailed(failure):
                return "ZIP creation failed: \(failure.localizedDescription)"
            case let .moveFailed(error):
                return "Failed to write package to destination: \(error.localizedDescription)"
            }
        }
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func createPackage(from contentDir: URL, outputURL: URL) async throws {
        try await BlockingWork.run { [self] in
            try createPackageSynchronously(from: contentDir, outputURL: outputURL)
        }
    }

    private func createPackageSynchronously(from contentDir: URL, outputURL: URL) throws {
        let outputDir = outputURL.deletingLastPathComponent()
        let tempOutputURL = outputDir.appendingPathComponent("\(UUID().uuidString).lwpkg")

        do {
            try ProcessRunner.runSynchronously(
                "/usr/bin/ditto",
                arguments: [
                    "-c",
                    "-k",
                    "--sequesterRsrc",
                    "--keepParent",
                    contentDir.path,
                    tempOutputURL.path
                ]
            )
        } catch let failure as ProcessRunner.Failure {
            AppLog.persistence
                .error("package archive failed: \(failure.localizedDescription, privacy: .public)")
            removePartialOutput(tempOutputURL)
            throw ArchiveError.zipCreationFailed(failure)
        }

        do {
            if fileManager.fileExists(atPath: outputURL.path) {
                _ = try fileManager.replaceItemAt(outputURL, withItemAt: tempOutputURL)
            } else {
                try fileManager.moveItem(at: tempOutputURL, to: outputURL)
            }
        } catch {
            removePartialOutput(tempOutputURL)
            throw ArchiveError.moveFailed(error)
        }
    }

    private func removePartialOutput(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            AppLog.persistence.error(
                "could not remove partial package \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

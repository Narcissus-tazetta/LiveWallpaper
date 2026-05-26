import Foundation

final class PackageArchiveWriter {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func createPackage(from contentDir: URL, outputURL: URL) throws {
        let outputDir = outputURL.deletingLastPathComponent()
        let tempOutputURL = outputDir.appendingPathComponent("\(UUID().uuidString).lwpkg")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = [
            "-c",
            "-k",
            "--sequesterRsrc",
            "--keepParent",
            contentDir.path,
            tempOutputURL.path
        ]
        try task.run()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            throw NSError(
                domain: "PackageExporter",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "ZIP creation failed"]
            )
        }

        do {
            if fileManager.fileExists(atPath: outputURL.path) {
                _ = try fileManager.replaceItemAt(outputURL, withItemAt: tempOutputURL)
            } else {
                try fileManager.moveItem(at: tempOutputURL, to: outputURL)
            }
        } catch {
            try? fileManager.removeItem(at: tempOutputURL)
            throw NSError(
                domain: "PackageExporter",
                code: -2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to write package to destination",
                    NSUnderlyingErrorKey: error
                ]
            )
        }
    }
}

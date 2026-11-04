@preconcurrency import AVFoundation
import Foundation

@MainActor
enum StoreSceneVideoCompressor {
    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession

        init(_ session: AVAssetExportSession) {
            self.session = session
        }
    }

    private static func otherContentBytes(in directory: URL, excluding videoURL: URL) throws -> Int {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        // Enumeration resolves macOS temporary-directory symlinks, unlike the input URL.
        let files = manager.enumerator(at: directory.resolvingSymlinksInPath(), includingPropertiesForKeys: Array(keys))!
        let videoPath = videoURL.resolvingSymlinksInPath().path
        var otherBytes = 0
        for case let file as URL in files where file.resolvingSymlinksInPath().path != videoPath {
            let values = try file.resourceValues(forKeys: keys)
            if values.isRegularFile == true { otherBytes += values.fileSize! }
        }
        return otherBytes
    }

    static func compressIfNeeded(videoURL: URL, contentDirectory: URL, maximumPackageBytes: Int) async throws {
        try Task.checkCancellation()
        let manager = FileManager.default
        let otherBytes = try otherContentBytes(in: contentDirectory, excluding: videoURL)
        let videoBytes = try manager.attributesOfItem(atPath: videoURL.path)[.size] as! Int
        // The thumbnail, manifest and ZIP records are added after this snapshot.
        let videoBudget = maximumPackageBytes - otherBytes - 1_048_576
        guard videoBudget > 0 else {
            throw StoreClientError.fileTooLarge(sizeBytes: otherBytes + videoBytes, maxBytes: maximumPackageBytes)
        }
        guard videoBytes > videoBudget else { return }

        let asset = AVURLAsset(url: videoURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw WallpaperTrimExporter.ExportError.sessionUnavailable
        }
        let temporary = videoURL.deletingLastPathComponent().appendingPathComponent(".store-\(UUID().uuidString).mp4")
        defer {
            if manager.fileExists(atPath: temporary.path) {
                do { try manager.removeItem(at: temporary) }
                catch { AppLog.store.error("Store video cleanup failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
        session.outputURL = temporary
        session.outputFileType = .mp4
        session.fileLengthLimit = Int64(Double(videoBudget) * 0.9)
        session.shouldOptimizeForNetworkUse = true
        let box = SessionBox(session)
        let status: AVAssetExportSession.Status = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.session.exportAsynchronously {
                    continuation.resume(returning: box.session.status)
                }
            }
        } onCancel: {
            box.session.cancelExport()
        }
        try Task.checkCancellation()
        switch status {
        case .completed: break
        case .cancelled: throw CancellationError()
        default: throw session.error ?? WallpaperTrimExporter.ExportError.failed("Store video export failed")
        }
        // AVAssetExportSession's length limit is approximate; never package an overrun.
        let bytes = try manager.attributesOfItem(atPath: temporary.path)[.size] as! Int
        guard bytes <= videoBudget else {
            throw StoreClientError.fileTooLarge(sizeBytes: otherBytes + bytes, maxBytes: maximumPackageBytes)
        }
        _ = try manager.replaceItemAt(videoURL, withItemAt: temporary)
    }
}

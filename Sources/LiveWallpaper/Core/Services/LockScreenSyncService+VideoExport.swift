@preconcurrency import AVFoundation
import Foundation

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}

/// ロック画面用動画の mov 変換と、変換後アセットの妥当性検証。
struct AerialVideoExporter {
    private let fileManager: FileManager
    private let shouldValidatePreparedVideo: Bool

    init(fileManager: FileManager, shouldValidatePreparedVideo: Bool) {
        self.fileManager = fileManager
        self.shouldValidatePreparedVideo = shouldValidatePreparedVideo
    }

    func prepareVideo(from sourceURL: URL, to destinationURL: URL) async throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        if sourceURL.pathExtension.lowercased() == "mov" {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            try await validatePreparedVideo(at: destinationURL)
            return
        }

        let asset = AVURLAsset(url: sourceURL)
        do {
            try await exportVideo(asset, to: destinationURL, presetName: AVAssetExportPresetPassthrough)
        } catch {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.removeItem(at: destinationURL)
            }
            try await exportVideo(asset, to: destinationURL, presetName: AVAssetExportPresetHighestQuality)
        }
        try await validatePreparedVideo(at: destinationURL)
    }

    private func exportVideo(
        _ asset: AVURLAsset,
        to destinationURL: URL,
        presetName: String
    ) async throws {
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: presetName
        ) else {
            throw LockScreenSyncError.exportSessionUnavailable
        }
        exportSession.outputURL = destinationURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = false

        let exportSessionBox = ExportSessionBox(exportSession)
        try await withCheckedThrowingContinuation { continuation in
            exportSessionBox.session.exportAsynchronously {
                switch exportSessionBox.session.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    let message = exportSessionBox.session.error?.localizedDescription
                        ?? "動画の mov 変換に失敗しました。"
                    continuation.resume(throwing: LockScreenSyncError.exportFailed(message))
                default:
                    continuation.resume(
                        throwing: LockScreenSyncError.exportFailed("動画の mov 変換が完了しませんでした。")
                    )
                }
            }
        }
    }

    private func validatePreparedVideo(at url: URL) async throws {
        guard shouldValidatePreparedVideo else {
            return
        }
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        let isPlayable: Bool
        let videoTracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            isPlayable = try await asset.load(.isPlayable)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw LockScreenSyncError.invalidVideo("ロック画面用の動画を読み込めませんでした: \(error.localizedDescription)")
        }

        guard isPlayable else {
            throw LockScreenSyncError.invalidVideo("ロック画面用の動画を再生可能として読み込めませんでした。")
        }
        guard duration.seconds.isFinite, duration.seconds >= 1.0 else {
            throw LockScreenSyncError.invalidVideo("ロック画面用の動画が短すぎるか、長さを読み取れませんでした。")
        }
        guard !videoTracks.isEmpty else {
            throw LockScreenSyncError.invalidVideo("ロック画面用の動画に映像トラックがありません。")
        }
    }
}

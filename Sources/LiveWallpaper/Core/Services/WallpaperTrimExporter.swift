import AVFoundation
import Foundation

/// カット範囲だけを含む動画ファイルを書き出す。
///
/// アプリ内のトリムは非破壊(再生範囲のメタデータ)なので、元ファイルは丸ごと
/// ディスクに残り、Storeへ共有すると使わない部分まで送ることになる。ここで
/// 実ファイルへ焼き込めば、容量もアップロード量も削れる。
///
/// 既定は **パススルー**(再エンコードなし)。画質を一切落とさず一瞬で終わる
/// 代わりに、切れる位置は最寄りのキーフレームへ寄る(だからこそ編集画面の
/// 「キーフレームに吸着」と相性が良い)。1フレーム単位で正確に切りたい場合だけ
/// 再エンコードを選ぶ。
enum WallpaperTrimExporter {
    enum Preset {
        /// 再エンコードなし。高速・無劣化だが、切れ目はキーフレーム境界。
        case passthrough
        /// 再エンコードあり。要求どおりの位置で切れるが時間がかかる。
        case reEncode

        var presetName: String {
            switch self {
            case .passthrough: return AVAssetExportPresetPassthrough
            case .reEncode: return AVAssetExportPresetHighestQuality
            }
        }
    }

    enum ExportError: LocalizedError {
        case emptyRange
        case sessionUnavailable
        case unsupportedOutputType
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .emptyRange:
                return "書き出す範囲がありません"
            case .sessionUnavailable, .unsupportedOutputType:
                return "この動画は書き出しに対応していません"
            case .cancelled:
                return "書き出しを中止しました"
            case let .failed(reason):
                return reason
            }
        }
    }

    /// 書き出す範囲。`WallpaperLoopBuilder.loopEndGuard` のような再生用の
    /// 余白はここでは足さない — 再生を成立させるための保険であって、
    /// ファイルの内容から末尾を削る理由にはならないため。
    ///
    /// - Returns: 有効な範囲。長さが取れない/空なら nil。
    static func makeTimeRange(
        trimStart: Double,
        trimEnd: Double?,
        assetDuration: Double
    ) -> CMTimeRange? {
        guard assetDuration.isFinite, assetDuration > 0 else {
            return nil
        }
        let start = min(max(trimStart, 0), assetDuration)
        let end = min(trimEnd ?? assetDuration, assetDuration)
        guard end > start else {
            return nil
        }
        return CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: end - start, preferredTimescale: 600)
        )
    }

    /// 書き出し先の既定ファイル名。元の名前に範囲が分かる接尾辞を付けて、
    /// 元ファイルと取り違えないようにする。
    static func suggestedFileName(sourcePath: String, fileExtension: String) -> String {
        let base = (sourcePath as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        let safeStem = stem.isEmpty ? "wallpaper" : stem
        return "\(safeStem)-trimmed.\(fileExtension)"
    }

    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession

        init(_ session: AVAssetExportSession) {
            self.session = session
        }
    }

    /// 書き出しを実行する。呼び出し元の `Task` をキャンセルすると、進行中の
    /// エクスポートも中断して途中ファイルを片付ける。
    /// - Parameter progress: 0...1。メインアクター上で呼ばれる。
    static func export(
        sourcePath: String,
        destination: URL,
        timeRange: CMTimeRange,
        preset: Preset,
        progress: @MainActor @escaping (Double) -> Void
    ) async throws {
        guard timeRange.duration.seconds > 0 else {
            throw ExportError.emptyRange
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: sourcePath))
        guard
            let session = AVAssetExportSession(asset: asset, presetName: preset.presetName)
        else {
            throw ExportError.sessionUnavailable
        }

        let outputFileType = resolveOutputFileType(
            session: session,
            destination: destination
        )
        guard let outputFileType else {
            throw ExportError.unsupportedOutputType
        }

        // 一時ファイルへ書いてから差し替える。途中で失敗したときに、書き出し先の
        // 既存ファイルを壊れた状態で残さないため。
        let tmpURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).exporting")
        try? FileManager.default.removeItem(at: tmpURL)

        session.outputURL = tmpURL
        session.outputFileType = outputFileType
        session.timeRange = timeRange
        session.shouldOptimizeForNetworkUse = false

        let box = SessionBox(session)
        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                progress(Double(box.session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer {
            progressTask.cancel()
        }

        let status: AVAssetExportSession.Status = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.session.exportAsynchronously {
                    continuation.resume(returning: box.session.status)
                }
            }
        } onCancel: {
            box.session.cancelExport()
        }

        switch status {
        case .completed:
            break
        case .cancelled:
            try? FileManager.default.removeItem(at: tmpURL)
            throw ExportError.cancelled
        default:
            let reason = box.session.error?.localizedDescription ?? "unknown"
            try? FileManager.default.removeItem(at: tmpURL)
            throw ExportError.failed(reason)
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw ExportError.failed(error.localizedDescription)
        }
        await progress(1)
    }

    /// 拡張子から出力形式を決める。その形式をプリセットが吐けない場合
    /// (パススルーは元のトラック構成に依存する)は、対応している方へ倒す。
    private static func resolveOutputFileType(
        session: AVAssetExportSession,
        destination: URL
    ) -> AVFileType? {
        let supported = session.supportedFileTypes
        let preferred: AVFileType =
            destination.pathExtension.lowercased() == "mov" ? .mov : .mp4
        if supported.contains(preferred) {
            return preferred
        }
        return supported.first { $0 == .mp4 || $0 == .mov } ?? supported.first
    }

    /// 出力に使える拡張子。パススルーで mp4 を吐けない動画(ProResなど)を
    /// 保存パネルの時点で .mov へ寄せられるようにする。
    static func preferredFileExtension(sourcePath: String, preset: Preset) -> String {
        let asset = AVURLAsset(url: URL(fileURLWithPath: sourcePath))
        guard let session = AVAssetExportSession(asset: asset, presetName: preset.presetName) else {
            return "mp4"
        }
        return session.supportedFileTypes.contains(.mp4) ? "mp4" : "mov"
    }
}

import AVFoundation
import CoreGraphics
import Foundation

/// トリム編集バーの背景に敷く等間隔サムネイル列を生成する。単発フレーム取得の
/// `VideoFrameCapture`、ベストショット探索の `VideoThumbnailGenerator` とは異なり、
/// 「動画全体を frameCount 等分した時刻のフレームをまとめて」必要とするため、
/// 1枚ずつ同期デコードするのではなく `generateCGImagesAsynchronously` の一括
/// リクエストを使う。
enum TrimFilmstripGenerator {
    /// `duration` を `frameCount` 個の時刻に等分してフレームを抽出する。
    /// 配列のインデックスは要求した時刻の順序と一致し、デコードに失敗した
    /// コマは nil のまま返す(呼び出し側がプレースホルダ表示を継続できるように)。
    static func generateFilmstrip(
        path: String,
        duration: Double,
        frameCount: Int,
        thumbnailHeight: CGFloat
    ) async -> [CGImage?] {
        guard duration > 0, frameCount > 0 else {
            return []
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let images = generateFramesSynchronously(
                    path: path,
                    duration: duration,
                    frameCount: frameCount,
                    thumbnailHeight: thumbnailHeight
                )
                continuation.resume(returning: images)
            }
        }
    }

    private nonisolated static func generateFramesSynchronously(
        path: String,
        duration: Double,
        frameCount: Int,
        thumbnailHeight: CGFloat
    ) -> [CGImage?] {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: .greatestFiniteMagnitude, height: thumbnailHeight * 2)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        let cmTimes = (0 ..< frameCount).map { index -> CMTime in
            let ratio = frameCount > 1 ? Double(index) / Double(frameCount - 1) : 0
            let seconds = min(ratio * duration, max(duration - 0.05, 0))
            return CMTime(seconds: seconds, preferredTimescale: 600)
        }

        // generateCGImagesAsynchronously はリクエスト順でコールバックする保証がなく、
        // 複数スレッドから並行に呼ばれうるため、書き込みは専用の直列キューに閉じ込める。
        var imagesByIndex: [Int: CGImage] = [:]
        let resultQueue = DispatchQueue(label: "TrimFilmstripGenerator.results")
        let group = DispatchGroup()
        for _ in cmTimes {
            group.enter()
        }

        generator.generateCGImagesAsynchronously(forTimes: cmTimes.map { NSValue(time: $0) }) {
            requestedTime, cgImage, _, _, _ in
            resultQueue.sync {
                if let index = cmTimes.firstIndex(where: { CMTimeCompare($0, requestedTime) == 0 }),
                   let cgImage
                {
                    imagesByIndex[index] = cgImage
                }
                group.leave()
            }
        }

        group.wait()
        return resultQueue.sync { (0 ..< frameCount).map { imagesByIndex[$0] } }
    }
}

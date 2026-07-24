import AVFoundation
import CoreGraphics
import Foundation

/// トリム編集バーの背景に敷く等間隔サムネイル列を生成する。単発フレーム取得の
/// `VideoFrameCapture`、ベストショット探索の `VideoThumbnailGenerator` とは異なり、
/// 「動画全体を frameCount 等分した時刻のフレームをまとめて」必要とするため、
/// 1枚ずつ同期デコードするのではなく `generateCGImagesAsynchronously` の一括
/// リクエストを使う。
enum TrimFilmstripGenerator {
    /// `startTime ..< startTime + duration` を `frameCount` 個の時刻に等分して
    /// フレームを抽出する。配列のインデックスは要求した時刻の順序と一致し、
    /// デコードに失敗したコマは nil のまま返す(呼び出し側がプレースホルダ表示を
    /// 継続できるように)。
    ///
    /// - Parameter startTime: 帯の左端が指す時刻。タイムラインを拡大している
    ///   ときは動画の先頭ではなく、今映している窓の開始位置になる。
    static func generateFilmstrip(
        path: String,
        startTime: Double = 0,
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
                    startTime: startTime,
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
        startTime: Double,
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

        // 各コマは「そのタイルが表す区間の中央」を狙う。等分点(0/n, 1/n, …)に
        // すると帯の左端が窓の開始位置ちょうどになり、1タイルぶん右へずれて
        // 見えるため。
        let cmTimes = (0 ..< frameCount).map { index -> CMTime in
            let ratio = (Double(index) + 0.5) / Double(frameCount)
            let seconds = max(startTime + ratio * duration, 0)
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

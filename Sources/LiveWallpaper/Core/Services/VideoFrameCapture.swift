import AVFoundation
import CoreGraphics
import Foundation

/// 動画ファイルの指定時刻を静止画として同期デコードする。壁紙が被覆されて
/// 一時停止する際のフリーズフレーム生成(共有プレイヤー・ディスプレイ固定の
/// 専用プレイヤーの両方)で使う共通実装。
enum VideoFrameCapture {
    /// This runs synchronously on the main thread right as the wallpaper gets
    /// covered, so it must stay cheap. A zero tolerance forces AVFoundation to
    /// decode every frame from the preceding sync sample up to the exact
    /// requested time, which can be a long stall on a long GOP. A ~1s window
    /// lets it snap to the nearest sync sample instead — imperceptible here
    /// since the frozen still is only shown while another app already covers
    /// the screen.
    static func capture(path: String, time: CMTime) -> CGImage? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        return try? generator.copyCGImage(at: time, actualTime: nil)
    }
}

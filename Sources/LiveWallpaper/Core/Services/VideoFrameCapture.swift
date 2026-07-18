import AVFoundation
import CoreGraphics
import Foundation

/// 動画ファイルの指定時刻を静止画として同期デコードする。壁紙が被覆されて
/// 一時停止する際のフリーズフレーム生成(共有プレイヤー・ディスプレイ固定の
/// 専用プレイヤーの両方)で使う共通実装。
///
/// 呼び出しは常にメインスレッド上の同期デコードなので、生成器を短期間だけ
/// キャッシュしてコンテナ(moov)の再パースを避ける。
@MainActor
enum VideoFrameCapture {
    /// 同時に抱える生成器の上限。1画面1生成器なので、マルチディスプレイでの
    /// Space切替(画面ごとに連続でキャプチャする)を一巡させられれば足りる。
    private static let cacheLimit = 3
    /// 最後に使ってからこの時間が経った生成器は捨てる。
    private static let cacheTTL: TimeInterval = 30

    private struct Entry {
        let generator: AVAssetImageGenerator
        var lastUsedAt: Date
    }

    private static var entriesByPath: [String: Entry] = [:]
    private static var evictionWorkItem: DispatchWorkItem?

    /// This runs synchronously on the main thread right as the wallpaper gets
    /// covered, so it must stay cheap. A zero tolerance forces AVFoundation to
    /// decode every frame from the preceding sync sample up to the exact
    /// requested time, which can be a long stall on a long GOP. A ~1s window
    /// lets it snap to the nearest sync sample instead — imperceptible here
    /// since the frozen still is only shown while another app already covers
    /// the screen.
    static func capture(path: String, time: CMTime) -> CGImage? {
        let generator = generator(for: path)
        scheduleEviction()
        return try? generator.copyCGImage(at: time, actualTime: nil)
    }

    /// Building the generator means opening the file and parsing its container,
    /// which dwarfs the single-frame decode that follows. Captures come in
    /// bursts — one per display on a Space switch, and repeatedly as the user
    /// covers/uncovers the wallpaper — so the same file is almost always asked
    /// for again moments later. Each live generator holds a decode session
    /// open, so the cache is deliberately small and short-lived rather than
    /// pinning decoders for a wallpaper that may not be captured again for
    /// hours; that would work against the deep-suspend path that exists
    /// precisely to hand those resources back.
    ///
    /// A generator caches the file's content, so replacing the file at `path`
    /// in place within the TTL would keep yielding the old frames. Nothing in
    /// the app writes over an existing registered path (imports and transcodes
    /// always pick a fresh destination), and the TTL bounds any external
    /// replacement to a stale still shown while the screen is already covered.
    private static func generator(for path: String) -> AVAssetImageGenerator {
        if var entry = entriesByPath[path] {
            entry.lastUsedAt = Date()
            entriesByPath[path] = entry
            return entry.generator
        }

        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        entriesByPath[path] = Entry(generator: generator, lastUsedAt: Date())
        evictLeastRecentlyUsedIfNeeded()
        return generator
    }

    private static func evictLeastRecentlyUsedIfNeeded() {
        while entriesByPath.count > cacheLimit {
            guard
                let oldest = entriesByPath.min(by: { $0.value.lastUsedAt < $1.value.lastUsedAt })
            else {
                return
            }
            entriesByPath.removeValue(forKey: oldest.key)
        }
    }

    private static func scheduleEviction() {
        guard evictionWorkItem == nil else {
            return
        }
        let workItem = DispatchWorkItem {
            MainActor.assumeIsolated {
                evictionWorkItem = nil
                evictExpired()
            }
        }
        evictionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + cacheTTL, execute: workItem)
    }

    private static func evictExpired() {
        let deadline = Date().addingTimeInterval(-cacheTTL)
        entriesByPath = entriesByPath.filter { $0.value.lastUsedAt > deadline }
        // まだ使われている生成器が残っているなら、その分だけ掃除を先送りする。
        guard !entriesByPath.isEmpty else {
            return
        }
        scheduleEviction()
    }
}

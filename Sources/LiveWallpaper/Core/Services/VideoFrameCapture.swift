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

    /// The still replaces the live frame the user last saw, so it must be that exact
    /// frame: any tolerance snaps to a nearby sync sample and the wallpaper visibly
    /// jumps back (up to ~1s) when it is covered or uncovered. The cost is decoding
    /// from the preceding sync sample on the main thread, measured at ~0.1s worst
    /// case on ordinary GOPs.
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
    ///
    /// Caching is gated on a successful decode: a generator built from a
    /// missing/unreadable path (e.g. a video removed mid Space-switch) would
    /// otherwise occupy one of only `cacheLimit` slots and evict a different
    /// display's still-valid, warm generator.
    static func capture(path: String, time: CMTime) -> CGImage? {
        if var entry = entriesByPath[path] {
            let requested = clampedToDuration(time, duration: entry.generator.asset.duration)
            let image: CGImage
            do {
                image = try entry.generator.copyCGImage(at: requested, actualTime: nil)
            } catch {
                // キャッシュ済みでもファイル消失等でデコードが失敗しうる。壊れた
                // 生成器は取り除き、有効な生成器の枠を守る。
                entriesByPath.removeValue(forKey: path)
                logFailure(path: path, time: requested, error: error)
                return nil
            }
            entry.lastUsedAt = Date()
            entriesByPath[path] = entry
            scheduleEviction()
            return image
        }

        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if #available(macOS 26, *) {
            // The still replaces a paused HDR video in the same layer; an SDR still would
            // visibly dim the wallpaper at every pause. The layer's preferredDynamicRange
            // (PlayerView.setHighDynamicRange) still tone-maps it when HDR display is off.
            // Earlier systems keep SDR: they have no per-layer switch to turn it back off.
            generator.dynamicRangePolicy = .matchSource
        }
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let requested = clampedToDuration(time, duration: asset.duration)
        let image: CGImage
        do {
            image = try generator.copyCGImage(at: requested, actualTime: nil)
        } catch {
            // デコード失敗時はキャッシュに載せない(欠落パスの生成器で有効枠を潰さない)。
            logFailure(path: path, time: requested, error: error)
            return nil
        }
        entriesByPath[path] = Entry(generator: generator, lastUsedAt: Date())
        evictLeastRecentlyUsedIfNeeded()
        scheduleEviction()
        return image
    }

    /// A play-once video leaves its player past the last frame (measured: timebase
    /// 160s on a 144s file), and a zero-tolerance decode beyond the end throws
    /// AVError -11832, which used to leave the paused wallpaper black.
    /// A non-numeric duration (not yet known) leaves the time unchanged.
    static func clampedToDuration(_ time: CMTime, duration: CMTime) -> CMTime {
        guard time.isNumeric, duration.isNumeric, CMTimeCompare(time, duration) > 0 else {
            return time
        }
        return duration
    }

    private static func logFailure(path: String, time: CMTime, error: Error) {
        AppLog.suspend.warning(
            "still capture failed file=\((path as NSString).lastPathComponent) t=\(time.seconds) error=\(error.localizedDescription)"
        )
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

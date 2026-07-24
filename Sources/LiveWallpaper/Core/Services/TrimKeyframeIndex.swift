import AVFoundation
import Foundation

/// 動画のキーフレーム(同期サンプル)時刻の索引と、そこへの吸着。
///
/// カット位置をキーフレームに合わせると
/// - ループの継ぎ目でデコードが前のGOPへ遡らずに済み、巻き戻りが滑らかになる
/// - パススルー書き出し(再エンコードなし)が要求どおりの位置で切れる
/// - シークが速く、正確になる
///
/// 索引の作成はサンプルを **デコードせずに** 走査する
/// (`AVAssetReaderSampleReferenceOutput`)ので、長尺でも実用的な速度で終わる。
enum TrimKeyframeIndex {
    /// 走査するサンプル数の上限。長尺・高フレームレートでもUIを待たせない
    /// ための保険で、打ち切った場合は途中までの索引を返す(吸着が効かなく
    /// なるだけで、編集自体は普通にできる)。
    static let sampleScanLimit = 500_000

    /// 吸着の許容誤差の下限/上限(秒)。画面上の距離から計算した値が極端に
    /// なるのを防ぐ。ズームアウト時に何秒も離れた位置へ飛ぶと、ユーザーには
    /// 「掴んだ場所と違うところに置かれた」としか見えない。
    static let minimumTolerance: Double = 0.02
    static let maximumTolerance: Double = 0.5

    private final class TrackBox: @unchecked Sendable {
        let asset: AVURLAsset
        let track: AVAssetTrack

        init(asset: AVURLAsset, track: AVAssetTrack) {
            self.asset = asset
            self.track = track
        }
    }

    /// 同期サンプルの表示時刻(秒・昇順)。読めなければ空配列。
    /// 空配列は「吸着しない」を意味するだけで、エラーとして扱う必要はない。
    static func loadKeyframeTimes(path: String) async -> [Double] {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard
            let tracks = try? await asset.loadTracks(withMediaType: .video),
            let track = tracks.first
        else {
            return []
        }
        let box = TrackBox(asset: asset, track: track)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: scan(box))
            }
        }
    }

    private static func scan(_ box: TrackBox) -> [Double] {
        guard let reader = try? AVAssetReader(asset: box.asset) else {
            return []
        }
        let output = AVAssetReaderSampleReferenceOutput(track: box.track)
        guard reader.canAdd(output) else {
            return []
        }
        reader.add(output)
        guard reader.startReading() else {
            return []
        }
        defer {
            reader.cancelReading()
        }

        var times: [Double] = []
        var scanned = 0
        while scanned < sampleScanLimit, let buffer = output.copyNextSampleBuffer() {
            scanned += 1
            guard isSyncSample(buffer) else {
                continue
            }
            let time = CMSampleBufferGetPresentationTimeStamp(buffer)
            guard time.isNumeric else {
                continue
            }
            times.append(time.seconds)
        }
        // 表示順とデコード順は一致しない(Bフレーム)ので必ず並べ直す。
        return times.sorted()
    }

    /// サンプル添付の `NotSync` が立っていなければ同期サンプル。添付そのものが
    /// 無いフォーマット(全フレームがキーフレーム)も同期サンプル扱いになる。
    private static func isSyncSample(_ buffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                buffer,
                createIfNecessary: false
            ) as? [[CFString: Any]],
            let first = attachments.first,
            let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool
        else {
            return true
        }
        return !notSync
    }

    /// `tolerance` 秒以内に最寄りのキーフレームがあればその時刻へ吸着させる。
    /// 無ければ元の時刻をそのまま返す(= 吸着は「近ければ効く」補助であって、
    /// 常にキーフレームへ強制するものではない)。
    static func snapped(_ time: Double, to keyframes: [Double], tolerance: Double) -> Double {
        guard time.isFinite, tolerance > 0, !keyframes.isEmpty else {
            return time
        }
        // keyframes は昇順。time の挿入位置の前後2つだけが最寄り候補になる。
        var low = 0
        var high = keyframes.count
        while low < high {
            let mid = (low + high) / 2
            if keyframes[mid] < time {
                low = mid + 1
            } else {
                high = mid
            }
        }

        var best: Double?
        for index in [low - 1, low] where index >= 0 && index < keyframes.count {
            let candidate = keyframes[index]
            if best == nil || abs(candidate - time) < abs((best ?? 0) - time) {
                best = candidate
            }
        }
        guard let best, abs(best - time) <= tolerance else {
            return time
        }
        return best
    }
}

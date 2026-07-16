import Foundation

/// 専用プレイヤー(Space別/ディスプレイ別)の隣接ウォームキャッシュを計算する純粋関数群。
/// AVFoundation/AppKit に依存しないため単体テスト可能。
///
/// `current`/`order` は Space UUID の並びにも、画面のプレイリスト動画パスの並びにも
/// 同じロジックをそのまま適用できるよう、文字列として抽象化している。
enum DedicatedPlayerWarmWindow {
    /// `order` の中で `current` の左右に隣接する要素。端ではラップアラウンドしない
    /// (実際のスワイプ/次へ・前へ操作も端で止まるため、体感と一致させる)。
    static func neighbors(current: String, order: [String]) -> (left: String?, right: String?) {
        guard let index = order.firstIndex(of: current) else {
            return (nil, nil)
        }
        let left = index > 0 ? order[index - 1] : nil
        let right = index < order.count - 1 ? order[index + 1] : nil
        return (left, right)
    }

    /// 現在温存中の集合(`existing`)を欲しい集合(`desired`)へ揃えるための差分。
    static func diff(desired: Set<String>, existing: Set<String>) -> (toCreate: Set<String>, toEvict: Set<String>) {
        (toCreate: desired.subtracting(existing), toEvict: existing.subtracting(desired))
    }
}

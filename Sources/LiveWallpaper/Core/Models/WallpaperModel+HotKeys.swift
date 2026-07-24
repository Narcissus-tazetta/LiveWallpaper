import Foundation

/// グローバルホットキーの設定状態。実際の Carbon 登録は AppDelegate 側
/// (AppDelegate+HotKeys)が、ここの @Published を監視して行う。
@MainActor
extension WallpaperModel {
    private static let hotKeysEnabledKey = "hotKeysEnabled"
    private static let hotKeyCombosKey = "hotKeyCombos"

    /// 起動時の復元。保存済みの割り当てを読み込み、無い操作は既定値で埋める。
    func restoreHotKeysState() {
        hotKeysEnabled = UserDefaults.standard.object(forKey: Self.hotKeysEnabledKey) as? Bool ?? false

        var combos: [HotKeyAction: HotKeyCombo] = [:]
        if let data = UserDefaults.standard.data(forKey: Self.hotKeyCombosKey),
           let decoded = try? JSONDecoder().decode([String: HotKeyCombo].self, from: data)
        {
            for (rawAction, combo) in decoded {
                if let action = HotKeyAction(rawValue: rawAction) {
                    combos[action] = combo
                }
            }
        }
        for action in HotKeyAction.allCases where combos[action] == nil {
            combos[action] = action.defaultCombo
        }
        hotKeyCombos = combos
    }

    /// ある操作に割り当てられた組み合わせ。
    func hotKeyCombo(for action: HotKeyAction) -> HotKeyCombo? {
        hotKeyCombos[action]
    }

    /// ホットキー機能のオン/オフ。
    func setHotKeysEnabled(_ enabled: Bool) {
        guard hotKeysEnabled != enabled else {
            return
        }
        hotKeysEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.hotKeysEnabledKey)
    }

    /// 操作へキーを割り当てる。nil を渡すとその操作を無効化(未割り当て)にする。
    /// 同じ組み合わせを持つ他の操作があれば、2つの操作が同じキーを奪い合わない
    /// よう先にその操作から外す。
    func setHotKeyCombo(_ combo: HotKeyCombo?, for action: HotKeyAction) {
        if let combo {
            for otherAction in HotKeyAction.allCases
                where otherAction != action && hotKeyCombos[otherAction] == combo
            {
                hotKeyCombos.removeValue(forKey: otherAction)
            }
            hotKeyCombos[action] = combo
        } else {
            hotKeyCombos.removeValue(forKey: action)
        }
        persistHotKeyCombos()
    }

    /// 既定の組み合わせへ戻す。
    func resetHotKeyCombo(for action: HotKeyAction) {
        setHotKeyCombo(action.defaultCombo, for: action)
    }

    private func persistHotKeyCombos() {
        var encodable: [String: HotKeyCombo] = [:]
        for (action, combo) in hotKeyCombos {
            encodable[action.rawValue] = combo
        }
        if let data = try? JSONEncoder().encode(encodable) {
            UserDefaults.standard.set(data, forKey: Self.hotKeyCombosKey)
        }
    }
}

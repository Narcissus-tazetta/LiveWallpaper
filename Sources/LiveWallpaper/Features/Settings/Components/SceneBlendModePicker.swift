import SwiftUI

extension SettingsView {
    private static let sceneBlendModeGroups: [(title: String, modes: [SceneBlendMode])] = [
        ("", [.normal]),
        ("暗くする系", [.darken, .multiply, .colorBurn, .subtract, .minimum]),
        ("明るくする系", [.lighten, .screen, .colorDodge, .add, .maximum, .plus, .brighten, .glow]),
        ("コントラスト系", [.overlay, .softLight, .hardLight, .vividLight, .linearLight, .pinLight, .hardMix]),
        ("差・反転系", [.difference, .exclusion, .negation, .average, .reflect, .phoenix]),
        ("色の合成", [.hue, .saturation, .color, .luminosity, .tint]),
    ]

    func sceneBlendModeName(_ mode: SceneBlendMode) -> String {
        let key: String = switch mode {
        case .normal: "通常"
        case .multiply: "乗算"
        case .screen: "スクリーン"
        case .overlay: "オーバーレイ"
        case .add: "加算"
        case .darken: "比較(暗)"
        case .colorBurn: "焼き込みカラー"
        case .subtract: "減算"
        case .minimum: "最小値"
        case .lighten: "比較(明)"
        case .colorDodge: "覆い焼きカラー"
        case .maximum: "最大値"
        case .softLight: "ソフトライト"
        case .hardLight: "ハードライト"
        case .vividLight: "ビビッドライト"
        case .linearLight: "リニアライト"
        case .pinLight: "ピンライト"
        case .hardMix: "ハードミックス"
        case .difference: "差の絶対値"
        case .exclusion: "除外"
        case .reflect: "リフレクト"
        case .glow: "グロー"
        case .phoenix: "フェニックス"
        case .average: "平均"
        case .negation: "ネゲーション"
        case .hue: "色相"
        case .saturation: "彩度"
        case .color: "カラー"
        case .luminosity: "輝度"
        case .tint: "ティント"
        case .plus: "加算(アルファ)"
        case .brighten: "加算(下地乗算)"
        }
        return model.localizedString(key)
    }

    /// Every blend mode, grouped by what it does to the layers below.
    @ViewBuilder
    func sceneBlendModePickerContent() -> some View {
        ForEach(Self.sceneBlendModeGroups, id: \.title) { group in
            if group.title.isEmpty {
                ForEach(group.modes, id: \.self) { Text(sceneBlendModeName($0)).tag($0) }
            } else {
                Section(model.localizedString(group.title)) {
                    ForEach(group.modes, id: \.self) { Text(sceneBlendModeName($0)).tag($0) }
                }
            }
        }
    }
}

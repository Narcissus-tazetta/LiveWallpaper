import SwiftUI

/// One setting of a real-time effect as the inspector shows it.
struct SceneRealTimeField: Identifiable {
    enum Control {
        case slider(ClosedRange<Double>)
        /// Stored in radians, shown in degrees.
        case angle
        case toggle
        /// Stored values with their labels (localization keys).
        case choice([(value: Double, label: String)])
        /// Three keys holding red, green and blue, 0...1.
        case colour(green: String, blue: String)
    }

    let key: String
    /// Localization key.
    let label: String
    let control: Control
    /// Shown without opening the details.
    var isMain = false
    /// Shown only while this key is non-zero.
    var shownWhen: String?

    var id: String {
        key
    }

    /// The image the effect reads that the user can paint, other than its area.
    enum Paint {
        case flow
        case timeOffset
    }

    static func paints(for kind: SceneEffectKind) -> [Paint] {
        switch kind {
        case .travelingWaves: [.timeOffset]
        case .flowShake: [.flow, .timeOffset]
        case .flowMap: [.flow]
        default: []
        }
    }

    /// The settings of a real-time effect, main ones first.
    static func fields(for kind: SceneEffectKind) -> [SceneRealTimeField] {
        switch kind {
        case .travelingWaves:
            typealias Key = SceneEffect.WaveKey
            return [
                .init(key: Key.speed, label: "速さ", control: .slider(0 ... 20), isMain: true),
                .init(key: Key.scale, label: "細かさ", control: .slider(1 ... 300), isMain: true),
                .init(key: Key.amplitude, label: "強さ", control: .slider(0 ... 1), isMain: true),
                .init(key: Key.angle, label: "向き", control: .angle, isMain: true),
                .init(key: Key.exponent, label: "波の形", control: .slider(0.51 ... 4)),
                .init(key: Key.dual, label: "2 つ目の波を重ねる", control: .toggle),
                .init(key: Key.speed2, label: "2 つ目の速さ", control: .slider(0 ... 20), shownWhen: Key.dual),
                .init(key: Key.scale2, label: "2 つ目の細かさ", control: .slider(1 ... 300), shownWhen: Key.dual),
                .init(key: Key.angle2, label: "2 つ目の向き", control: .angle, shownWhen: Key.dual),
                .init(key: Key.exponent2, label: "2 つ目の波の形", control: .slider(0.51 ... 4), shownWhen: Key.dual),
                .init(key: Key.offset2, label: "2 つ目のずれ", control: .slider(-5 ... 5), shownWhen: Key.dual)
            ]
        case .flowShake:
            typealias Key = SceneEffect.FlowShakeKey
            return [
                .init(key: Key.speed, label: "速さ", control: .slider(0 ... 10), isMain: true),
                .init(key: Key.amplitude, label: "強さ", control: .slider(0 ... 0.5), isMain: true),
                .init(key: Key.side, label: "振れる側", control: .choice([(0, "両側"), (1, "前だけ"), (2, "後ろだけ")])),
                .init(key: Key.irregular, label: "不規則に揺らす", control: .toggle),
                .init(key: Key.frictionX, label: "行きの緩急", control: .slider(0.1 ... 5)),
                .init(key: Key.frictionY, label: "帰りの緩急", control: .slider(0.1 ... 5)),
                .init(key: Key.boundsMin, label: "使う振れ幅の下限", control: .slider(0 ... 1)),
                .init(key: Key.boundsMax, label: "使う振れ幅の上限", control: .slider(0 ... 1))
            ]
        case .flowMap:
            typealias Key = SceneEffect.FlowMapKey
            return [
                .init(key: Key.speed, label: "速さ", control: .slider(0 ... 3), isMain: true),
                .init(key: Key.strength, label: "強さ", control: .slider(0 ... 10), isMain: true),
                .init(key: Key.feather, label: "つなぎ目のぼかし", control: .slider(0 ... 0.5)),
                .init(key: Key.phaseScale, label: "まだらの細かさ", control: .slider(0 ... 10))
            ]
        case .normalRipples:
            typealias Key = SceneEffect.RipplesKey
            return [
                .init(key: Key.animationSpeed, label: "速さ", control: .slider(0 ... 1), isMain: true),
                .init(key: Key.scale, label: "細かさ", control: .slider(0.1 ... 10), isMain: true),
                .init(key: Key.strength, label: "強さ", control: .slider(0 ... 0.5), isMain: true),
                .init(key: Key.ratio, label: "縦の細かさ", control: .slider(0.1 ... 10)),
                .init(key: Key.scrollSpeed, label: "流れる速さ", control: .slider(0 ... 1)),
                .init(key: Key.scrollAngle, label: "流れる向き", control: .angle),
                .init(key: Key.specular, label: "光の反射を足す", control: .toggle),
                .init(key: Key.specularStrength, label: "反射の強さ", control: .slider(0 ... 5), shownWhen: Key.specular),
                .init(key: Key.specularPower, label: "反射の鋭さ", control: .slider(0.1 ... 10), shownWhen: Key.specular),
                .init(
                    key: Key.specularRed, label: "反射の色",
                    control: .colour(green: Key.specularGreen, blue: Key.specularBlue), shownWhen: Key.specular
                )
            ]
        case .noiseDrift:
            typealias Key = SceneEffect.NoiseDriftKey
            return [
                .init(key: Key.speed, label: "速さ", control: .slider(0 ... 0.1), isMain: true),
                .init(key: Key.amount, label: "強さ", control: .slider(0 ... 0.2), isMain: true),
                .init(key: Key.angle, label: "向き", control: .angle, isMain: true),
                .init(key: Key.scale, label: "細かさ", control: .slider(0.5 ... 4)),
                .init(key: Key.scaleX, label: "横の細かさ", control: .slider(0.1 ... 1))
            ]
        case .noiseSway:
            typealias Key = SceneEffect.NoiseSwayKey
            return [
                .init(key: Key.speed, label: "速さ", control: .slider(0 ... 10), isMain: true),
                .init(key: Key.strength, label: "強さ", control: .slider(0 ... 1), isMain: true),
                .init(key: Key.angle, label: "向き", control: .angle, isMain: true),
                .init(key: Key.phase, label: "場所ごとのずれ", control: .slider(0 ... 2)),
                .init(key: Key.power, label: "揺れの鋭さ", control: .slider(0.1 ... 4)),
                .init(key: Key.noiseScale, label: "まだらの細かさ", control: .slider(0.01 ... 0.5)),
                .init(key: Key.ratio, label: "縦横の揺れの比", control: .slider(0.05 ... 2))
            ]
        case .pulseBlend:
            typealias Key = SceneEffect.PulseKey
            return [
                .init(key: Key.speed, label: "速さ", control: .slider(0 ... 10), isMain: true),
                .init(key: Key.amount, label: "強さ", control: .slider(0 ... 2), isMain: true),
                .init(
                    key: Key.highRed, label: "明るい時の色",
                    control: .colour(green: Key.highGreen, blue: Key.highBlue), isMain: true
                ),
                .init(key: Key.blendMode, label: "合成", control: .choice(pulseBlendModes), isMain: true),
                .init(key: Key.lowRed, label: "暗い時の色", control: .colour(green: Key.lowGreen, blue: Key.lowBlue)),
                .init(key: Key.phase, label: "始まりのずれ", control: .slider(0 ... 6.282)),
                .init(key: Key.boundsMin, label: "使う振れ幅の下限", control: .slider(0 ... 1)),
                .init(key: Key.boundsMax, label: "使う振れ幅の上限", control: .slider(0 ... 1)),
                .init(key: Key.power, label: "明滅の鋭さ", control: .slider(0.1 ... 4)),
                .init(key: Key.noiseAmount, label: "ゆらぎの量", control: .slider(0 ... 2)),
                .init(key: Key.noiseSpeed, label: "ゆらぎの速さ", control: .slider(0 ... 1)),
                .init(key: Key.pulsesColor, label: "色を変える", control: .toggle),
                .init(key: Key.pulsesOpacity, label: "不透明度も変える", control: .toggle)
            ]
        case .uvScroll:
            typealias Key = SceneEffect.ScrollKey
            return [
                .init(key: Key.speedX, label: "横の速さ", control: .slider(-2 ... 2), isMain: true),
                .init(key: Key.speedY, label: "縦の速さ", control: .slider(-2 ... 2), isMain: true),
                .init(key: Key.repeatX, label: "横の繰り返し", control: .slider(0.1 ... 10)),
                .init(key: Key.repeatY, label: "縦の繰り返し", control: .slider(0.1 ... 10))
            ]
        case .axisSwing:
            typealias Key = SceneEffect.AxisSwingKey
            return [
                .init(key: Key.speed, label: "速さ", control: .slider(0 ... 10), isMain: true),
                .init(key: Key.amount, label: "強さ", control: .slider(0 ... 1), isMain: true),
                .init(key: Key.size, label: "しなる幅", control: .slider(0 ... 1), isMain: true),
                .init(key: Key.x0, label: "軸の始まり (横)", control: .slider(0 ... 1)),
                .init(key: Key.y0, label: "軸の始まり (縦)", control: .slider(0 ... 1)),
                .init(key: Key.x1, label: "軸の終わり (横)", control: .slider(0 ... 1)),
                .init(key: Key.y1, label: "軸の終わり (縦)", control: .slider(0 ... 1)),
                .init(key: Key.center, label: "支点", control: .slider(0 ... 1)),
                .init(key: Key.feather, label: "ぼかし", control: .slider(0 ... 0.5)),
                .init(key: Key.phase, label: "始まりのずれ", control: .slider(0 ... 1)),
                .init(key: Key.doubleSided, label: "軸の両側をしならせる", control: .toggle),
                .init(key: Key.noise, label: "ゆらぎを足す", control: .toggle),
                .init(key: Key.noiseAmount, label: "ゆらぎの量", control: .slider(0 ... 1), shownWhen: Key.noise),
                .init(key: Key.noiseSpeed, label: "ゆらぎの速さ", control: .slider(0 ... 1), shownWhen: Key.noise)
            ]
        default:
            return []
        }
    }

    /// The blend modes offered for the pulse; a scene can hold any of 0...32, and a
    /// value not listed shows as its number.
    static let pulseBlendModes: [(value: Double, label: String)] = [
        (0, "通常"), (2, "乗算"), (7, "スクリーン"), (11, "オーバーレイ"), (9, "加算"), (1, "比較(暗)"), (6, "比較(明)"),
        (12, "ソフトライト"), (18, "差の絶対値")
    ]
}

extension SceneEditorView {
    @ViewBuilder
    func sceneRealTimeEffectInspector(path: String, layerID: UUID, effect: SceneEffect) -> some View {
        let fields = SceneRealTimeField.fields(for: effect.kind)
            .filter { field in field.shownWhen.map { effect.value($0) != 0 } ?? true }
        ForEach(fields.filter(\.isMain)) { field in
            sceneRealTimeFieldRow(field, path: path, layerID: layerID, effect: effect)
        }
        ForEach(SceneRealTimeField.paints(for: effect.kind), id: \.self) { paint in
            sceneRealTimePaintRow(paint, path: path, layerID: layerID, effect: effect)
        }
        let details = fields.filter { !$0.isMain }
        if !details.isEmpty {
            DisclosureGroup(model.localizedString("詳細")) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(details) { field in
                        sceneRealTimeFieldRow(field, path: path, layerID: layerID, effect: effect)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func sceneRealTimeFieldRow(
        _ field: SceneRealTimeField, path: String, layerID: UUID, effect: SceneEffect
    ) -> some View {
        let title = model.localizedString(field.label)
        let value = sceneEffectValueBinding(path: path, layerID: layerID, effect: effect, key: field.key)
        HStack(spacing: 12) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: sceneEffectLabelWidth, alignment: .leading)
            switch field.control {
            case let .slider(range):
                Slider(value: value, in: range)
                    .accessibilityLabel(title)
                    .accessibilityValue(Self.realTimeNumber(value.wrappedValue))
                Text(Self.realTimeNumber(value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 48, alignment: .trailing)
            case .angle:
                let degrees = Binding(
                    get: { (value.wrappedValue * 180 / .pi).truncatingRemainder(dividingBy: 360) + (value.wrappedValue < 0 ? 360 : 0) },
                    set: { value.wrappedValue = $0 * .pi / 180 }
                )
                Slider(value: degrees, in: 0 ... 359)
                    .accessibilityLabel(title)
                    .accessibilityValue("\(Int(degrees.wrappedValue.rounded()))°")
                Text("\(Int(degrees.wrappedValue.rounded()))°")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 48, alignment: .trailing)
            case .toggle:
                Toggle(title, isOn: Binding(get: { value.wrappedValue != 0 }, set: { value.wrappedValue = $0 ? 1 : 0 }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                Spacer(minLength: 0)
            case let .choice(options):
                Picker(title, selection: value) {
                    ForEach(options, id: \.value) { option in
                        Text(model.localizedString(option.label)).tag(option.value)
                    }
                    if !options.contains(where: { $0.value == value.wrappedValue }) {
                        Text(String(format: model.localizedString("その他 (%d)"), locale: model.appLocale, Int(value.wrappedValue)))
                            .tag(value.wrappedValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: SceneInspectorMetrics.menuMaxWidth)
                Spacer(minLength: 0)
            case let .colour(greenKey, blueKey):
                let green = sceneEffectValueBinding(path: path, layerID: layerID, effect: effect, key: greenKey)
                let blue = sceneEffectValueBinding(path: path, layerID: layerID, effect: effect, key: blueKey)
                ColorPicker(
                    title,
                    selection: Binding(
                        get: {
                            Color(.sRGB, red: value.wrappedValue, green: green.wrappedValue, blue: blue.wrappedValue)
                        },
                        set: { colour in
                            guard let components = NSColor(colour).usingColorSpace(.sRGB) else {
                                return
                            }
                            value.wrappedValue = Double(components.redComponent)
                            green.wrappedValue = Double(components.greenComponent)
                            blue.wrappedValue = Double(components.blueComponent)
                        }
                    ),
                    supportsOpacity: false
                )
                .labelsHidden()
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func sceneRealTimePaintRow(
        _ paint: SceneRealTimeField.Paint, path: String, layerID: UUID, effect: SceneEffect
    ) -> some View {
        switch paint {
        case .flow:
            HStack(spacing: 12) {
                Text(model.localizedString("流れる向き"))
                    .frame(width: sceneEffectLabelWidth, alignment: .leading)
                Button(model.localizedString(effect.flowFile == nil ? "向きを描く" : "描き直す")) {
                    beginScenePainting(path: path, layerID: layerID, effect: effect, kind: .flow)
                }
                Spacer(minLength: 0)
            }
            if effect.flowFile == nil {
                settingsFootnote(model.localizedString("向きを描くまでは動きません。"))
            }
        case .timeOffset:
            HStack(spacing: 12) {
                Text(model.localizedString("時間差"))
                    .frame(width: sceneEffectLabelWidth, alignment: .leading)
                Button(model.localizedString(effect.timeOffsetFile == nil ? "時間差を塗る" : "塗り直す")) {
                    beginScenePainting(path: path, layerID: layerID, effect: effect, kind: .timeOffset)
                }
                if effect.timeOffsetFile != nil {
                    Button(model.localizedString("時間差をなくす")) {
                        endSceneEditorTool()
                        model.setScenePaintFile(nil, kind: .timeOffset, effectID: effect.id, layerID: layerID, path: path)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    func sceneEffectValueBinding(path: String, layerID: UUID, effect: SceneEffect, key: String) -> Binding<Double> {
        Binding(
            get: { effect.value(key) },
            set: { newValue in
                updateSceneEffect(path: path, layerID: layerID, effectID: effect.id) { $0.values[key] = newValue }
            }
        )
    }

    /// Up to three decimals, without trailing zeros.
    static func realTimeNumber(_ value: Double) -> String {
        let text = String(format: "%.3f", value)
        return text.contains(".") ? String(text.reversed().drop { $0 == "0" }.reversed()).trimmingCharacters(in: CharacterSet(charactersIn: ".")) : text
    }
}

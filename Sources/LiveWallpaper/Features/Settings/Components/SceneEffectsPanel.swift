import SwiftUI

/// What the preview is being used for while editing an effect.
enum SceneEditorTool: Equatable {
    case paint(effectID: UUID, kind: ScenePaintOverride.Target)
    case pickCenter(effectID: UUID)
    /// Each click on the preview adds a puppet pin.
    case addPins(effectID: UUID)
}

extension SettingsView {
    var sceneEffectLabelWidth: CGFloat {
        132
    }

    func sceneEffectName(_ kind: SceneEffectKind) -> String {
        switch kind {
        case .shake: model.localizedString("揺れ")
        case .sway: model.localizedString("風にそよぐ")
        case .swing: model.localizedString("振り子")
        case .waves: model.localizedString("波")
        case .ripple: model.localizedString("波紋")
        case .waterFlow: model.localizedString("水の流れ")
        case .scroll: model.localizedString("スクロール")
        case .cloudMotion: model.localizedString("雲の流れ")
        case .spin: model.localizedString("回転")
        case .twirl: model.localizedString("渦")
        case .pulse: model.localizedString("明滅")
        case .puppet: model.localizedString("パペット(ピン)")
        case .drift: model.localizedString("一方向に流す")
        case .travelingWaves: model.localizedString("進む波")
        case .flowShake: model.localizedString("流れに沿って揺らす")
        case .flowMap: model.localizedString("流れマップで流す")
        case .normalRipples: model.localizedString("法線マップのさざ波")
        case .noiseDrift: model.localizedString("ノイズでずらす")
        case .noiseSway: model.localizedString("ノイズでそよがせる")
        case .pulseBlend: model.localizedString("色の明滅")
        case .uvScroll: model.localizedString("速さを決めてスクロール")
        case .axisSwing: model.localizedString("軸でしならせる")
        case .opacityMask: model.localizedString("不透明度マスク")
        case .shader: model.localizedString("シェーダー効果")
        }
    }

    /// The preview interaction matching the current tool.
    func scenePreviewInteraction(layerID: UUID?) -> ScenePreviewInteraction {
        guard let layerID, let tool = sceneEditorTool else {
            return .arrange(selectedLayerID: layerID)
        }
        switch tool {
        case .paint:
            return .paint(layerID: layerID)
        case .pickCenter, .addPins:
            return .pickPoint(layerID: layerID)
        }
    }

    func handleScenePreviewPick(_ point: SIMD2<Float>, path: String, layerID: UUID) {
        if case let .addPins(effectID) = sceneEditorTool {
            var added: ScenePin?
            updateSceneEffect(path: path, layerID: layerID, effectID: effectID) { effect in
                guard effect.pins.count < ScenePin.maximumCount else {
                    return
                }
                // The first pins usually hold the picture; later ones move it.
                var pin = ScenePin(x: Double(point.x), y: Double(point.y), isAnchor: effect.pins.isEmpty)
                pin.direction = 90
                effect.pins.append(pin)
                added = pin
            }
            if let added {
                selectedScenePinID = added.id
            }
            return
        }
        guard case let .pickCenter(effectID) = sceneEditorTool else {
            return
        }
        updateSceneEffect(path: path, layerID: layerID, effectID: effectID) { effect in
            effect.centerX = Double(point.x)
            effect.centerY = Double(point.y)
        }
        sceneEditorTool = nil
    }

    func endSceneEditorTool() {
        sceneMaskPainter.end()
        sceneEditorTool = nil
    }

    // MARK: - Painting bar

    /// Shown under the preview while painting a mask, a time offset or a flow map.
    @ViewBuilder
    func scenePaintBar(kind: ScenePaintOverride.Target) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker(model.localizedString("ブラシ"), selection: $sceneMaskPainter.tool) {
                    Text(model.localizedString(kind.isGrey ? "塗る" : "向きを描く")).tag(SceneMaskPainter.Tool.paint)
                    Text(model.localizedString("消す")).tag(SceneMaskPainter.Tool.erase)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()

                Text(model.localizedString("筆の大きさ"))
                Slider(value: $sceneMaskPainter.brushSize, in: 0.01 ... 0.3)
                    .accessibilityLabel(model.localizedString("筆の大きさ"))
                Text(model.localizedString("硬さ"))
                Slider(value: $sceneMaskPainter.hardness, in: 0 ... 1)
                    .accessibilityLabel(model.localizedString("硬さ"))
            }
            HStack(spacing: 8) {
                if kind.isGrey {
                    Button(model.localizedString("全体を塗る")) {
                        sceneMaskPainter.fillAll()
                    }
                }
                Button(model.localizedString("すべて消す")) {
                    sceneMaskPainter.clearAll()
                }
                Spacer(minLength: 0)
                Button(model.localizedString("完了")) {
                    endSceneEditorTool()
                }
                .keyboardShortcut(.defaultAction)
            }
            settingsFootnote(model.localizedString(scenePaintHint(kind)))
        }
    }

    private func scenePaintHint(_ kind: ScenePaintOverride.Target) -> String {
        switch kind {
        case .mask: "プレビューの上をドラッグして、動かす範囲を塗ります。赤い部分だけが動きます。"
        case .flow: "プレビューの上を、流したい向きにドラッグします。青い部分が、なぞった向きに流れます。"
        case .timeOffset: "プレビューの上をドラッグして、動きをずらす所を塗ります。紫が濃い所ほど、動きが遅れて始まります。"
        }
    }

    // MARK: - Effect list

    @ViewBuilder
    func sceneEffectsSection(path: String, layer: SceneLayer) -> some View {
        let selectedID = layer.effects.contains(where: { $0.id == selectedSceneEffectID })
            ? selectedSceneEffectID
            : layer.effects.first?.id

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.localizedString("動き"))
                    .font(.headline)
                Spacer(minLength: 0)
                Menu {
                    Section(model.localizedString("揺れ")) {
                        sceneAddEffectButton(.shake, path: path, layerID: layer.id)
                        sceneAddEffectButton(.sway, path: path, layerID: layer.id)
                        sceneAddEffectButton(.swing, path: path, layerID: layer.id)
                    }
                    Section(model.localizedString("水")) {
                        sceneAddEffectButton(.waves, path: path, layerID: layer.id)
                        sceneAddEffectButton(.ripple, path: path, layerID: layer.id)
                        sceneAddEffectButton(.waterFlow, path: path, layerID: layer.id)
                    }
                    Section(model.localizedString("パペット")) {
                        sceneAddEffectButton(.puppet, path: path, layerID: layer.id)
                    }
                    Section(model.localizedString("流れ・回転・明滅")) {
                        sceneAddEffectButton(.scroll, path: path, layerID: layer.id)
                        sceneAddEffectButton(.drift, path: path, layerID: layer.id)
                        sceneAddEffectButton(.cloudMotion, path: path, layerID: layer.id)
                        sceneAddEffectButton(.spin, path: path, layerID: layer.id)
                        sceneAddEffectButton(.twirl, path: path, layerID: layer.id)
                        sceneAddEffectButton(.pulse, path: path, layerID: layer.id)
                    }
                    Section(model.localizedString("細かく設定できる動き")) {
                        // A shader effect needs a renderGraph only an import supplies; added by hand it would be empty.
                        ForEach(SceneEffectKind.allCases.filter { $0.runsOnRealTime && $0 != .shader }, id: \.self) { kind in
                            sceneAddEffectButton(kind, path: path, layerID: layer.id)
                        }
                    }
                } label: {
                    Label(model.localizedString("動きを追加"), systemImage: "plus")
                }
                .fixedSize()
            }

            if layer.effects.isEmpty {
                Text(model.localizedString("このレイヤーには動きがありません。「動きを追加」から選ぶと、塗った範囲だけを動かせます。"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(layer.effects) { effect in
                            sceneEffectRow(path: path, layerID: layer.id, effect: effect, isSelected: effect.id == selectedID)
                        }
                        HStack(spacing: 4) {
                            Button {
                                if let selectedID {
                                    removeSceneEffect(path: path, layerID: layer.id, effectID: selectedID)
                                }
                            } label: {
                                Image(systemName: "minus")
                            }
                            .disabled(selectedID == nil)
                            .help(model.localizedString("選択した動きを削除"))
                            .accessibilityLabel(model.localizedString("選択した動きを削除"))
                            Spacer(minLength: 0)
                            Button {
                                moveSceneEffect(path: path, layerID: layer.id, effectID: selectedID, by: -1)
                            } label: {
                                Image(systemName: "arrow.up")
                            }
                            .disabled(selectedID == nil || selectedID == layer.effects.first?.id)
                            .help(model.localizedString("先に掛ける"))
                            .accessibilityLabel(model.localizedString("先に掛ける"))
                            Button {
                                moveSceneEffect(path: path, layerID: layer.id, effectID: selectedID, by: 1)
                            } label: {
                                Image(systemName: "arrow.down")
                            }
                            .disabled(selectedID == nil || selectedID == layer.effects.last?.id)
                            .help(model.localizedString("後に掛ける"))
                            .accessibilityLabel(model.localizedString("後に掛ける"))
                        }
                        .buttonStyle(.borderless)
                    }
                    .frame(width: 240)

                    if let selectedID, let effect = layer.effects.first(where: { $0.id == selectedID }) {
                        sceneEffectInspector(path: path, layerID: layer.id, effect: effect)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func sceneAddEffectButton(_ kind: SceneEffectKind, path: String, layerID: UUID) -> some View {
        Button(sceneEffectName(kind)) {
            guard let effect = model.makeSceneEffect(kind, path: path) else {
                return
            }
            updateSceneLayerEffects(path: path, layerID: layerID) { $0.append(effect) }
            selectedSceneEffectID = effect.id
        }
    }

    private func sceneEffectRow(path: String, layerID: UUID, effect: SceneEffect, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Toggle(
                isOn: Binding(
                    get: { effect.isEnabled },
                    set: { value in
                        updateSceneEffect(path: path, layerID: layerID, effectID: effect.id) { $0.isEnabled = value }
                    }
                )
            ) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(model.localizedString("動きを有効にする"))
            .accessibilityValue(sceneEffectName(effect.kind))

            Button {
                selectedSceneEffectID = effect.id
            } label: {
                HStack(spacing: 6) {
                    Text(sceneEffectName(effect.kind))
                        .foregroundColor(effect.isEnabled ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if effect.maskFile != nil {
                        Image(systemName: "paintbrush.pointed")
                            .foregroundColor(.secondary)
                            .help(model.localizedString("塗った範囲だけ"))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sceneEffectName(effect.kind))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.1) : Color.clear)
        )
    }

    // MARK: - Inspector

    @ViewBuilder
    private func sceneEffectInspector(path: String, layerID: UUID, effect: SceneEffect) -> some View {
        let loopSeconds = model.sceneDocumentsByPath[path]?.loopSeconds ?? 20
        VStack(alignment: .leading, spacing: 8) {
            if effect.kind == .shader {
                settingsFootnote(model.localizedString("この効果は作品に含まれるシェーダーで描画します。範囲の描き直しには未対応です。"))
            } else {
            if effect.kind == .opacityMask {
                sceneEffectSlider(
                    title: model.localizedString("不透明度"),
                    value: sceneEffectValueBinding(path: path, layerID: layerID, effect: effect, key: "alpha"),
                    range: 0 ... 1
                )
            }
            if effect.kind.runsOnRealTime {
                sceneRealTimeEffectInspector(path: path, layerID: layerID, effect: effect)
            }
            if effect.kind.usesCycles {
            sceneEffectRow(title: model.localizedString("速さ")) {
                Stepper(
                    value: sceneEffectBinding(path: path, layerID: layerID, effect: effect, \.cycles),
                    in: SceneEffect.cyclesRange
                ) {
                    Text(String(
                        format: model.localizedString("ループ %1$d 秒の間に %2$d 回"), locale: model.appLocale,
                        loopSeconds, effect.cycles
                    ))
                    .font(.caption.monospacedDigit())
                }
                .accessibilityLabel(model.localizedString("速さ"))
            }
            }

            if effect.kind.usesStrength {
                sceneEffectSlider(
                    title: model.localizedString("強さ"),
                    value: sceneEffectBinding(path: path, layerID: layerID, effect: effect, \.strength),
                    range: 0 ... 1
                )
            }
            if effect.kind.usesScale {
                sceneEffectSlider(
                    title: model.localizedString(effect.kind == .twirl ? "範囲" : "細かさ"),
                    value: sceneEffectBinding(path: path, layerID: layerID, effect: effect, \.scale),
                    range: 0 ... 1
                )
            }
            if effect.kind.usesDirection {
                sceneEffectRow(title: model.localizedString("向き")) {
                    let direction = sceneEffectBinding(path: path, layerID: layerID, effect: effect, \.direction)
                    Group {
                        // Scrolling only loops in eight directions; a 1° step would
                        // draw 360 tick marks.
                        if effect.kind == .scroll {
                            Slider(value: direction, in: 0 ... 315, step: 45)
                        } else {
                            Slider(value: direction, in: 0 ... 359)
                        }
                    }
                    .accessibilityLabel(model.localizedString("向き"))
                    Text("\(Int(effect.direction))°")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            if effect.kind == .spin || effect.kind == .twirl {
                Toggle(
                    model.localizedString("逆向きに回す"),
                    isOn: sceneEffectBinding(path: path, layerID: layerID, effect: effect, \.reversed)
                )
            }
            if effect.kind.usesCenter {
                sceneEffectRow(title: model.localizedString("中心")) {
                    Button(model.localizedString(
                        sceneEditorTool == .pickCenter(effectID: effect.id) ? "プレビューをクリック…" : "プレビューで選ぶ"
                    )) {
                        sceneMaskPainter.end()
                        sceneEditorTool = sceneEditorTool == .pickCenter(effectID: effect.id)
                            ? nil : .pickCenter(effectID: effect.id)
                    }
                }
            }
            if effect.kind == .puppet {
                scenePuppetPins(path: path, layerID: layerID, effect: effect)
            }
            if effect.kind == .waterFlow {
                sceneEffectRow(title: model.localizedString("流れる向き")) {
                    Button(model.localizedString(effect.flowFile == nil ? "向きを描く" : "描き直す")) {
                        beginScenePainting(path: path, layerID: layerID, effect: effect, kind: .flow)
                    }
                }
                if effect.flowFile == nil {
                    settingsFootnote(model.localizedString("向きを描くまでは動きません。"))
                }
            }
            if effect.kind.usesFixedEdge {
                sceneEffectRow(title: model.localizedString("固定する側")) {
                    Picker(
                        model.localizedString("固定する側"),
                        selection: sceneEffectBinding(path: path, layerID: layerID, effect: effect, \.fixedEdge)
                    ) {
                        Text(model.localizedString("なし")).tag(SceneFixedEdge.none)
                        Text(model.localizedString("上")).tag(SceneFixedEdge.top)
                        Text(model.localizedString("下")).tag(SceneFixedEdge.bottom)
                        Text(model.localizedString("左")).tag(SceneFixedEdge.left)
                        Text(model.localizedString("右")).tag(SceneFixedEdge.right)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    Spacer(minLength: 0)
                }
                if effect.fixedEdge != .none {
                    settingsFootnote(model.localizedString("選んだ側は動かさず、反対側ほど大きく動かします。髪の根元や枝の付け根を押さえるのに使います。"))
                        .padding(.leading, sceneEffectLabelWidth + 12)
                }
            }
            sceneEffectRow(title: model.localizedString("範囲")) {
                Text(model.localizedString(effect.maskFile == nil ? "レイヤー全体" : "塗った範囲だけ"))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button(model.localizedString(effect.maskFile == nil ? "範囲を塗る" : "塗り直す")) {
                    beginScenePainting(path: path, layerID: layerID, effect: effect, kind: .mask)
                }
                if effect.maskFile != nil {
                    Button(model.localizedString("全体に戻す")) {
                        endSceneEditorTool()
                        model.setScenePaintFile(nil, kind: .mask, effectID: effect.id, layerID: layerID, path: path)
                    }
                }
            }
            .padding(.leading, sceneEffectLabelWidth + 12)
            if effect.maskFile != nil, effect.kind.canMoveOnItsOwnLayer,
               let owner = model.sceneDocumentsByPath[path]?.layers.first(where: { $0.id == layerID }),
               owner.kind == .image, owner.videoFile == nil
            {
                HStack(spacing: 8) {
                    Button(model.localizedString("塗った範囲を別のレイヤーにする")) {
                        moveScenePaintedArea(path: path, layerID: layerID, effectID: effect.id)
                    }
                    .disabled(model.sceneAIWork[layerID] != nil)
                    if model.sceneAIWork[layerID] == .separating {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.leading, sceneEffectLabelWidth + 12)
                settingsFootnote(model.localizedString("塗った範囲だけを動かすと、輪郭はその場に残ります。別のレイヤーにすると輪郭ごと動き、元のレイヤーの抜けた所は周りの色で埋めます。"))
                    .padding(.leading, sceneEffectLabelWidth + 12)
            }
            }
        }
    }

    /// Selects the new layer with the effect when the cut-out is done.
    func moveScenePaintedArea(path: String, layerID: UUID, effectID: UUID) {
        endSceneEditorTool()
        Task {
            guard let id = await model.moveScenePaintedAreaToOwnLayer(effectID: effectID, layerID: layerID, path: path),
                  fitEditor.resolvedVideoPath() == path
            else {
                return
            }
            selectSceneLayer(id)
            selectedSceneEffectID = effectID
        }
    }

    // MARK: - Puppet

    @ViewBuilder
    private func scenePuppetPins(path: String, layerID: UUID, effect: SceneEffect) -> some View {
        let isAdding = sceneEditorTool == .addPins(effectID: effect.id)
        sceneEffectRow(title: model.localizedString("ピン")) {
            Text(String(format: model.localizedString("%d 本"), locale: model.appLocale, effect.pins.count))
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
            Button(model.localizedString(isAdding ? "追加を終える" : "ピンを追加")) {
                sceneMaskPainter.end()
                sceneEditorTool = isAdding ? nil : .addPins(effectID: effect.id)
            }
        }
        if effect.pins.isEmpty {
            settingsFootnote(model.localizedString("固定するピンで動かさない所を押さえ、揺らすピンで動かしたい所を指定します。ピンが無い間は動きません。"))
        }
        ForEach(Array(effect.pins.enumerated()), id: \.element.id) { index, pin in
            let isSelected = pin.id == selectedScenePinID
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button {
                        selectedScenePinID = isSelected ? nil : pin.id
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: pin.isAnchor ? "pin.fill" : "waveform.path")
                                .foregroundColor(.secondary)
                            Text(String(format: model.localizedString("ピン %d"), locale: model.appLocale, index + 1))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    Picker(
                        model.localizedString("ピンの種類"),
                        selection: scenePinBinding(path: path, layerID: layerID, effectID: effect.id, pin: pin, \.isAnchor)
                    ) {
                        Text(model.localizedString("固定")).tag(true)
                        Text(model.localizedString("揺らす")).tag(false)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    Button {
                        updateSceneEffect(path: path, layerID: layerID, effectID: effect.id) { effect in
                            effect.pins.removeAll { $0.id == pin.id }
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(model.localizedString("ピンを削除"))
                    .accessibilityLabel(model.localizedString("ピンを削除"))
                }
                if isSelected, !pin.isAnchor {
                    sceneEffectSlider(
                        title: model.localizedString("揺れ幅"),
                        value: scenePinBinding(path: path, layerID: layerID, effectID: effect.id, pin: pin, \.amount),
                        range: 0 ... 1
                    )
                    sceneEffectRow(title: model.localizedString("向き")) {
                        Slider(
                            value: scenePinBinding(path: path, layerID: layerID, effectID: effect.id, pin: pin, \.direction),
                            in: 0 ... 359
                        )
                        .accessibilityLabel(model.localizedString("向き"))
                        Text("\(Int(pin.direction))°")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    sceneEffectSlider(
                        title: model.localizedString("タイミングのずれ"),
                        value: scenePinBinding(path: path, layerID: layerID, effectID: effect.id, pin: pin, \.phase),
                        range: 0 ... 1
                    )
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func scenePinBinding<Value>(
        path: String,
        layerID: UUID,
        effectID: UUID,
        pin: ScenePin,
        _ keyPath: WritableKeyPath<ScenePin, Value>
    ) -> Binding<Value> {
        Binding(
            get: { pin[keyPath: keyPath] },
            set: { newValue in
                updateSceneEffect(path: path, layerID: layerID, effectID: effectID) { effect in
                    guard let index = effect.pins.firstIndex(where: { $0.id == pin.id }) else {
                        return
                    }
                    effect.pins[index][keyPath: keyPath] = newValue
                }
            }
        )
    }

    /// Points drawn over the preview for the selected effect: its pins or centre.
    func scenePreviewMarkers(document: SceneDocument, layerID: UUID?) -> [ScenePreviewMarker] {
        guard let layerID,
              let layer = document.layers.first(where: { $0.id == layerID }),
              let effect = layer.effects.first(where: { $0.id == selectedSceneEffectID }) ?? layer.effects.first
        else {
            return []
        }
        if effect.kind == .puppet {
            return effect.pins.map { pin in
                ScenePreviewMarker(
                    layerID: layerID, point: SIMD2(Float(pin.x), Float(pin.y)),
                    style: pin.isAnchor ? .anchor : .mover, isSelected: pin.id == selectedScenePinID
                )
            }
        }
        if effect.kind.usesCenter {
            return [ScenePreviewMarker(
                layerID: layerID, point: SIMD2(Float(effect.centerX), Float(effect.centerY)),
                style: .center, isSelected: false
            )]
        }
        return []
    }

    private func sceneEffectRow(title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: sceneEffectLabelWidth, alignment: .leading)
            content()
        }
    }

    private func sceneEffectSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        sceneEffectRow(title: title) {
            Slider(value: value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int((value.wrappedValue * 100).rounded()))%")
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    // MARK: - Editing helpers

    func beginScenePainting(path: String, layerID: UUID, effect: SceneEffect, kind: ScenePaintOverride.Target) {
        guard let document = model.sceneDocumentsByPath[path],
              let layer = document.layers.first(where: { $0.id == layerID })
        else {
            return
        }
        let size: CGSize
        do {
            if let text = layer.text {
                // Painted in the text's picture as it is drawn now.
                let fontURL = text.fontFile.map { SceneStore.folderURL(forVideoPath: path).appendingPathComponent($0) }
                guard let raster = try SceneTextRasterizer.render(text, fontURL: fontURL) else { return }
                size = CGSize(width: raster.width, height: raster.height)
            } else {
                size = try SceneStore.pixelSize(of: SceneStore.imageURL(layer, videoPath: path))
            }
        } catch {
            model.sceneErrorMessage = error.localizedDescription
            return
        }
        sceneMaskPainter.onCommit = { [model] target, fileName, bounds in
            model.setScenePaintFile(
                fileName, kind: target.kind, effectID: target.effectID, layerID: target.layerID, path: target.path,
                bounds: bounds
            )
        }
        sceneMaskPainter.onError = { [model] error in
            model.sceneErrorMessage = error.localizedDescription
        }
        sceneMaskPainter.tool = .paint
        sceneMaskPainter.begin(
            SceneMaskPainter.Target(
                path: path, layerID: layerID, effectID: effect.id, kind: kind,
                storesFlowReversed: effect.kind == .flowMap
            ),
            existingFile: effect.paintFile(kind),
            layerPixelSize: size
        )
        if !effect.isEnabled {
            updateSceneEffect(path: path, layerID: layerID, effectID: effect.id) { $0.isEnabled = true }
        }
        sceneEditorTool = .paint(effectID: effect.id, kind: kind)
    }

    private func sceneEffectBinding<Value>(
        path: String,
        layerID: UUID,
        effect: SceneEffect,
        _ keyPath: WritableKeyPath<SceneEffect, Value>
    ) -> Binding<Value> {
        Binding(
            get: { effect[keyPath: keyPath] },
            set: { newValue in
                updateSceneEffect(path: path, layerID: layerID, effectID: effect.id) { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    func updateSceneEffect(path: String, layerID: UUID, effectID: UUID, _ change: (inout SceneEffect) -> Void) {
        updateSceneLayerEffects(path: path, layerID: layerID) { effects in
            guard let index = effects.firstIndex(where: { $0.id == effectID }) else {
                return
            }
            change(&effects[index])
        }
    }

    private func updateSceneLayerEffects(path: String, layerID: UUID, _ change: (inout [SceneEffect]) -> Void) {
        guard var document = model.sceneDocumentsByPath[path],
              let index = document.layers.firstIndex(where: { $0.id == layerID })
        else {
            return
        }
        change(&document.layers[index].effects)
        model.updateScene(document, path: path)
    }

    private func removeSceneEffect(path: String, layerID: UUID, effectID: UUID) {
        if sceneEditorToolEffectID == effectID {
            endSceneEditorTool()
        }
        updateSceneLayerEffects(path: path, layerID: layerID) { $0.removeAll { $0.id == effectID } }
    }

    /// `by` is -1 to apply earlier, +1 to apply later.
    private func moveSceneEffect(path: String, layerID: UUID, effectID: UUID?, by step: Int) {
        guard let effectID else {
            return
        }
        updateSceneLayerEffects(path: path, layerID: layerID) { effects in
            guard let index = effects.firstIndex(where: { $0.id == effectID }),
                  effects.indices.contains(index + step)
            else {
                return
            }
            effects.swapAt(index, index + step)
        }
    }

    private var sceneEditorToolEffectID: UUID? {
        switch sceneEditorTool {
        case let .paint(effectID, _), let .pickCenter(effectID), let .addPins(effectID):
            effectID
        case nil:
            nil
        }
    }
}

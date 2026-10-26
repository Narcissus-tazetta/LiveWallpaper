import SwiftUI

extension SettingsView {
    /// The keyframe being edited, when the layer moves over time.
    func selectedSceneKeyframe(in layer: SceneLayer) -> SceneKeyframe? {
        guard layer.isKeyframed else {
            return nil
        }
        return layer.keyframes.first { $0.id == selectedSceneKeyframeID }
    }

    /// The placement the preview's handles and the number fields change: the chosen
    /// keyframe's pose, or the fixed placement. nil while locked, or while the layer
    /// moves over time and no keyframe is chosen.
    func sceneEditableTransform(of layer: SceneLayer) -> SceneTransform? {
        guard !layer.isLocked, layer.motion == nil else {
            return nil
        }
        guard layer.isKeyframed else {
            return layer.transform
        }
        guard layer.id == selectedSceneLayerID else {
            return nil
        }
        return selectedSceneKeyframe(in: layer)?.transform
    }

    func applySceneTransform(_ transform: SceneTransform, path: String, layerID: UUID) {
        updateSceneLayout(path: path, layerID: layerID) { layer in
            if layer.isKeyframed {
                guard let index = layer.keyframes.firstIndex(where: { $0.id == selectedSceneKeyframeID }) else {
                    return
                }
                layer.keyframes[index].transform = transform
            } else {
                layer.transform = transform
            }
        }
    }

    /// `phase` is 0..<1 of the loop.
    func setSceneKeyframeTime(_ phase: Double, keyframeID: UUID, path: String, layerID: UUID) {
        updateSceneLayout(path: path, layerID: layerID) { layer in
            guard !layer.isLocked, let index = layer.keyframes.firstIndex(where: { $0.id == keyframeID }) else {
                return
            }
            layer.keyframes[index].time = phase
        }
    }

    /// Placement, and its keyframes when the layer moves over time.
    @ViewBuilder
    func sceneLayoutControls(path: String, layer: SceneLayer) -> some View {
        let labelWidth: CGFloat = 132
        let keyframe = selectedSceneKeyframe(in: layer)
        let loopSeconds = Double(model.sceneDocumentsByPath[path]?.loopSeconds ?? 20)

        Divider()
        Text(model.localizedString("配置"))
            .font(.headline)

        if let motion = layer.motion {
            settingsFootnote(model.localizedString("読み込んだ動きで動きます。動きを外すと、最初の姿勢で止まり、配置を変えられるようになります。"))
            Button(model.localizedString("動きを外す")) {
                updateSceneLayout(path: path, layerID: layer.id) { layer in
                    let first = motion.pose(at: 0)
                    layer.transform = first.transform
                    layer.opacity *= first.opacity
                    layer.motion = nil
                }
            }
            .disabled(layer.isLocked)
        } else {
            sceneEditableLayoutControls(path: path, layer: layer, keyframe: keyframe, loopSeconds: loopSeconds, labelWidth: labelWidth)
        }
    }

    @ViewBuilder
    private func sceneEditableLayoutControls(
        path: String, layer: SceneLayer, keyframe: SceneKeyframe?, loopSeconds: Double, labelWidth: CGFloat
    ) -> some View {
        Toggle(
            model.localizedString("時間で動かす"),
            isOn: Binding(
                get: { layer.isKeyframed },
                set: { enabled in
                    updateSceneLayout(path: path, layerID: layer.id) { layer in
                        if enabled {
                            // Start with the current pose at the loop start and half way.
                            let first = SceneKeyframe(time: 0, transform: layer.transform)
                            layer.keyframes = [first, SceneKeyframe(time: 0.5, transform: layer.transform)]
                            selectedSceneKeyframeID = first.id
                        } else {
                            layer.transform = layer.keyframes.first?.transform ?? layer.transform
                            layer.keyframes = []
                            selectedSceneKeyframeID = nil
                        }
                    }
                }
            )
        )

        if layer.isKeyframed {
            settingsFootnote(
                model.localizedString("キーフレームの姿勢を順に通って、最後のキーフレームから最初に戻ります。キーフレームを選んでいる間は、プレビューがその時刻で止まります。一時停止中に追加すると、その時刻に追加します。")
            )
            ForEach(Array(layer.keyframes.sorted { $0.time < $1.time }.enumerated()), id: \.element.id) { index, frame in
                let isSelected = frame.id == keyframe?.id
                HStack(spacing: 8) {
                    Button {
                        selectedSceneKeyframeID = isSelected ? nil : frame.id
                    } label: {
                        HStack {
                            Image(systemName: "diamond.fill")
                                .foregroundColor(isSelected ? .accentColor : .secondary)
                            Text(String(
                                format: model.localizedString("キーフレーム %1$d(%2$@ 秒)"), locale: model.appLocale,
                                index + 1, String(format: "%.1f", frame.time * loopSeconds)
                            ))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    Button {
                        updateSceneLayout(path: path, layerID: layer.id) { layer in
                            layer.keyframes.removeAll { $0.id == frame.id }
                            if layer.keyframes.count < 2 {
                                layer.transform = layer.keyframes.first?.transform ?? layer.transform
                                layer.keyframes = []
                            }
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(model.localizedString("キーフレームを削除"))
                    .accessibilityLabel(model.localizedString("キーフレームを削除"))
                }
            }
            Button(model.localizedString("キーフレームを追加")) {
                updateSceneLayout(path: path, layerID: layer.id) { layer in
                    let times = layer.keyframes.map(\.time).sorted()
                    let playhead = scenePreviewController.time / loopSeconds
                    let wrappedPlayhead = playhead - floor(playhead)
                    let time: Double
                    if !scenePreviewController.isPlaying, keyframe == nil,
                       !times.contains(where: { abs($0 - wrappedPlayhead) < 0.001 })
                    {
                        // Stopped at a time of the user's choosing: add it there.
                        time = min(wrappedPlayhead, 0.999)
                    } else {
                        // Halfway into the longest gap, starting from the pose shown there.
                        var bestStart = times.last ?? 0
                        var bestGap = (times.first ?? 0) + 1 - bestStart
                        for (a, b) in zip(times, times.dropFirst()) where b - a > bestGap {
                            bestStart = a
                            bestGap = b - a
                        }
                        time = (bestStart + bestGap / 2).truncatingRemainder(dividingBy: 1)
                    }
                    let pose = layer.pose(at: time)
                    let frame = SceneKeyframe(time: time, transform: pose.transform, opacity: pose.opacity)
                    layer.keyframes.append(frame)
                    selectedSceneKeyframeID = frame.id
                }
            }
        }

        if layer.isLocked {
            settingsFootnote(model.localizedString("ロック中のレイヤーは変更できません。"))
        } else if layer.isKeyframed, keyframe == nil {
            settingsFootnote(model.localizedString("姿勢を変えるには、キーフレームを選んでください。"))
        } else {
            if let keyframe {
                sceneLayoutSlider(
                    title: model.localizedString("時刻"),
                    value: sceneKeyframeBinding(path: path, layerID: layer.id, keyframe: keyframe, \.time),
                    range: 0 ... 0.999,
                    factor: loopSeconds,
                    unit: "s",
                    fractionDigits: 1,
                    labelWidth: labelWidth
                )
            }
            sceneLayoutSlider(
                title: model.localizedString("横位置"),
                value: sceneTransformBinding(path: path, layer: layer, keyframe: keyframe, \.offsetX),
                range: -1 ... 1,
                factor: 100,
                unit: "%",
                labelWidth: labelWidth
            )
            sceneLayoutSlider(
                title: model.localizedString("縦位置"),
                value: sceneTransformBinding(path: path, layer: layer, keyframe: keyframe, \.offsetY),
                range: -1 ... 1,
                factor: 100,
                unit: "%",
                labelWidth: labelWidth
            )
            sceneLayoutSlider(
                title: model.localizedString("大きさ"),
                value: sceneTransformBinding(path: path, layer: layer, keyframe: keyframe, \.scale),
                range: SceneTransform.scaleRange,
                factor: 100,
                unit: "%",
                labelWidth: labelWidth
            )
            sceneLayoutSlider(
                title: model.localizedString("角度"),
                value: sceneTransformBinding(path: path, layer: layer, keyframe: keyframe, \.rotation),
                range: -180 ... 180,
                unit: "°",
                labelWidth: labelWidth
            )
            if let keyframe {
                sceneLayoutSlider(
                    title: model.localizedString("不透明度"),
                    value: sceneKeyframeBinding(path: path, layerID: layer.id, keyframe: keyframe, \.opacity),
                    range: 0 ... 1,
                    factor: 100,
                    unit: "%",
                    labelWidth: labelWidth
                )
            }
            let transform = keyframe?.transform ?? layer.transform
            Button(model.localizedString("配置を元に戻す")) {
                updateSceneLayout(path: path, layerID: layer.id) { layer in
                    if let id = keyframe?.id, let index = layer.keyframes.firstIndex(where: { $0.id == id }) {
                        layer.keyframes[index].transform = .identity
                    } else {
                        layer.transform = .identity
                    }
                }
            }
            .disabled(transform == .identity)
        }
    }

    /// A slider with the value next to it, which can also be typed.
    func sceneLayoutSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        factor: Double = 1,
        unit: String,
        fractionDigits: Int = 0,
        labelWidth: CGFloat
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: labelWidth, alignment: .leading)
            Slider(value: value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(String(format: "%.\(fractionDigits)f\(unit)", value.wrappedValue * factor))
            SceneNumberField(
                title: title, value: value.wrappedValue, factor: factor, unit: unit, range: range,
                fractionDigits: fractionDigits
            ) { newValue in
                value.wrappedValue = newValue
            }
        }
    }

    /// Edits the selected keyframe's pose, or the layer's fixed placement.
    private func sceneTransformBinding(
        path: String,
        layer: SceneLayer,
        keyframe: SceneKeyframe?,
        _ keyPath: WritableKeyPath<SceneTransform, Double>
    ) -> Binding<Double> {
        Binding(
            get: { (keyframe?.transform ?? layer.transform)[keyPath: keyPath] },
            set: { newValue in
                updateSceneLayout(path: path, layerID: layer.id) { layer in
                    if let id = keyframe?.id, let index = layer.keyframes.firstIndex(where: { $0.id == id }) {
                        layer.keyframes[index].transform[keyPath: keyPath] = newValue
                    } else {
                        layer.transform[keyPath: keyPath] = newValue
                    }
                }
            }
        )
    }

    private func sceneKeyframeBinding(
        path: String,
        layerID: UUID,
        keyframe: SceneKeyframe,
        _ keyPath: WritableKeyPath<SceneKeyframe, Double>
    ) -> Binding<Double> {
        Binding(
            get: { keyframe[keyPath: keyPath] },
            set: { newValue in
                updateSceneLayout(path: path, layerID: layerID) { layer in
                    guard let index = layer.keyframes.firstIndex(where: { $0.id == keyframe.id }) else {
                        return
                    }
                    layer.keyframes[index][keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func updateSceneLayout(path: String, layerID: UUID, _ change: (inout SceneLayer) -> Void) {
        guard var document = model.sceneDocumentsByPath[path],
              let index = document.layers.firstIndex(where: { $0.id == layerID })
        else {
            return
        }
        change(&document.layers[index])
        model.updateScene(document, path: path)
    }
}

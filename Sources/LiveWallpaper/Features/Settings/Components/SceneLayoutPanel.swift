import SwiftUI

extension SettingsView {
    /// The keyframe being edited, when the layer moves over time.
    func selectedSceneKeyframe(in layer: SceneLayer) -> SceneKeyframe? {
        guard layer.isKeyframed else {
            return nil
        }
        return layer.keyframes.first { $0.id == selectedSceneKeyframeID }
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
                model.localizedString("キーフレームの姿勢を順に通って、最後のキーフレームから最初に戻ります。キーフレームを選んでいる間は、プレビューがその時刻で止まります。")
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
                    // Halfway into the longest gap, starting from the pose shown there.
                    let times = layer.keyframes.map(\.time).sorted()
                    var bestStart = times.last ?? 0
                    var bestGap = (times.first ?? 0) + 1 - bestStart
                    for (a, b) in zip(times, times.dropFirst()) where b - a > bestGap {
                        bestStart = a
                        bestGap = b - a
                    }
                    let time = (bestStart + bestGap / 2).truncatingRemainder(dividingBy: 1)
                    let pose = layer.pose(at: time)
                    let frame = SceneKeyframe(time: time, transform: pose.transform, opacity: pose.opacity)
                    layer.keyframes.append(frame)
                    selectedSceneKeyframeID = frame.id
                }
            }
        }

        if layer.isKeyframed, keyframe == nil {
            settingsFootnote(model.localizedString("姿勢を変えるには、キーフレームを選んでください。"))
        } else {
            if let keyframe {
                sceneLayoutSlider(
                    title: model.localizedString("時刻"),
                    value: sceneKeyframeBinding(path: path, layerID: layer.id, keyframe: keyframe, \.time),
                    range: 0 ... 0.999,
                    text: String(format: "%.1f s", keyframe.time * loopSeconds),
                    labelWidth: labelWidth
                )
            }
            let transform = keyframe?.transform ?? layer.transform
            sceneLayoutSlider(
                title: model.localizedString("横位置"),
                value: sceneTransformBinding(path: path, layer: layer, keyframe: keyframe, \.offsetX),
                range: -1 ... 1,
                text: "\(Int((transform.offsetX * 100).rounded()))%",
                labelWidth: labelWidth
            )
            sceneLayoutSlider(
                title: model.localizedString("縦位置"),
                value: sceneTransformBinding(path: path, layer: layer, keyframe: keyframe, \.offsetY),
                range: -1 ... 1,
                text: "\(Int((transform.offsetY * 100).rounded()))%",
                labelWidth: labelWidth
            )
            sceneLayoutSlider(
                title: model.localizedString("大きさ"),
                value: sceneTransformBinding(path: path, layer: layer, keyframe: keyframe, \.scale),
                range: 0.1 ... 3,
                text: "\(Int((transform.scale * 100).rounded()))%",
                labelWidth: labelWidth
            )
            sceneLayoutSlider(
                title: model.localizedString("回転"),
                value: sceneTransformBinding(path: path, layer: layer, keyframe: keyframe, \.rotation),
                range: -180 ... 180,
                text: "\(Int(transform.rotation.rounded()))°",
                labelWidth: labelWidth
            )
            if let keyframe {
                sceneLayoutSlider(
                    title: model.localizedString("不透明度"),
                    value: sceneKeyframeBinding(path: path, layerID: layer.id, keyframe: keyframe, \.opacity),
                    range: 0 ... 1,
                    text: "\(Int((keyframe.opacity * 100).rounded()))%",
                    labelWidth: labelWidth
                )
            }
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

    private func sceneLayoutSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        text: String,
        labelWidth: CGFloat
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: labelWidth, alignment: .leading)
            Slider(value: value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(text)
            Text(text)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 64, alignment: .trailing)
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

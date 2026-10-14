import SwiftUI

extension SettingsView {
    @ViewBuilder
    func sceneAIControls(path: String, layer: SceneLayer) -> some View {
        let labelWidth: CGFloat = 132
        let work = model.sceneAIWork[layer.id]

        Divider()
        Text(model.localizedString("AI"))
            .font(.headline)

        // Subject cut-out
        HStack(spacing: 8) {
            Button(model.localizedString("被写体を切り抜く")) {
                model.separateSceneForeground(layerID: layer.id, path: path)
            }
            .disabled(work != nil || !SceneAI.canSeparateForeground)
            if work == .separating {
                ProgressView()
                    .controlSize(.small)
                Text(model.localizedString("切り抜き中…"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        settingsFootnote(
            model.localizedString(
                SceneAI.canSeparateForeground
                    ? "被写体を切り抜いて、前景と背景の 2 枚のレイヤーに分けます。背景の抜けた部分は、周りの色で埋めます。"
                    : "被写体の切り抜きは macOS 14 以降で使えます。"
            )
        )

        // Depth
        if layer.depthFile == nil {
            HStack(spacing: 8) {
                Button(model.localizedString("奥行きを推定")) {
                    model.estimateSceneDepth(layerID: layer.id, path: path)
                }
                .disabled(work != nil)
                sceneAIProgress(work)
            }
            settingsFootnote(
                SceneAI.isDepthModelInstalled
                    ? model.localizedString("画像から奥行きを推定して、手前と奥が別々に動く立体的な見え方にします。")
                    : String(
                        format: model.localizedString("画像から奥行きを推定して、手前と奥が別々に動く立体的な見え方にします。初回だけ、Apple が公開しているモデル(約 %d MB)を Hugging Face からダウンロードします。"),
                        locale: model.appLocale, SceneAI.modelDownloadMegabytes
                    )
            )
        } else {
            sceneAISlider(
                title: model.localizedString("奥行きの強さ"),
                value: sceneLayerAIBinding(path: path, layerID: layer.id, layer: layer, \.depthStrength),
                labelWidth: labelWidth
            )
            Toggle(
                model.localizedString("カーソルに合わせて動かす"),
                isOn: sceneLayerAIBinding(path: path, layerID: layer.id, layer: layer, \.depthFollowsCursor)
            )
            sceneAISlider(
                title: model.localizedString("ひとりでに動く量"),
                value: sceneLayerAIBinding(path: path, layerID: layer.id, layer: layer, \.depthAutoMotion),
                labelWidth: labelWidth,
                zeroText: model.localizedString("オフ")
            )
            if layer.depthAutoMotion > 0 {
                HStack(spacing: 12) {
                    Text(model.localizedString("速さ"))
                        .frame(width: labelWidth, alignment: .leading)
                    Stepper(
                        value: sceneLayerAIBinding(path: path, layerID: layer.id, layer: layer, \.depthAutoCycles),
                        in: SceneEffect.cyclesRange
                    ) {
                        Text(String(
                            format: model.localizedString("ループ %1$d 秒の間に %2$d 回"), locale: model.appLocale,
                            model.sceneDocumentsByPath[path]?.loopSeconds ?? 20, layer.depthAutoCycles
                        ))
                        .font(.caption.monospacedDigit())
                    }
                    .accessibilityLabel(model.localizedString("速さ"))
                }
            }
            HStack(spacing: 8) {
                Button(model.localizedString("推定し直す")) {
                    model.estimateSceneDepth(layerID: layer.id, path: path)
                }
                .disabled(work != nil)
                Button(model.localizedString("奥行きを外す")) {
                    updateSceneLayerAI(path: path, layerID: layer.id) { $0.depthFile = nil }
                }
                .disabled(work != nil)
                sceneAIProgress(work)
            }
            settingsFootnote(
                model.localizedString("「ひとりでに動く量」を上げると、カーソルが無くても視点がゆっくり回ります。ロック画面とスクリーンセーバーにも、この動きが入ります。")
            )
        }
    }

    @ViewBuilder
    private func sceneAIProgress(_ work: SceneAIWork?) -> some View {
        switch work {
        case let .downloadingModel(progress):
            ProgressView(value: progress)
                .frame(width: 80)
            Text(model.localizedString("モデルをダウンロード中…"))
                .font(.caption)
                .foregroundColor(.secondary)
        case .estimatingDepth:
            ProgressView()
                .controlSize(.small)
            Text(model.localizedString("推定中…"))
                .font(.caption)
                .foregroundColor(.secondary)
        default:
            EmptyView()
        }
    }

    private func sceneAISlider(title: String, value: Binding<Double>, labelWidth: CGFloat, zeroText: String? = nil) -> some View {
        let text = value.wrappedValue <= 0 ? (zeroText ?? "0%") : "\(Int((value.wrappedValue * 100).rounded()))%"
        return HStack(spacing: 12) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: labelWidth, alignment: .leading)
            Slider(value: value, in: 0 ... 1)
                .accessibilityLabel(title)
                .accessibilityValue(text)
            Text(text)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
    }

    private func sceneLayerAIBinding<Value>(
        path: String,
        layerID: UUID,
        layer: SceneLayer,
        _ keyPath: WritableKeyPath<SceneLayer, Value>
    ) -> Binding<Value> {
        Binding(
            get: { layer[keyPath: keyPath] },
            set: { newValue in
                updateSceneLayerAI(path: path, layerID: layerID) { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private func updateSceneLayerAI(path: String, layerID: UUID, _ change: (inout SceneLayer) -> Void) {
        guard var document = model.sceneDocumentsByPath[path],
              let index = document.layers.firstIndex(where: { $0.id == layerID })
        else {
            return
        }
        change(&document.layers[index])
        model.updateScene(document, path: path)
    }
}

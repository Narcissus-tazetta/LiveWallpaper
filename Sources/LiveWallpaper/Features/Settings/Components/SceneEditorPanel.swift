import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    private var sceneRowLabelWidth: CGFloat {
        132
    }

    /// Layers of a still-image wallpaper. Shown instead of trim editing for scenes.
    var wallpaperSceneEditorPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let path = fitEditor.resolvedVideoPath(), let document = model.sceneDocumentsByPath[path] {
                sceneEditorContent(path: path, document: document)
            } else {
                Text(model.localizedString("下の壁紙一覧から画像の壁紙を選択すると、レイヤーを編集できます"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCardBackground()
        .onDisappear {
            endSceneEditorTool()
        }
    }

    @ViewBuilder
    private func sceneEditorContent(path: String, document: SceneDocument) -> some View {
        let selectedID = document.layers.contains(where: { $0.id == selectedSceneLayerID })
            ? selectedSceneLayerID
            : document.layers.last?.id

        HStack(spacing: 10) {
            Text(model.registeredVideoDisplayName(for: path))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.scenesBaking.contains(path) {
                ProgressView()
                    .controlSize(.small)
                if let progress = model.sceneBakeProgress[path] {
                    Text(String(
                        format: model.localizedString("ロック画面用の動画を書き出し中… %d%%"), locale: model.appLocale,
                        Int((progress * 100).rounded())
                    ))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                } else {
                    Text(model.localizedString("ロック画面用の動画を準備中…"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }

        ScenePreviewView(
            document: document,
            videoPath: path,
            interaction: scenePreviewInteraction(layerID: selectedID),
            painter: sceneMaskPainter,
            onPickPoint: { point in
                if let selectedID {
                    handleScenePreviewPick(point, path: path, layerID: selectedID)
                }
            },
            markers: scenePreviewMarkers(document: document, layerID: selectedID),
            fixedTime: selectedID
                .flatMap { id in document.layers.first { $0.id == id } }
                .flatMap { selectedSceneKeyframe(in: $0) }
                .map { $0.time * Double(document.loopSeconds) }
        )
        .aspectRatio(CGFloat(document.aspectRatio), contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel(model.localizedString("プレビュー"))

        if case let .paint(_, kind) = sceneEditorTool {
            scenePaintBar(kind: kind)
        } else if case .pickCenter = sceneEditorTool {
            settingsFootnote(model.localizedString("プレビューをクリックして、中心にする位置を選びます。"))
        } else if case .addPins = sceneEditorTool {
            settingsFootnote(model.localizedString("プレビューをクリックすると、その位置にピンを追加します。最初のピンは固定、それ以降は揺らすピンになります。"))
        } else {
            settingsFootnote(
                model.localizedString("プレビューの上でポインタを動かすと、カーソルへの反応を確かめられます。")
            )
        }

        HStack(spacing: 12) {
            Text(model.localizedString("ループの長さ"))
                .frame(width: sceneRowLabelWidth, alignment: .leading)
            Spacer(minLength: 0)
            Picker(
                model.localizedString("ループの長さ"),
                selection: Binding(
                    get: { document.loopSeconds },
                    set: { value in
                        var updated = document
                        updated.loopSeconds = value
                        model.updateScene(updated, path: path)
                    }
                )
            ) {
                ForEach(SceneDocument.loopSecondsChoices, id: \.self) { seconds in
                    Text(String(format: model.localizedString("%d 秒"), locale: model.appLocale, seconds)).tag(seconds)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        settingsFootnote(
            model.localizedString("動きはこの長さで一周します。ロック画面とスクリーンセーバーには、この長さの動画を書き出して使います。長いほど書き出しに時間がかかります。")
        )

        HStack(alignment: .top, spacing: 16) {
            sceneLayerList(path: path, document: document, selectedID: selectedID)
                .frame(width: 240)
            if let selectedID, let layer = document.layers.first(where: { $0.id == selectedID }) {
                sceneLayerInspector(path: path, layer: layer)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        if let selectedID, let layer = document.layers.first(where: { $0.id == selectedID }) {
            Divider()
            sceneEffectsSection(path: path, layer: layer)
        }

        if let message = model.sceneErrorMessage {
            Text(message)
                .font(.caption)
                .foregroundColor(.orange)
        }

        settingsFootnote(
            model.localizedString(
                "変更はすぐに壁紙へ反映されます。ロック画面とスクリーンセーバーでは、カーソルに反応していない状態で表示されます。"
            )
        )
    }

    // MARK: - Layer list

    private func sceneLayerList(path: String, document: SceneDocument, selectedID: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.localizedString("レイヤー"))
                .font(.headline)
            VStack(spacing: 2) {
                // Top layer first, as in image editors.
                ForEach(document.layers.reversed()) { layer in
                    sceneLayerRow(path: path, layer: layer, isSelected: layer.id == selectedID)
                }
            }
            HStack(spacing: 4) {
                sceneAddLayerMenu(path: path)

                Button {
                    if let selectedID {
                        model.removeSceneLayer(id: selectedID, path: path)
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(document.layers.count <= 1)
                .help(model.localizedString("選択したレイヤーを削除"))
                .accessibilityLabel(model.localizedString("選択したレイヤーを削除"))

                Spacer(minLength: 0)

                Button {
                    moveSceneLayer(path: path, id: selectedID, by: 1)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(selectedID == nil || selectedID == document.layers.last?.id)
                .help(model.localizedString("前面へ移動"))
                .accessibilityLabel(model.localizedString("前面へ移動"))

                Button {
                    moveSceneLayer(path: path, id: selectedID, by: -1)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .disabled(selectedID == nil || selectedID == document.layers.first?.id)
                .help(model.localizedString("背面へ移動"))
                .accessibilityLabel(model.localizedString("背面へ移動"))
            }
            .buttonStyle(.borderless)
        }
    }

    private func sceneLayerRow(path: String, layer: SceneLayer, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                updateSceneLayer(path: path, id: layer.id) { $0.isVisible.toggle() }
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(model.localizedString(layer.isVisible ? "レイヤーを隠す" : "レイヤーを表示"))
            .accessibilityLabel(model.localizedString(layer.isVisible ? "レイヤーを隠す" : "レイヤーを表示"))
            .accessibilityValue(layer.name)

            Button {
                if selectedSceneLayerID != layer.id {
                    endSceneEditorTool()
                    selectedSceneEffectID = nil
                    selectedSceneKeyframeID = nil
                    selectedScenePinID = nil
                }
                selectedSceneLayerID = layer.id
            } label: {
                HStack(spacing: 6) {
                    if layer.kind == .particles {
                        Image(systemName: "sparkles")
                            .foregroundColor(.secondary)
                    }
                    Text(layer.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(layer.isVisible ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if layer.cursorMask != nil {
                        Image(systemName: "circle.dashed")
                            .foregroundColor(.secondary)
                            .help(model.localizedString("カーソルで透かす"))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(layer.name)
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
    private func sceneLayerInspector(path: String, layer: SceneLayer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let particles = layer.particles {
                sceneParticleControls(path: path, layer: layer, particles: particles)
            }
            sceneSliderRow(
                title: model.localizedString("不透明度"),
                value: sceneLayerBinding(path: path, layer: layer, \.opacity),
                range: 0 ... 1,
                valueText: "\(Int((layer.opacity * 100).rounded()))%"
            )

            HStack(spacing: 12) {
                Text(model.localizedString("合成"))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: sceneRowLabelWidth, alignment: .leading)
                Spacer(minLength: 0)
                Picker(model.localizedString("合成"), selection: sceneLayerBinding(path: path, layer: layer, \.blendMode)) {
                    Text(model.localizedString("通常")).tag(SceneBlendMode.normal)
                    Text(model.localizedString("乗算")).tag(SceneBlendMode.multiply)
                    Text(model.localizedString("スクリーン")).tag(SceneBlendMode.screen)
                    Text(model.localizedString("オーバーレイ")).tag(SceneBlendMode.overlay)
                    Text(model.localizedString("加算")).tag(SceneBlendMode.add)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            sceneSliderRow(
                title: model.localizedString("奥行き"),
                value: sceneLayerBinding(path: path, layer: layer, \.parallaxDepth),
                range: 0 ... 1,
                valueText: layer.parallaxDepth <= 0
                    ? model.localizedString("動かさない")
                    : "\(Int((layer.parallaxDepth * 100).rounded()))%"
            )
            settingsFootnote(
                model.localizedString("値が大きいレイヤーほど、カーソルに合わせて大きく動きます。手前のものほど大きくすると奥行きが出ます。")
            )

            HStack(spacing: 12) {
                Text(model.localizedString("カーソルで透かす"))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: sceneRowLabelWidth, alignment: .leading)
                Spacer(minLength: 0)
                Picker(
                    model.localizedString("カーソルで透かす"),
                    selection: Binding<SceneCursorMaskMode?>(
                        get: { layer.cursorMask?.mode },
                        set: { mode in
                            updateSceneLayer(path: path, id: layer.id) { layer in
                                if let mode {
                                    var mask = layer.cursorMask ?? SceneCursorMask()
                                    mask.mode = mode
                                    layer.cursorMask = mask
                                } else {
                                    layer.cursorMask = nil
                                }
                            }
                        }
                    )
                ) {
                    Text(model.localizedString("オフ")).tag(SceneCursorMaskMode?.none)
                    Text(model.localizedString("カーソルの周りを透かす")).tag(SceneCursorMaskMode?.some(.hide))
                    Text(model.localizedString("カーソルの周りだけ表示")).tag(SceneCursorMaskMode?.some(.show))
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            if let mask = layer.cursorMask {
                sceneSliderRow(
                    title: model.localizedString("大きさ"),
                    value: sceneMaskBinding(path: path, layer: layer, \.radius),
                    range: 0.03 ... 0.5,
                    valueText: "\(Int((mask.radius * 100).rounded()))%"
                )
                sceneSliderRow(
                    title: model.localizedString("ぼかし"),
                    value: sceneMaskBinding(path: path, layer: layer, \.softness),
                    range: 0 ... 1,
                    valueText: "\(Int((mask.softness * 100).rounded()))%"
                )
                settingsFootnote(
                    mask.mode == .hide
                        ? model.localizedString("カーソルの周りだけ、下のレイヤーが見えます。上下に構図の同じ画像を重ねると、X 線で透かしたような表現になります。")
                        : model.localizedString("このレイヤーは、カーソルの周りにだけ表示されます。")
                )
            }
            sceneLayoutControls(path: path, layer: layer)
            if layer.kind == .image {
                sceneAIControls(path: path, layer: layer)
            }
        }
    }

    private func sceneSliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        valueText: String
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: sceneRowLabelWidth, alignment: .leading)
            Slider(value: value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
            Text(valueText)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
    }

    // MARK: - Editing helpers

    private func sceneLayerBinding<Value>(
        path: String,
        layer: SceneLayer,
        _ keyPath: WritableKeyPath<SceneLayer, Value>
    ) -> Binding<Value> {
        Binding(
            get: { layer[keyPath: keyPath] },
            set: { newValue in
                updateSceneLayer(path: path, id: layer.id) { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private func sceneMaskBinding(
        path: String,
        layer: SceneLayer,
        _ keyPath: WritableKeyPath<SceneCursorMask, Double>
    ) -> Binding<Double> {
        Binding(
            get: { layer.cursorMask?[keyPath: keyPath] ?? 0 },
            set: { newValue in
                updateSceneLayer(path: path, id: layer.id) { $0.cursorMask?[keyPath: keyPath] = newValue }
            }
        )
    }

    private func updateSceneLayer(path: String, id: UUID, _ change: (inout SceneLayer) -> Void) {
        guard var document = model.sceneDocumentsByPath[path],
              let index = document.layers.firstIndex(where: { $0.id == id })
        else {
            return
        }
        change(&document.layers[index])
        model.updateScene(document, path: path)
    }

    /// `by` is +1 toward the front, -1 toward the back.
    private func moveSceneLayer(path: String, id: UUID?, by step: Int) {
        guard let id, var document = model.sceneDocumentsByPath[path],
              let index = document.layers.firstIndex(where: { $0.id == id })
        else {
            return
        }
        let destination = index + step
        guard document.layers.indices.contains(destination) else {
            return
        }
        document.layers.swapAt(index, destination)
        model.updateScene(document, path: path)
    }

    func chooseSceneLayerImage(path: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else {
            return
        }
        for url in panel.urls {
            model.addSceneLayer(from: url, path: path)
        }
        selectedSceneLayerID = model.sceneDocumentsByPath[path]?.layers.last?.id
    }
}

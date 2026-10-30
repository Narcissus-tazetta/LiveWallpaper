import SwiftUI

extension SettingsView {
    private static let sceneTextFontFamilies = NSFontManager.shared.availableFontFamilies

    @ViewBuilder
    func sceneTextControls(path: String, layer: SceneLayer, text: SceneText) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                model.localizedString("文字"),
                text: Binding(
                    get: { text.string },
                    set: { value in
                        updateSceneText(path: path, layerID: layer.id) { $0.string = String(value.prefix(SceneText.maximumLength)) }
                    }
                ),
                axis: .vertical
            )
            .lineLimit(1 ... 4)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(model.localizedString("文字"))

            sceneTextRow(model.localizedString("フォント")) {
                Picker(
                    model.localizedString("フォント"),
                    selection: Binding<String?>(
                        get: { text.systemFont },
                        set: { name in updateSceneText(path: path, layerID: layer.id) { $0.systemFont = name } }
                    )
                ) {
                    Text(model.localizedString("既定のフォント")).tag(String?.none)
                    ForEach(Self.sceneTextFontFamilies, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            sceneTextSlider(
                model.localizedString("大きさ"), value: text.pointSize, range: SceneText.pointSizeRange, format: "%.0f"
            ) { value in updateSceneText(path: path, layerID: layer.id) { $0.pointSize = value } }
            sceneTextRow(model.localizedString("色")) {
                sceneTextColorPicker(text.color, title: model.localizedString("色")) { color in
                    updateSceneText(path: path, layerID: layer.id) { $0.color = color }
                }
            }
            sceneTextRow(model.localizedString("寄せ")) {
                Picker(
                    model.localizedString("寄せ"),
                    selection: Binding(
                        get: { text.horizontalAlignment },
                        set: { value in updateSceneText(path: path, layerID: layer.id) { $0.horizontalAlignment = value } }
                    )
                ) {
                    Text(model.localizedString("左")).tag(SceneTextHorizontalAlignment.left)
                    Text(model.localizedString("中央")).tag(SceneTextHorizontalAlignment.center)
                    Text(model.localizedString("右")).tag(SceneTextHorizontalAlignment.right)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            sceneTextSlider(
                model.localizedString("字間"), value: text.letterSpacing, range: -20 ... 100, format: "%.0f"
            ) { value in updateSceneText(path: path, layerID: layer.id) { $0.letterSpacing = value } }
            sceneTextSlider(
                model.localizedString("行間"), value: text.lineSpacing, range: -50 ... 200, format: "%.0f"
            ) { value in updateSceneText(path: path, layerID: layer.id) { $0.lineSpacing = value } }
            sceneTextRow(model.localizedString("折り返し")) {
                Toggle(
                    model.localizedString("折り返し"),
                    isOn: Binding(
                        get: { text.maxWidth != nil },
                        set: { on in updateSceneText(path: path, layerID: layer.id) { $0.maxWidth = on ? 1000 : nil } }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
            }
            if let maxWidth = text.maxWidth {
                sceneTextSlider(
                    model.localizedString("折り返す幅"), value: maxWidth, range: 50 ... 4000, format: "%.0f"
                ) { value in updateSceneText(path: path, layerID: layer.id) { $0.maxWidth = value } }
            }

            sceneTextOutline(path: path, layer: layer, text: text)
            sceneTextShadow(path: path, layer: layer, text: text)
            sceneTextSlider(
                model.localizedString("文字のぼかし"), value: text.style?.blur ?? 0, range: 0 ... 20, format: "%.1f"
            ) { value in
                updateSceneText(path: path, layerID: layer.id) { text in
                    var style = text.style ?? SceneTextStyle()
                    style.blur = value > 0 ? value : nil
                    text.style = style.isEmpty ? nil : style
                }
            }
        }
    }

    @ViewBuilder
    private func sceneTextOutline(path: String, layer: SceneLayer, text: SceneText) -> some View {
        let outline = text.style?.outline
        sceneTextRow(model.localizedString("縁取り")) {
            Toggle(
                model.localizedString("縁取り"),
                isOn: Binding(
                    get: { outline != nil },
                    set: { on in
                        setSceneTextStyle(path: path, layerID: layer.id) {
                            $0.outline = on ? .init(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1), thickness: 2) : nil
                        }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
        }
        if let outline {
            sceneTextRow(model.localizedString("縁の色")) {
                sceneTextColorPicker(outline.color, title: model.localizedString("縁の色")) { color in
                    setSceneTextStyle(path: path, layerID: layer.id) { $0.outline?.color = color }
                }
            }
            sceneTextSlider(
                model.localizedString("縁の太さ"), value: outline.thickness, range: 0.5 ... 20, format: "%.1f"
            ) { value in setSceneTextStyle(path: path, layerID: layer.id) { $0.outline?.thickness = value } }
        }
    }

    @ViewBuilder
    private func sceneTextShadow(path: String, layer: SceneLayer, text: SceneText) -> some View {
        let shadow = text.style?.shadow
        sceneTextRow(model.localizedString("影")) {
            Toggle(
                model.localizedString("影"),
                isOn: Binding(
                    get: { shadow != nil },
                    set: { on in
                        setSceneTextStyle(path: path, layerID: layer.id) {
                            $0.shadow = on
                                ? .init(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1), size: 4, offsetX: 3, offsetY: 3, opacity: 0.6)
                                : nil
                        }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
        }
        if let shadow {
            sceneTextRow(model.localizedString("影の色")) {
                sceneTextColorPicker(shadow.color, title: model.localizedString("影の色")) { color in
                    setSceneTextStyle(path: path, layerID: layer.id) { $0.shadow?.color = color }
                }
            }
            sceneTextSlider(
                model.localizedString("影のぼかし"), value: shadow.size, range: 0 ... 30, format: "%.1f"
            ) { value in setSceneTextStyle(path: path, layerID: layer.id) { $0.shadow?.size = value } }
            sceneTextSlider(
                model.localizedString("影の横位置"), value: shadow.offsetX, range: -30 ... 30, format: "%.1f"
            ) { value in setSceneTextStyle(path: path, layerID: layer.id) { $0.shadow?.offsetX = value } }
            sceneTextSlider(
                model.localizedString("影の縦位置"), value: shadow.offsetY, range: -30 ... 30, format: "%.1f"
            ) { value in setSceneTextStyle(path: path, layerID: layer.id) { $0.shadow?.offsetY = value } }
            sceneTextSlider(
                model.localizedString("影の濃さ"), value: shadow.opacity, range: 0 ... 1, format: "%.2f"
            ) { value in setSceneTextStyle(path: path, layerID: layer.id) { $0.shadow?.opacity = value } }
        }
    }

    private func sceneTextRow(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 132, alignment: .leading)
            Spacer(minLength: 0)
            content()
        }
    }

    private func sceneTextSlider(
        _ title: String, value: Double, range: ClosedRange<Double>, format: String,
        set: @escaping (Double) -> Void
    ) -> some View {
        let valueText = String(format: format, locale: model.appLocale, value)
        return HStack(spacing: 12) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 132, alignment: .leading)
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: set), in: range)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
            Text(valueText)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func sceneTextColorPicker(_ color: RGBAColor, title: String, set: @escaping (RGBAColor) -> Void) -> some View {
        ColorPicker(
            title,
            selection: Binding(
                get: { Color(nsColor: color.nsColor) },
                set: { set(RGBAColor(NSColor($0))) }
            ),
            supportsOpacity: true
        )
        .labelsHidden()
    }

    private func setSceneTextStyle(path: String, layerID: UUID, _ change: (inout SceneTextStyle) -> Void) {
        updateSceneText(path: path, layerID: layerID) { text in
            var style = text.style ?? SceneTextStyle()
            change(&style)
            text.style = style.isEmpty ? nil : style
        }
    }

    private func updateSceneText(path: String, layerID: UUID, _ change: (inout SceneText) -> Void) {
        guard var document = model.sceneDocumentsByPath[path],
              let index = document.layers.firstIndex(where: { $0.id == layerID }),
              !document.layers[index].isLocked,
              var text = document.layers[index].text
        else {
            return
        }
        change(&text)
        document.layers[index].text = text
        model.updateScene(document, path: path)
    }
}

extension SettingsView {
    /// Switches an image layer's picture to the playing track's cover or to the canvas below it.
    @ViewBuilder
    func sceneLayerSourceToggles(path: String, layer: SceneLayer) -> some View {
        if layer.videoFile == nil {
            sceneSourceToggle(
                title: model.localizedString("再生中の曲のジャケットを表示"),
                isOn: layer.usesMediaArtwork,
                note: model.localizedString("画像の透明な部分でジャケットの形を切り抜きます。曲が無いときは画像そのものを表示します。この設定のシーンは、書き出した動画ではなくリアルタイムで描画します。")
            ) { on in updateSceneLayerSource(path: path, layerID: layer.id) { $0.usesMediaArtwork = on } }
            sceneSourceToggle(
                title: model.localizedString("下のレイヤーを入力にする"),
                isOn: layer.capturesCanvas,
                note: model.localizedString("画像の代わりに、このレイヤーより下の絵を入力にします。動きと組み合わせると、下の絵を揺らしたり歪めたりできます。")
            ) { on in updateSceneLayerSource(path: path, layerID: layer.id) { $0.capturesCanvas = on } }
        }
    }

    private func sceneSourceToggle(
        title: String, isOn: Bool, note: String, set: @escaping (Bool) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: Binding(get: { isOn }, set: set))
                .toggleStyle(.switch)
            settingsFootnote(note)
        }
    }

    private func updateSceneLayerSource(path: String, layerID: UUID, _ change: (inout SceneLayer) -> Void) {
        guard var document = model.sceneDocumentsByPath[path],
              let index = document.layers.firstIndex(where: { $0.id == layerID }),
              !document.layers[index].isLocked
        else {
            return
        }
        change(&document.layers[index])
        model.updateScene(document, path: path, coalescing: false)
    }
}

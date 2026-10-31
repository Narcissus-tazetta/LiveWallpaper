import SwiftUI

extension SceneEditorView {
    private var sceneLinkLabelWidth: CGFloat {
        SceneInspectorMetrics.labelWidth
    }

    func sceneTimeOfDayName(_ timeOfDay: SceneTimeOfDay) -> String {
        switch timeOfDay {
        case .morning: model.localizedString("朝")
        case .day: model.localizedString("昼")
        case .evening: model.localizedString("夕方")
        case .night: model.localizedString("夜")
        }
    }

    private func sceneLinkInputName(_ input: SceneLinkInput) -> String {
        switch input {
        case .timeOfDay: model.localizedString("時間帯")
        case .cursorX: model.localizedString("カーソルの横の位置")
        case .cursorY: model.localizedString("カーソルの縦の位置")
        case .cursorDistance: model.localizedString("カーソルの中心からの距離")
        }
    }

    /// The cursor position each edge stands for in the preview.
    private func sceneLinkEdgeCursor(_ input: SceneLinkInput, isEnd: Bool) -> SIMD2<Float> {
        let sign: Float = isEnd ? 1 : -1
        switch input {
        case .cursorX, .timeOfDay: return SIMD2(sign, 0)
        case .cursorY: return SIMD2(0, sign)
        case .cursorDistance: return SIMD2(1, 0)
        }
    }

    /// The badge on the preview while it shows simulated conditions.
    func scenePreviewConditionText() -> String {
        var parts: [String] = []
        if let timeOfDay = scenePreviewController.simulatedTimeOfDay {
            parts.append(sceneTimeOfDayName(timeOfDay))
        }
        if let cursor = scenePreviewController.simulatedCursor {
            let place = switch (cursor.x, cursor.y) {
            case (..<0, _): "左端"
            case (0.001..., _): "右端"
            case (_, ..<0): "上端"
            case (_, 0.001...): "下端"
            default: "中央"
            }
            parts.append(String(format: model.localizedString("カーソル: %@"), model.localizedString(place)))
        }
        return String(
            format: model.localizedString("%@ として表示中"), parts.joined(separator: model.localizedString("・"))
        )
    }

    // MARK: - Section

    /// Links of layers to the time of day and the cursor, for the whole scene.
    @ViewBuilder
    func sceneLinksSection(path: String, document: SceneDocument, selectedLayerID: UUID?) -> some View {
        let selected = document.links.first { $0.id == selectedSceneLinkID } ?? document.links.first
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.localizedString("時間帯・カーソルとの連動"))
                    .font(.headline)
                Spacer(minLength: 0)
                Menu {
                    ForEach(SceneLinkInput.allCases, id: \.self) { input in
                        Button(sceneLinkInputName(input)) {
                            addSceneLink(input, path: path, layerID: selectedLayerID)
                        }
                    }
                } label: {
                    Label(model.localizedString("連動を追加"), systemImage: "plus")
                }
                .fixedSize()
                .disabled(selectedLayerID == nil)
            }

            scenePreviewConditionRow(document: document)

            if document.links.isEmpty {
                settingsFootnote(model.localizedString("時間帯で明るさや色を変えたり、カーソルの位置に合わせてレイヤーを動かしたりできます。「連動を追加」で、選んでいるレイヤーに設定します。"))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(document.links) { link in
                            sceneLinkRow(path: path, document: document, link: link, isSelected: link.id == selected?.id)
                        }
                        HStack(spacing: 4) {
                            Button {
                                if let selected {
                                    removeSceneLink(selected.id, path: path)
                                }
                            } label: {
                                Image(systemName: "minus")
                            }
                            .disabled(selected == nil)
                            .help(model.localizedString("選択した連動を削除"))
                            .accessibilityLabel(model.localizedString("選択した連動を削除"))
                            Spacer(minLength: 0)
                        }
                        .buttonStyle(.borderless)
                    }
                    Divider()

                    if let selected {
                        sceneLinkInspector(path: path, document: document, link: selected)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            settingsFootnote(model.localizedString("ロック画面・スクリーンセーバー・書き出した動画は、その時点の時間帯で、カーソルが中央にあるものとして表示します。時間帯が変わると動画を書き出し直します(アプリを終了している間は、最後に書き出した時間帯のままです)。"))
        }
    }

    /// What the preview takes the time of day and the cursor to be. One row per menu:
    /// side by side they do not fit the inspector.
    private func scenePreviewConditionRow(document: SceneDocument) -> some View {
        let now = document.timeOfDay(at: Date())
        return VStack(alignment: .leading, spacing: 8) {
            Text(model.localizedString("プレビューの条件"))
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                Text(model.localizedString("時間帯"))
                    .frame(width: sceneLinkLabelWidth, alignment: .leading)
                Spacer(minLength: 0)
                Picker(model.localizedString("時間帯"), selection: $scenePreviewController.simulatedTimeOfDay) {
                    Text(String(format: model.localizedString("いまの時間帯(%@)"), sceneTimeOfDayName(now)))
                        .tag(SceneTimeOfDay?.none)
                    ForEach(SceneTimeOfDay.allCases, id: \.self) { timeOfDay in
                        Text(sceneTimeOfDayName(timeOfDay)).tag(SceneTimeOfDay?.some(timeOfDay))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: SceneInspectorMetrics.menuMaxWidth)
            }
            HStack(spacing: 12) {
                Text(model.localizedString("カーソル"))
                    .frame(width: sceneLinkLabelWidth, alignment: .leading)
                Spacer(minLength: 0)
                Picker(
                    model.localizedString("カーソル"),
                    selection: Binding(
                        get: { scenePreviewController.simulatedCursor.map { [$0.x, $0.y] } },
                        set: { value in
                            scenePreviewController.simulatedCursor = value.map { SIMD2($0[0], $0[1]) }
                        }
                    )
                ) {
                    Text(model.localizedString("ポインタに合わせる")).tag([Float]?.none)
                    Text(model.localizedString("中央")).tag([Float]?.some([0, 0]))
                    Text(model.localizedString("左端")).tag([Float]?.some([-1, 0]))
                    Text(model.localizedString("右端")).tag([Float]?.some([1, 0]))
                    Text(model.localizedString("上端")).tag([Float]?.some([0, -1]))
                    Text(model.localizedString("下端")).tag([Float]?.some([0, 1]))
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: SceneInspectorMetrics.menuMaxWidth)
            }
        }
    }

    private func sceneLinkRow(path: String, document: SceneDocument, link: SceneLink, isSelected: Bool) -> some View {
        let names = link.layerIDs.compactMap { id in document.layers.first { $0.id == id }?.name }
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { link.isEnabled },
                set: { value in updateSceneLink(link.id, path: path, coalescing: false) { $0.isEnabled = value } }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(model.localizedString("連動を有効にする"))
            .accessibilityValue(sceneLinkInputName(link.input))

            Button {
                selectSceneLink(link)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(sceneLinkInputName(link.input))
                        .foregroundColor(link.isEnabled ? .primary : .secondary)
                    Text(names.isEmpty ? model.localizedString("対象のレイヤーなし") : names.joined(separator: model.localizedString("・")))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
    private func sceneLinkInspector(path: String, document: SceneDocument, link: SceneLink) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.localizedString("対象のレイヤー"))
            // Bounded: imported scenes have hundreds of layers.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    // Top layer first, as in the layer list.
                    ForEach(document.layers.reversed()) { layer in
                        Toggle(isOn: Binding(
                        get: { link.layerIDs.contains(layer.id) },
                        set: { isOn in
                            updateSceneLink(link.id, path: path, coalescing: false) { link in
                                if isOn {
                                    link.layerIDs.append(layer.id)
                                } else {
                                    link.layerIDs.removeAll { $0 == layer.id }
                                }
                            }
                        }
                        )) {
                            Text(layer.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(layer.name)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
            settingsFootnote(model.localizedString("チェックしたレイヤーが、同じ値で一緒に変わります。"))

            Divider()

            switch link.input {
            case .timeOfDay:
                sceneTimeOfDayEditor(path: path, document: document, link: link)
            case .cursorX, .cursorY, .cursorDistance:
                sceneCursorEdgeEditor(path: path, link: link)
            }
        }
    }

    @ViewBuilder
    private func sceneTimeOfDayEditor(path: String, document: SceneDocument, link: SceneLink) -> some View {
        let editing = scenePreviewController.simulatedTimeOfDay ?? document.timeOfDay(at: Date())
        HStack(spacing: 12) {
            Text(model.localizedString("編集する時間帯"))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: sceneLinkLabelWidth, alignment: .leading)
            Picker(
                model.localizedString("編集する時間帯"),
                selection: Binding(
                    get: { editing },
                    set: { scenePreviewController.simulatedTimeOfDay = $0 }
                )
            ) {
                ForEach(SceneTimeOfDay.allCases, id: \.self) { timeOfDay in
                    Text(sceneTimeOfDayName(timeOfDay)).tag(timeOfDay)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: SceneInspectorMetrics.menuMaxWidth)
            Spacer(minLength: 0)
        }
        sceneLinkValueEditor(
            path: path, link: link,
            values: link.timeValues[editing] ?? .identity,
            set: { link, values in link.timeValues[editing] = values }
        )

        Divider()
        Text(model.localizedString("時間帯の始まり"))
        ForEach(SceneTimeOfDay.allCases, id: \.self) { timeOfDay in
            sceneTimeBandRow(path: path, document: document, timeOfDay: timeOfDay)
        }
        settingsFootnote(model.localizedString("それぞれの時間帯は、次の時間帯が始まるまで続きます。"))
    }

    private func sceneTimeBandRow(path: String, document: SceneDocument, timeOfDay: SceneTimeOfDay) -> some View {
        let minute = document.timeBands.first { $0.timeOfDay == timeOfDay }?.startMinute ?? 0
        let calendar = Calendar.current
        let date = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        return HStack(spacing: 12) {
            Text(sceneTimeOfDayName(timeOfDay))
                .frame(width: sceneLinkLabelWidth, alignment: .leading)
            DatePicker(
                sceneTimeOfDayName(timeOfDay),
                selection: Binding(
                    get: { date },
                    set: { newDate in
                        let parts = calendar.dateComponents([.hour, .minute], from: newDate)
                        let newMinute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                        guard var document = model.sceneDocumentsByPath[path],
                              let index = document.timeBands.firstIndex(where: { $0.timeOfDay == timeOfDay })
                        else {
                            return
                        }
                        document.timeBands[index].startMinute = newMinute
                        model.updateScene(document, path: path)
                    }
                ),
                displayedComponents: .hourAndMinute
            )
            .labelsHidden()
            .environment(\.locale, model.appLocale)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func sceneCursorEdgeEditor(path: String, link: SceneLink) -> some View {
        let isEnd = link.input == .cursorDistance
            || (scenePreviewController.simulatedCursor.map { $0.x + $0.y >= 0 } ?? true)
        if link.input != .cursorDistance {
            HStack(spacing: 12) {
                Text(model.localizedString("編集する位置"))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: sceneLinkLabelWidth, alignment: .leading)
                Picker(
                    model.localizedString("編集する位置"),
                    selection: Binding(
                        get: { isEnd },
                        set: { scenePreviewController.simulatedCursor = sceneLinkEdgeCursor(link.input, isEnd: $0) }
                    )
                ) {
                    Text(model.localizedString(link.input == .cursorX ? "左端" : "上端")).tag(false)
                    Text(model.localizedString(link.input == .cursorX ? "右端" : "下端")).tag(true)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: SceneInspectorMetrics.menuMaxWidth)
                Spacer(minLength: 0)
            }
        }
        sceneLinkValueEditor(
            path: path, link: link,
            values: isEnd ? link.end : link.start,
            set: { link, values in
                if isEnd {
                    link.end = values
                } else {
                    link.start = values
                }
            }
        )
        settingsFootnote(model.localizedString(
            link.input == .cursorDistance
                ? "カーソルが中央にあるときは何も変えず、画面の端に近づくほど、この値に近づきます。"
                : "カーソルが中央にあるときは何も変えず、端に近づくほど、それぞれの端の値に近づきます。"
        ))
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Sliders for one set of values (a part of the day, or an edge).
    @ViewBuilder
    private func sceneLinkValueEditor(
        path: String,
        link: SceneLink,
        values: SceneLinkValues,
        set: @escaping (inout SceneLink, SceneLinkValues) -> Void
    ) -> some View {
        let binding = { (keyPath: WritableKeyPath<SceneLinkValues, Double>) in
            Binding<Double>(
                get: { values[keyPath: keyPath] },
                set: { newValue in
                    var changed = values
                    changed[keyPath: keyPath] = newValue
                    updateSceneLink(link.id, path: path) { set(&$0, changed) }
                }
            )
        }
        sceneLinkSlider(model.localizedString("横位置"), binding(\.offsetX), -0.5 ... 0.5, text: percent(values.offsetX, signed: true))
        sceneLinkSlider(model.localizedString("縦位置"), binding(\.offsetY), -0.5 ... 0.5, text: percent(values.offsetY, signed: true))
        sceneLinkSlider(model.localizedString("角度"), binding(\.rotation), -180 ... 180, text: String(format: "%+.0f°", values.rotation))
        // In powers of two, so ×1 sits in the middle and halving mirrors doubling.
        sceneLinkSlider(
            model.localizedString("大きさ"),
            Binding(
                get: { log2(values.scale) },
                set: { binding(\.scale).wrappedValue = exp2($0) }
            ),
            log2(SceneLinkValues.scaleRange.lowerBound) ... log2(SceneLinkValues.scaleRange.upperBound),
            text: String(format: "×%.2f", values.scale)
        )
        sceneLinkSlider(model.localizedString("不透明度"), binding(\.opacity), 0 ... 1, text: percent(values.opacity, signed: false))
        sceneLinkSlider(model.localizedString("明るさ"), binding(\.brightness), -1 ... 1, text: percent(values.brightness, signed: true))
        sceneLinkSlider(model.localizedString("彩度"), binding(\.saturation), 0 ... 2, text: percent(values.saturation, signed: false))
        sceneLinkSlider(model.localizedString("色温度"), binding(\.warmth), -1 ... 1, text: percent(values.warmth, signed: true))
        HStack {
            Spacer(minLength: 0)
            Button(model.localizedString("この値をリセット")) {
                updateSceneLink(link.id, path: path, coalescing: false) { set(&$0, .identity) }
            }
            .disabled(values == .identity)
        }
    }

    private func percent(_ value: Double, signed: Bool) -> String {
        String(format: signed ? "%+.0f%%" : "%.0f%%", value * 100)
    }

    private func sceneLinkSlider(
        _ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, text: String
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: sceneLinkLabelWidth, alignment: .leading)
            Slider(value: value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(text)
            Text(text)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }

    // MARK: - Editing

    private func selectSceneLink(_ link: SceneLink) {
        selectedSceneLinkID = link.id
        // Show the values being edited instead of the cursor at rest, as the
        // pointer is on the sliders, not the preview.
        if link.input.usesCursor {
            scenePreviewController.simulatedCursor = sceneLinkEdgeCursor(link.input, isEnd: true)
        }
    }

    private func addSceneLink(_ input: SceneLinkInput, path: String, layerID: UUID?) {
        guard let layerID, var document = model.sceneDocumentsByPath[path] else {
            return
        }
        let link = SceneLink(input: input, layerIDs: [layerID])
        document.links.append(link)
        model.updateScene(document, path: path, coalescing: false)
        selectSceneLink(link)
    }

    private func removeSceneLink(_ id: UUID, path: String) {
        guard var document = model.sceneDocumentsByPath[path] else {
            return
        }
        document.links.removeAll { $0.id == id }
        model.updateScene(document, path: path, coalescing: false)
    }

    private func updateSceneLink(_ id: UUID, path: String, coalescing: Bool = true, _ change: (inout SceneLink) -> Void) {
        guard var document = model.sceneDocumentsByPath[path],
              let index = document.links.firstIndex(where: { $0.id == id })
        else {
            return
        }
        change(&document.links[index])
        model.updateScene(document, path: path, coalescing: coalescing)
    }
}

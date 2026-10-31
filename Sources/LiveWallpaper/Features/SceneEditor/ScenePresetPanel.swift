import SwiftUI

extension SceneEditorView {
    // MARK: - Menu

    /// Built-in and saved presets. Choosing one shows it on the preview first.
    func scenePresetMenu(path: String, layer: SceneLayer?) -> some View {
        let target = layer.flatMap { $0.kind == .image && !$0.isLocked ? $0 : nil }
        return Menu {
            Section(model.localizedString("完成例")) {
                ForEach(ScenePreset.BuiltIn.allCases, id: \.self) { kind in
                    Button(ScenePreset.builtIn(kind, localize: model.localizedString).name) {
                        if let target {
                            tryScenePreset(ScenePreset.builtIn(kind, localize: model.localizedString), layer: target, path: path)
                        }
                    }
                }
            }
            Section(model.localizedString("自分のプリセット")) {
                let presets = model.userScenePresets ?? []
                if presets.isEmpty {
                    Text(model.localizedString("保存したプリセットはまだありません"))
                }
                ForEach(presets) { preset in
                    Button(preset.name) {
                        if let target {
                            tryScenePreset(preset, layer: target, path: path)
                        }
                    }
                }
            }
            Divider()
            Button(model.localizedString("いまの設定をプリセットとして保存…")) {
                guard let target else {
                    return
                }
                // The sheet saves selectedSceneLayerID, which is nil while the list
                // only shows the top layer as selected by default.
                selectSceneLayer(target.id)
                scenePresetNameDraft = target.name
                scenePresetIncludesPaint = false
                scenePresetIncludesParticles = true
                isSavingScenePreset = true
            }
            if let presets = model.userScenePresets, !presets.isEmpty {
                Menu(model.localizedString("自分のプリセットを削除")) {
                    ForEach(presets) { preset in
                        Button(preset.name) {
                            scenePresetPendingDeletion = preset
                        }
                    }
                }
            }
        } label: {
            Label(model.localizedString("プリセット"), systemImage: "wand.and.stars")
        }
        .fixedSize()
        .disabled(target == nil || model.scenePresetTrial != nil)
        .help(model.localizedString(
            target == nil
                ? "ロックしていない画像レイヤーを選ぶと、プリセットを使えます"
                : "完成例や保存した設定を、選んだレイヤーに当てはめます。適用する前にプレビューで確かめられます。"
        ))
        .onAppear {
            model.loadUserScenePresetsIfNeeded()
        }
    }

    private func tryScenePreset(_ preset: ScenePreset, layer: SceneLayer, path: String) {
        endSceneEditorTool()
        scenePreviewController.isComparing = false
        model.beginScenePresetTrial(preset, layerID: layer.id, path: path)
    }

    // MARK: - Trial bar

    /// Shown under the preview while a preset is on show.
    func scenePresetTrialBar(_ trial: ScenePresetTrial) -> some View {
        let layerName = model.sceneDocumentsByPath[trial.path]?.layers.first { $0.id == trial.layerID }?.name ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .foregroundColor(.secondary)
                Text(String(format: model.localizedString("「%@」を試しています"), trial.preset.name))
                    .font(.headline)
                Spacer(minLength: 0)
                Button(model.localizedString("やめる")) {
                    model.endScenePresetTrial()
                }
                .keyboardShortcut(.cancelAction)
                Button(model.localizedString("適用")) {
                    let layerID = trial.layerID
                    model.applyScenePresetTrial()
                    selectSceneLayer(layerID)
                }
                .keyboardShortcut(.defaultAction)
            }
            if let kind = trial.preset.builtIn {
                settingsFootnote(model.localizedString(ScenePreset.summary(of: kind)))
            }
            settingsFootnote(String(
                format: model.localizedString("レイヤー「%@」の動き・奥行き・カーソルの設定を置き換え、粒子のレイヤーがあれば上に追加します。適用したあと ⌘Z で 1 回で元に戻せます。"),
                layerName
            ))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    // MARK: - Guide

    /// What is left to do after a preset, until done or dismissed.
    @ViewBuilder
    func scenePresetGuideCard(path: String, document: SceneDocument) -> some View {
        if let guide = model.scenePresetGuides[path], guide.isActive(in: document),
           let layer = document.layers.first(where: { $0.id == guide.layerID })
        {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(String(format: model.localizedString("「%@」の仕上げ"), guide.presetName))
                        .font(.headline)
                    Spacer(minLength: 0)
                    Button {
                        model.scenePresetGuides[path] = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help(model.localizedString("閉じる"))
                    .accessibilityLabel(model.localizedString("閉じる"))
                }
                ForEach(guide.visibleSteps(in: document)) { step in
                    let isDone = guide.isDone(step, in: document) ?? true
                    HStack(spacing: 8) {
                        Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(isDone ? .green : .secondary)
                            .accessibilityHidden(true)
                        Text(scenePresetStepText(step))
                            .foregroundColor(isDone ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !isDone {
                            scenePresetStepButton(step, path: path, layer: layer)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(model.localizedString(isDone ? "済み" : "未完了"))
                }
                settingsFootnote(String(
                    format: model.localizedString("レイヤー「%@」に当てはめました。終わった項目には印が付きます。"),
                    layer.name
                ))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
    }

    private func scenePresetStepText(_ step: ScenePresetStep) -> String {
        switch step {
        case let .paintMask(_, kind):
            String(format: model.localizedString("「%@」で動かす範囲を塗る"), sceneEffectName(kind))
        case .moveToOwnLayer:
            model.localizedString("塗った範囲を別のレイヤーにして、輪郭ごと動かす")
        case .drawFlow:
            model.localizedString("水が流れる向きを描く")
        case .addPins:
            model.localizedString("ピンを置く")
        case .estimateDepth:
            model.localizedString("奥行きを推定する(AI)")
        }
    }

    @ViewBuilder
    private func scenePresetStepButton(_ step: ScenePresetStep, path: String, layer: SceneLayer) -> some View {
        switch step {
        case let .paintMask(effectID, _), let .drawFlow(effectID):
            let kind: ScenePaintOverride.Target = if case .drawFlow = step { .flow } else { .mask }
            Button(model.localizedString(kind == .flow ? "描く" : "塗る")) {
                guard let effect = layer.effects.first(where: { $0.id == effectID }) else {
                    return
                }
                selectSceneLayer(layer.id)
                selectedSceneEffectID = effectID
                beginScenePainting(path: path, layerID: layer.id, effect: effect, kind: kind)
            }
            .controlSize(.small)
            .disabled(layer.isLocked)
        case let .moveToOwnLayer(effectID):
            if model.sceneAIWork[layer.id] == .separating {
                ProgressView()
                    .controlSize(.small)
            } else {
                let isPainted = layer.effects.first { $0.id == effectID }?.maskFile != nil
                Button(model.localizedString("別のレイヤーにする")) {
                    moveScenePaintedArea(path: path, layerID: layer.id, effectID: effectID)
                }
                .controlSize(.small)
                .disabled(layer.isLocked || !isPainted || model.sceneAIWork[layer.id] != nil)
                .help(isPainted ? "" : model.localizedString("先に範囲を塗ってください"))
            }
        case let .addPins(effectID):
            Button(model.localizedString("ピンを追加")) {
                selectSceneLayer(layer.id)
                selectedSceneEffectID = effectID
                sceneMaskPainter.end()
                sceneEditorTool = .addPins(effectID: effectID)
            }
            .controlSize(.small)
            .disabled(layer.isLocked)
        case .estimateDepth:
            if model.sceneAIWork[layer.id] != nil {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(model.localizedString("推定する")) {
                    model.estimateSceneDepth(layerID: layer.id, path: path)
                }
                .controlSize(.small)
                .disabled(layer.isLocked)
                .help(SceneAI.isDepthModelInstalled
                    ? ""
                    : String(
                        format: model.localizedString("初回だけ、Apple が公開しているモデル(約 %d MB)を Hugging Face からダウンロードします。"),
                        locale: model.appLocale, SceneAI.modelDownloadMegabytes
                    ))
            }
        }
    }

    // MARK: - Saving and deleting

    func scenePresetSaveSheet(path: String, layerID: UUID?) -> some View {
        let name = scenePresetNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 12) {
            Text(model.localizedString("プリセットとして保存"))
                .font(.headline)
            TextField(model.localizedString("プリセットの名前"), text: $scenePresetNameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)
            Toggle(model.localizedString("塗った範囲とピンの位置も含める"), isOn: $scenePresetIncludesPaint)
            settingsFootnote(model.localizedString("含めると、別の画像にも同じ割合の位置で当てはめます。構図の似た写真に使うときに便利です。含めない場合は、適用したあとに塗る操作を案内します。"))
            Toggle(model.localizedString("粒子のレイヤーも含める"), isOn: $scenePresetIncludesParticles)
            settingsFootnote(model.localizedString("選んだレイヤーの動き・奥行き・カーソルの設定を保存します。配置とキーフレーム、奥行きの推定結果は含めません。"))
            HStack {
                Spacer(minLength: 0)
                Button(model.localizedString("キャンセル")) {
                    isSavingScenePreset = false
                }
                .keyboardShortcut(.cancelAction)
                Button(model.localizedString("保存")) {
                    guard let layerID else {
                        return
                    }
                    if model.saveUserScenePreset(
                        name: name, layerID: layerID, path: path,
                        includingPaint: scenePresetIncludesPaint, includingParticles: scenePresetIncludesParticles
                    ) {
                        isSavingScenePreset = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || layerID == nil)
            }
        }
        .padding(20)
    }

    var scenePresetDeletionBinding: Binding<Bool> {
        Binding(
            get: { scenePresetPendingDeletion != nil },
            set: { if !$0 { scenePresetPendingDeletion = nil } }
        )
    }
}

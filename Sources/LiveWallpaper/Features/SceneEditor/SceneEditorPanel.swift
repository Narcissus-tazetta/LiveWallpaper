import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension SceneEditorView {
    private var sceneRowLabelWidth: CGFloat {
        SceneInspectorMetrics.labelWidth
    }

    var wallpaperSceneEditorPanel: some View {
        Group {
            if let document = model.sceneDocumentsByPath[path] {
                sceneEditorContent(path: path, document: document)
            } else {
                Text(model.localizedString("このシーンは削除されました"))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDisappear {
            endSceneEditorTool()
            model.endScenePresetTrial()
            model.bakeAllScenesNowIfPending()
        }
        .sheet(isPresented: $isSavingScenePreset) {
            scenePresetSaveSheet(path: path, layerID: selectedSceneLayerID)
        }
        .confirmationDialog(
            model.localizedString("プリセットを削除しますか?"),
            isPresented: scenePresetDeletionBinding,
            titleVisibility: .visible
        ) {
            Button(model.localizedString("削除"), role: .destructive) {
                if let preset = scenePresetPendingDeletion {
                    model.deleteUserScenePreset(preset.id)
                }
                scenePresetPendingDeletion = nil
            }
            Button(model.localizedString("キャンセル"), role: .cancel) {
                scenePresetPendingDeletion = nil
            }
        } message: {
            Text(scenePresetPendingDeletion?.name ?? "")
        }
    }

    @ViewBuilder
    private func sceneEditorContent(path: String, document: SceneDocument) -> some View {
        let selectedID = document.layers.contains(where: { $0.id == selectedSceneLayerID })
            ? selectedSceneLayerID
            : document.layers.last?.id
        let selectedLayer = selectedID.flatMap { id in document.layers.first { $0.id == id } }

        VStack(spacing: 0) {
            if #unavailable(macOS 14.0) {
                sceneEditorToolbarRow(path: path, selectedLayer: selectedLayer)
                Divider()
            }
            HSplitView {
                sceneLayerList(path: path, document: document, selectedID: selectedID)
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 360, maxHeight: .infinity)
                sceneCanvasColumn(path: path, document: document, selectedID: selectedID)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                sceneInspectorColumn(path: path, document: document, selectedLayer: selectedLayer)
                    .frame(minWidth: 340, idealWidth: 380, maxWidth: 540, maxHeight: .infinity)
            }
            Divider()
            sceneStatusBar(path: path)
        }
        .background {
            // The shortcuts live in the content: on macOS 14 the buttons are moved into the
            // window's AppKit toolbar, where SwiftUI shortcuts are not guaranteed to fire.
            Group {
                Button("") {
                    model.undoScene(path: path)
                    syncScenePainterWithDocument(path: path)
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndoScene(path: path))
                Button("") {
                    model.redoScene(path: path)
                    syncScenePainterWithDocument(path: path)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedoScene(path: path))
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
        .navigationTitle(model.registeredVideoDisplayName(for: path))
        .navigationSubtitle(model.localizedString("シーンエディタ"))
        .toolbar {
            ToolbarItem(placement: .principal) {
                sceneZoomControls()
            }
            // Separate items, so each group gets its own capsule with room around its text.
            ToolbarItem(placement: .primaryAction) {
                sceneHintsToggle()
            }
            ToolbarItem(placement: .primaryAction) {
                sceneComparisonControls(path: path)
            }
            ToolbarItem(placement: .primaryAction) {
                scenePresetMenu(path: path, layer: selectedLayer)
            }
            ToolbarItem(placement: .primaryAction) {
                sceneUndoRedoButtons(path: path)
            }
        }
    }

    // MARK: - Toolbar

    /// macOS 13 has no way to put the toolbar into the window, so it is a row of the content.
    private func sceneEditorToolbarRow(path: String, selectedLayer: SceneLayer?) -> some View {
        HStack(spacing: 12) {
            sceneZoomControls()
            Spacer(minLength: 8)
            sceneHintsToggle()
            sceneComparisonControls(path: path)
            scenePresetMenu(path: path, layer: selectedLayer)
                .fixedSize()
            sceneUndoRedoButtons(path: path)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    private func sceneHintsToggle() -> some View {
        Toggle(isOn: $showsSceneHints) {
            Image(systemName: "info.circle")
        }
        .toggleStyle(.button)
        .iconHelp(model.localizedString(showsSceneHints ? "説明を隠す" : "説明を表示"))
    }

    private func sceneUndoRedoButtons(path: String) -> some View {
        ControlGroup {
            Button {
                model.undoScene(path: path)
                syncScenePainterWithDocument(path: path)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!model.canUndoScene(path: path))
            .iconHelp(model.localizedString("取り消す(⌘Z)"))

            Button {
                model.redoScene(path: path)
                syncScenePainterWithDocument(path: path)
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!model.canRedoScene(path: path))
            .iconHelp(model.localizedString("やり直す(⇧⌘Z)"))
        }
        .fixedSize()
    }

    // MARK: - Canvas

    @ViewBuilder
    private func sceneCanvasColumn(path: String, document: SceneDocument, selectedID: UUID?) -> some View {
        let comparison = scenePreviewController.isComparing ? model.sceneComparisonSnapshots[path] : nil
        let trial = model.scenePresetTrial.flatMap { $0.path == path ? $0 : nil }
        let isEditable = comparison == nil && trial == nil
        let fixedTime = selectedID
            .flatMap { id in document.layers.first { $0.id == id } }
            .flatMap { selectedSceneKeyframe(in: $0) }
            .map { $0.time * Double(document.loopSeconds) }
        let visibleRegions = model.desktopVisibleRegions(path: path, videoAspectRatio: document.aspectRatio)

        VStack(spacing: 0) {
            ScenePreviewView(
                document: comparison ?? trial?.document ?? document,
                videoPath: path,
                controller: scenePreviewController,
                interaction: isEditable ? scenePreviewInteraction(layerID: selectedID) : .hover,
                painter: sceneMaskPainter,
                onPickPoint: { point in
                    if let selectedID {
                        handleScenePreviewPick(point, path: path, layerID: selectedID)
                    }
                },
                onSelectLayer: { id in
                    selectSceneLayer(id)
                },
                editableTransform: { layer in
                    sceneEditableTransform(of: layer)
                },
                onTransformLayer: { id, transform in
                    applySceneTransform(transform, path: path, layerID: id)
                },
                markers: isEditable ? scenePreviewMarkers(document: document, layerID: selectedID) : [],
                fixedTime: fixedTime,
                visibleRegions: visibleRegions,
                onScriptIssues: { issues in
                    if model.sceneScriptIssues[path] != issues { model.sceneScriptIssues[path] = issues }
                },
                onScriptLogs: { model.receiveSceneScriptLogs($0, path: path) }
            )
            .aspectRatio(CGFloat(document.aspectRatio), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
            .overlay(alignment: .topLeading) {
                if comparison != nil || trial != nil {
                    Text(model.localizedString(comparison != nil ? "記録した状態を表示中" : "プリセットを試し中"))
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if scenePreviewController.simulatedTimeOfDay != nil || scenePreviewController.simulatedCursor != nil {
                    HStack(spacing: 6) {
                        Text(scenePreviewConditionText())
                            .font(.caption)
                        Button(model.localizedString("戻す")) {
                            scenePreviewController.simulatedTimeOfDay = nil
                            scenePreviewController.simulatedCursor = nil
                        }
                        .controlSize(.small)
                        .help(model.localizedString("いまの時間帯と、ポインタの位置に戻します"))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .padding(8)
                }
            }
            .accessibilityLabel(model.localizedString("プレビュー"))
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
            .task(id: path) {
                if let trial = model.scenePresetTrial, trial.path != path {
                    model.endScenePresetTrial()
                }
                if model.sceneComparisonSnapshots[path] == nil {
                    model.recordSceneComparison(path: path)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                scenePlaybackBar(path: path, document: document, selectedID: selectedID, fixedTime: fixedTime)
                sceneCanvasHint(path: path, comparison: comparison, trial: trial, visibleRegions: visibleRegions)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    /// What the pointer does on the canvas right now, or the bar of the tool in use.
    @ViewBuilder
    private func sceneCanvasHint(
        path _: String,
        comparison: SceneDocument?,
        trial: ScenePresetTrial?,
        visibleRegions: [CGRect]
    ) -> some View {
        if comparison != nil {
            settingsFootnote(model.localizedString("記録した状態を、いまと同じ時刻・カーソル位置で表示しています。編集内容は変わりません。"))
        } else if let trial {
            scenePresetTrialBar(trial)
        } else if case let .paint(_, kind) = sceneEditorTool {
            scenePaintBar(kind: kind)
        } else if case .pickCenter = sceneEditorTool {
            settingsFootnote(model.localizedString("プレビューをクリックして、中心にする位置を選びます。"))
        } else if case .addPins = sceneEditorTool {
            settingsFootnote(model.localizedString("プレビューをクリックすると、その位置にピンを追加します。最初のピンは固定、それ以降は揺らすピンになります。"))
        } else {
            settingsFootnote(
                model.localizedString("レイヤーをクリックして選び、ドラッグで移動します。四隅で拡大・縮小、上の丸で回転します(⇧で15°ずつ、⌘でスナップなし)。ポインタを動かすと、カーソルへの反応も確かめられます。")
            )
        }
        if visibleRegions.contains(where: { $0.width < 0.999 || $0.height < 0.999 }) {
            settingsFootnote(model.localizedString("暗い部分は、デスクトップでは画面の外になり表示されません。"))
        }
    }

    // MARK: - Inspector

    private func sceneInspectorColumn(path: String, document: SceneDocument, selectedLayer: SceneLayer?) -> some View {
        VStack(spacing: 0) {
            Picker(model.localizedString("インスペクタ"), selection: $inspectorTab) {
                Text(model.localizedString("レイヤー")).tag(SceneInspectorTab.layer)
                Text(model.localizedString("動き")).tag(SceneInspectorTab.motion)
                Text(model.localizedString("連動")).tag(SceneInspectorTab.links)
                Text(model.localizedString("シーン")).tag(SceneInspectorTab.scene)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    sceneInspectorContent(path: path, document: document, selectedLayer: selectedLayer)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func sceneInspectorContent(path: String, document: SceneDocument, selectedLayer: SceneLayer?) -> some View {
        switch inspectorTab {
        case .layer:
            scenePresetGuideCard(path: path, document: document)
            if let layer = selectedLayer {
                sceneInspectorLayerHeader(path: path, layer: layer)
                sceneLayerInspector(path: path, layer: layer)
                if layer.particleSystem != nil {
                    Divider()
                    sceneParticleSystemSection(path: path, layer: layer)
                }
            } else {
                sceneInspectorEmpty()
            }
        case .motion:
            if let layer = selectedLayer {
                sceneInspectorLayerHeader(path: path, layer: layer)
                sceneEffectsSection(path: path, layer: layer)
                    .disabled(layer.isLocked)
            } else {
                sceneInspectorEmpty()
            }
        case .links:
            sceneLinksSection(path: path, document: document, selectedLayerID: selectedLayer?.id)
        case .scene:
            sceneDocumentSettings(path: path, document: document)
            SceneScriptPanel(model: model, editor: sceneScriptEditor, preview: scenePreviewController,
                             path: path, selectedLayerID: selectedLayer?.id)
        }
    }

    /// Which layer the tab edits, since the list may be scrolled away from it.
    private func sceneInspectorLayerHeader(path: String, layer: SceneLayer) -> some View {
        HStack(spacing: 10) {
            SceneLayerThumbnail(
                url: sceneLayerThumbnailURL(layer, path: path),
                symbol: sceneLayerSymbol(layer),
                isVideo: layer.videoFile != nil
            )
            Text(layer.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(layer.name)
                .frame(maxWidth: .infinity, alignment: .leading)
            if layer.isLocked {
                Image(systemName: "lock.fill")
                    .foregroundColor(.secondary)
                    .help(model.localizedString("ロックを解除"))
            }
        }
        .padding(.bottom, 2)
    }

    private func sceneInspectorEmpty() -> some View {
        Text(model.localizedString("レイヤーを選ぶと、ここで設定できます"))
            .font(.callout)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 24)
    }

    @ViewBuilder
    private func sceneDocumentSettings(path: String, document: SceneDocument) -> some View {
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
            .frame(maxWidth: SceneInspectorMetrics.menuMaxWidth)
        }
        settingsFootnote(
            model.localizedString("動きはこの長さで一周します。ロック画面かスクリーンセーバーにこの壁紙を選ぶと、この長さの動画を書き出して使います。長いほど書き出しに時間がかかります。デスクトップに合わせたスクリーンセーバーには、最後に書き出した動画を使います。")
        )
        if document.usesAudio {
            SceneSoundReactionToggle(model: model, path: path)
        }
        Divider()
    }

    // MARK: - Status bar

    private func sceneStatusBar(path: String) -> some View {
        HStack(spacing: 12) {
            sceneStatusRow(path: path)
            if let message = model.sceneErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 26)
        .help(model.localizedString("変更はすぐに壁紙へ反映されます。ロック画面とスクリーンセーバーでは、カーソルに反応していない状態で表示されます。"))
    }

    // MARK: - Status

    /// Saving and the baked video are reported apart: an edit can be saved while the
    /// lock screen still shows the previous video.
    private func sceneStatusRow(path: String) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                if let failure = model.sceneSaveFailures[path] {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(model.localizedString("保存できませんでした"))
                        .help(failure)
                    Button(model.localizedString("再試行")) {
                        model.retrySceneSave(path: path)
                    }
                    .controlSize(.small)
                } else if model.scenesSaving.contains(path) {
                    Image(systemName: "circle.dotted")
                        .foregroundColor(.secondary)
                    Text(model.localizedString("保存中…"))
                } else {
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(.secondary)
                    Text(model.localizedString("保存済み"))
                }
            }

            HStack(spacing: 4) {
                if model.sceneVideosAwaitingScriptApproval.contains(path) {
                    Image(systemName: "pause.circle")
                        .foregroundColor(.orange)
                    Text(model.localizedString("未許可のスクリプトがあるため、ロック画面用の動画を更新していません。スクリプトを許可するか停止すると書き出します"))
                        .fixedSize(horizontal: false, vertical: true)
                } else if let failure = model.sceneBakeFailures[path] {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(model.localizedString("動画を書き出せませんでした。ロック画面とスクリーンセーバーは前の動画のままです"))
                        .help(failure)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(model.localizedString("再試行")) {
                        model.retrySceneBake(path: path)
                    }
                    .controlSize(.small)
                } else if model.scenesBakeRunning.contains(path) {
                    SceneBakeRunningStatus(model: model, progress: model.sceneBakeProgressStore, path: path)
                } else if model.scenesBaking.contains(path) {
                    Image(systemName: "clock")
                        .foregroundColor(.secondary)
                    Text(model.localizedString("編集が止まると、ロック画面用の動画を書き出します"))
                    Button(model.localizedString("今すぐ書き出す")) {
                        model.bakeSceneNowIfPending(path: path)
                    }
                    .controlSize(.small)
                } else {
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(.secondary)
                    Text(model.localizedString("ロック画面用の動画は最新です"))
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    // MARK: - Layer list

    private func sceneLayerList(path: String, document: SceneDocument, selectedID: UUID?) -> some View {
        let selectedLayer = selectedID.flatMap { id in document.layers.first { $0.id == id } }
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(model.localizedString("レイヤー"))
                    .font(.headline)
                    .help(model.localizedString("ドラッグで重ね順を変えられます。名前はダブルクリックで変更できます。"))
                if model.sceneLayerImportCounts[path] != nil {
                    ProgressView()
                        .controlSize(.small)
                        .help(model.localizedString("画像を読み込み中…"))
                }
                Spacer(minLength: 0)
                sceneAddLayerMenu(path: path)
                    .fixedSize()
                    .sceneFocusRingHidden()
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            Divider()
            ScrollView {
                // Lazy: imported scenes reach hundreds of layers, each row with a thumbnail to load.
                LazyVStack(spacing: 1) {
                    // Top layer first, as in image editors.
                    ForEach(document.layers.reversed()) { layer in
                        sceneLayerRow(path: path, document: document, layer: layer, isSelected: layer.id == selectedID)
                    }
                }
                .padding(6)
            }
            Divider()
            HStack(spacing: 2) {
                Button {
                    if let selectedID {
                        duplicateSceneLayer(path: path, id: selectedID)
                    }
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .disabled(selectedID == nil)
                .help(model.localizedString("選択したレイヤーを複製"))
                .accessibilityLabel(model.localizedString("選択したレイヤーを複製"))

                Button {
                    if let selectedID {
                        model.removeSceneLayer(id: selectedID, path: path)
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(document.layers.count <= 1 || selectedLayer?.isLocked == true)
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
            .padding(.horizontal, 10)
            .frame(height: 30)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    func sceneLayerSymbol(_ layer: SceneLayer) -> String {
        switch layer.kind {
        case .particles: "sparkles"
        case .text: "textformat"
        case .model: "cube"
        case .image: layer.videoFile != nil ? "film" : "photo"
        }
    }

    func sceneLayerThumbnailURL(_ layer: SceneLayer, path: String) -> URL? {
        guard layer.kind == .image, !layer.imageFile.isEmpty else {
            return nil
        }
        return SceneStore.folderURL(forVideoPath: path).appendingPathComponent(layer.imageFile)
    }

    private func sceneLayerRow(path: String, document: SceneDocument, layer: SceneLayer, isSelected: Bool) -> some View {
        let showsLock = layer.isLocked || hoveredSceneLayerID == layer.id || isSelected
        return HStack(spacing: 8) {
            Button {
                updateSceneLayer(path: path, id: layer.id, allowLocked: true) { $0.isVisible.toggle() }
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .foregroundColor(layer.isVisible ? .secondary : .secondary.opacity(0.5))
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(model.localizedString(layer.isVisible ? "レイヤーを隠す" : "レイヤーを表示"))
            .accessibilityLabel(model.localizedString(layer.isVisible ? "レイヤーを隠す" : "レイヤーを表示"))
            .accessibilityValue(layer.name)

            SceneLayerThumbnail(
                url: sceneLayerThumbnailURL(layer, path: path),
                symbol: sceneLayerSymbol(layer),
                isVideo: layer.videoFile != nil
            )
            .opacity(layer.isVisible ? 1 : 0.4)

            if renamingSceneLayerID == layer.id {
                TextField(model.localizedString("レイヤー名"), text: $sceneLayerNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit {
                        commitSceneLayerRename(path: path, id: layer.id)
                    }
                    .onExitCommand {
                        renamingSceneLayerID = nil
                    }
            } else {
                HStack(spacing: 6) {
                    Text(layer.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(layer.isVisible ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(layer.name)
                    if layer.cursorMask != nil {
                        Image(systemName: "circle.dashed")
                            .foregroundColor(.secondary)
                            .help(model.localizedString("カーソルで透かす"))
                    }
                    if !layer.effects.isEmpty {
                        Image(systemName: "wind")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .help(model.localizedString("動き"))
                    }
                }
                .contentShape(Rectangle())
                // Selecting must not wait to see whether a second click follows.
                .gesture(TapGesture(count: 2).onEnded {
                    beginSceneLayerRename(layer)
                })
                .simultaneousGesture(TapGesture().onEnded {
                    selectSceneLayer(layer.id)
                })
                .accessibilityElement(children: .combine)
                .accessibilityLabel(layer.name)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction {
                    selectSceneLayer(layer.id)
                }
                .accessibilityAction(named: model.localizedString("名前を変更")) {
                    beginSceneLayerRename(layer)
                }
            }

            Button {
                toggleSceneLayerLock(path: path, layer: layer)
            } label: {
                Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                    .foregroundColor(layer.isLocked ? .primary : .secondary)
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            // Kept in the layout while hidden, so names do not shift under the pointer.
            .opacity(showsLock ? 1 : 0)
            .help(model.localizedString(layer.isLocked ? "ロックを解除" : "ロックして、誤って動かしたり変えたりしないようにする"))
            .accessibilityLabel(model.localizedString(layer.isLocked ? "ロックを解除" : "ロック"))
            .accessibilityValue(layer.name)
        }
        .onHover { inside in
            if inside {
                hoveredSceneLayerID = layer.id
            } else if hoveredSceneLayerID == layer.id {
                hoveredSceneLayerID = nil
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.12) : hoveredSceneLayerID == layer.id ? Color.primary.opacity(0.05) : Color.clear)
        )
        .contextMenu {
            Button(model.localizedString("名前を変更")) {
                beginSceneLayerRename(layer)
            }
            Button(model.localizedString("複製")) {
                duplicateSceneLayer(path: path, id: layer.id)
            }
            Button(model.localizedString(layer.isLocked ? "ロックを解除" : "ロック")) {
                toggleSceneLayerLock(path: path, layer: layer)
            }
            Divider()
            Button(model.localizedString("削除")) {
                model.removeSceneLayer(id: layer.id, path: path)
            }
            .disabled(document.layers.count <= 1 || layer.isLocked)
        }
        .onDrag {
            draggedSceneLayerID = layer.id
            return NSItemProvider(object: layer.id.uuidString as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: SceneLayerDropDelegate(
                targetID: layer.id,
                draggedID: $draggedSceneLayerID,
                move: { draggedID in
                    guard let destination = document.layers.firstIndex(where: { $0.id == layer.id }) else {
                        return
                    }
                    model.moveSceneLayer(id: draggedID, to: destination, path: path)
                }
            )
        )
    }

    private func toggleSceneLayerLock(path: String, layer: SceneLayer) {
        // Painting or picking points on a layer is changing it.
        if !layer.isLocked, layer.id == selectedSceneLayerID {
            endSceneEditorTool()
        }
        updateSceneLayer(path: path, id: layer.id, allowLocked: true) { $0.isLocked.toggle() }
    }

    private func beginSceneLayerRename(_ layer: SceneLayer) {
        selectSceneLayer(layer.id)
        sceneLayerNameDraft = layer.name
        renamingSceneLayerID = layer.id
    }

    private func commitSceneLayerRename(path: String, id: UUID) {
        let name = sceneLayerNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingSceneLayerID = nil
        guard !name.isEmpty else {
            return
        }
        updateSceneLayer(path: path, id: id, allowLocked: true) { $0.name = name }
    }

    private func duplicateSceneLayer(path: String, id: UUID) {
        if let copy = model.duplicateSceneLayer(id: id, path: path) {
            selectSceneLayer(copy)
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private func sceneLayerInspector(path: String, layer: SceneLayer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let particles = layer.particles {
                sceneParticleControls(path: path, layer: layer, particles: particles)
            }
            if let text = layer.text {
                sceneTextControls(path: path, layer: layer, text: text)
            }
            if let placement = layer.modelPlacement {
                sceneModelControls(path: path, layer: layer, placement: placement)
            }
            sceneLayoutSlider(
                title: model.localizedString("不透明度"),
                value: sceneLayerBinding(path: path, layer: layer, \.opacity),
                range: 0 ... 1,
                factor: 100,
                unit: "%",
                labelWidth: sceneRowLabelWidth
            )

            // A model is drawn into the canvas with its own material, which no blend mode, parallax or mask reaches.
            if layer.kind != .model {
                sceneLayerCompositingControls(path: path, layer: layer)
            }
            sceneLayoutControls(path: path, layer: layer)
            // The cut-out and depth work on one still picture; a video layer has none.
            if layer.kind == .image, layer.videoFile == nil {
                sceneAIControls(path: path, layer: layer)
            }
        }
        // Locked means the same in the inspector as on the preview.
        .disabled(layer.isLocked)
    }

    @ViewBuilder
    private func sceneLayerCompositingControls(path: String, layer: SceneLayer) -> some View {
        HStack(spacing: 12) {
            Text(model.localizedString("合成"))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: sceneRowLabelWidth, alignment: .leading)
            Spacer(minLength: 0)
            Picker(model.localizedString("合成"), selection: sceneLayerBinding(path: path, layer: layer, \.blendMode)) {
                sceneBlendModePickerContent()
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: SceneInspectorMetrics.menuMaxWidth)
        }

        if layer.kind == .image {
            sceneLayerSourceToggles(path: path, layer: layer)
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
            .frame(maxWidth: SceneInspectorMetrics.menuMaxWidth)
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
    }

    private func sceneParticleSystemSection(path: String, layer: SceneLayer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.localizedString("粒子"))
                .font(.headline)
            SceneParticleSystemEditor(
                model: model,
                path: path,
                system: Binding(
                    get: {
                        model.sceneDocumentsByPath[path]?.layers.first { $0.id == layer.id }?.particleSystem
                            ?? layer.particleSystem ?? SceneParticleSystem()
                    },
                    set: { system in
                        updateSceneLayer(path: path, id: layer.id) { layer in
                            // The layer composites additive particles with add, which keeps
                            // light where their alpha is 0.
                            if system.blend != layer.particleSystem?.blend {
                                if system.blend == .add {
                                    layer.blendMode = .add
                                } else if layer.blendMode == .add {
                                    layer.blendMode = .normal
                                }
                            }
                            layer.particleSystem = system
                        }
                    }
                )
            )
            .id(layer.id)
        }
        .disabled(layer.isLocked)
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

    /// Locked layers only take changes that the lock allows (visibility, the lock
    /// itself, the name).
    private func updateSceneLayer(
        path: String,
        id: UUID,
        allowLocked: Bool = false,
        _ change: (inout SceneLayer) -> Void
    ) {
        guard var document = model.sceneDocumentsByPath[path],
              let index = document.layers.firstIndex(where: { $0.id == id }),
              allowLocked || !document.layers[index].isLocked
        else {
            return
        }
        change(&document.layers[index])
        model.updateScene(document, path: path, coalescing: !allowLocked)
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
        model.updateScene(document, path: path, coalescing: false)
    }

    /// Undo and redo can swap the painted file or remove what is being painted.
    private func syncScenePainterWithDocument(path: String) {
        guard let target = sceneMaskPainter.target, target.path == path else {
            return
        }
        guard let file = model.sceneDocumentsByPath[path]?.paintFile(
            layerID: target.layerID, effectID: target.effectID, kind: target.kind
        ) else {
            endSceneEditorTool()
            return
        }
        sceneMaskPainter.reload(existingFile: file)
    }

    func selectSceneLayer(_ id: UUID) {
        if renamingSceneLayerID != id {
            renamingSceneLayerID = nil
        }
        if selectedSceneLayerID != id {
            endSceneEditorTool()
            selectedSceneEffectID = nil
            selectedSceneKeyframeID = nil
            selectedScenePinID = nil
        }
        selectedSceneLayerID = id
    }

    func chooseSceneLayerVideo(path: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        Task {
            guard let id = await model.addSceneVideoLayer(from: url, path: path),
                  isStillEditing
            else {
                return
            }
            selectSceneLayer(id)
        }
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
        let urls = panel.urls
        Task {
            guard let id = await model.addSceneLayers(from: urls, path: path),
                  isStillEditing
            else {
                return
            }
            selectSceneLayer(id)
        }
    }
}

/// Drops a dragged layer row onto another: the dragged layer takes that row's place.
struct SceneLayerDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var draggedID: UUID?
    let move: (UUID) -> Void

    func validateDrop(info _: DropInfo) -> Bool {
        draggedID != nil
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        defer { draggedID = nil }
        guard let draggedID, draggedID != targetID else {
            return false
        }
        move(draggedID)
        return true
    }
}

/// Observes the progress alone, so its updates redraw this status and not the settings window.
private struct SceneBakeRunningStatus: View {
    let model: WallpaperModel
    @ObservedObject var progress: SceneBakeProgress
    let path: String

    var body: some View {
        ProgressView()
            .controlSize(.mini)
        if let value = progress.values[path] {
            Text(String(
                format: model.localizedString("ロック画面用の動画を書き出し中… %d%%"), locale: model.appLocale,
                Int((value * 100).rounded())
            ))
            .monospacedDigit()
        } else {
            Text(model.localizedString("ロック画面用の動画を準備中…"))
        }
    }
}

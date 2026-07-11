import SwiftUI

extension SettingsView {
    private var fitEditorRowLabelWidth: CGFloat {
        72
    }

    var wallpaperFitEditorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(model.localizedString("フィット編集"), systemImage: "crop")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }

            if let path = fitEditor.resolvedVideoPath(),
               !path.isEmpty
            {
                let screenID = fitEditor.resolvedScreenID()
                fitEditorContent(path: path, screenID: screenID)
            } else {
                Text(model.localizedString("下の壁紙一覧から動画を選択すると、画面ごとにフィット設定を編集できます"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    @ViewBuilder
    private func fitEditorContent(path: String, screenID: String) -> some View {
        let fitModeValue = fitEditor.fitMode(path: path, screenID: screenID)
        let zoomValue = fitEditor.zoom(path: path, screenID: screenID)
        let offsetXValue = fitEditor.offsetX(path: path, screenID: screenID)
        let offsetYValue = fitEditor.offsetY(path: path, screenID: screenID)
        let isDirty = fitEditor.isDraftDirty(path: path, screenID: screenID)
        let hasOverride = model.hasWallpaperPresentationOverride(path: path, screenID: screenID)
        let panGeometry = model.wallpaperRenderGeometry(
            path: path,
            screenID: screenID,
            containerSize: fitEditor.resolvedConstraintFrameSize(screenID: screenID),
            fitMode: fitModeValue,
            zoom: zoomValue,
            offsetX: offsetXValue,
            offsetY: offsetYValue
        )
        let canPanX = panGeometry.maxPan.width > 0.5
        let canPanY = panGeometry.maxPan.height > 0.5

        HStack(spacing: 10) {
            Text(model.registeredVideoDisplayName(for: path))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !fitEditor.screens.isEmpty {
                Picker(
                    "",
                    selection: Binding<String>(
                        get: { fitEditor.resolvedScreenID() },
                        set: { fitEditor.selectScreen($0) }
                    )
                ) {
                    ForEach(fitEditor.screens) { screen in
                        Text(screen.name).tag(screen.id)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
        }

        if let dimensionsText = fitEditorDimensionsText(path: path, screenID: screenID) {
            Text(dimensionsText)
                .font(.caption)
                .foregroundColor(.secondary)
        }

        wallpaperFitPreview(path: path, screenID: screenID)

        fitEditorPrimaryActions(path: path, screenID: screenID, isDirty: isDirty)

        if expandedHelpTopics.contains(.fitLiveApply) {
            settingsFootnote(
                model.localizedString(
                    "オンにすると、編集内容が保存操作なしで自動的に壁紙へ反映されます"
                )
            )
        }

        fitEditorSecondaryActions(path: path, screenID: screenID, hasOverride: hasOverride)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text(model.localizedString("表示"))
                    helpIconButton(for: .perVideoFitMode)
                }
                .frame(width: fitEditorRowLabelWidth, alignment: .leading)
                Spacer(minLength: 0)
                EqualSegmentedControl(
                    options: [
                        (model.localizedString("拡大"), VideoFitMode.fill),
                        (model.localizedString("全体"), VideoFitMode.fit)
                    ],
                    selection: fitEditor.fitModeBinding(path: path, screenID: screenID)
                )
                .frame(width: fitEditorSegmentedPickerWidth, height: 24)
            }

            if expandedHelpTopics.contains(.perVideoFitMode) {
                settingsFootnote(
                    model.localizedString(
                        "ここで変更すると、この動画・この画面だけの表示方法を上書きします。未設定の場合は設定タブの既定値が使われます"
                    )
                )
            }
        }

        HStack(spacing: 12) {
            Text(model.localizedString("プレビュー"))
                .lineLimit(1)
                .frame(width: fitEditorRowLabelWidth, alignment: .leading)
            Spacer(minLength: 0)
            EqualSegmentedControl(
                options: [
                    (model.localizedString("動画"), FitPreviewMode.video),
                    (model.localizedString("静止画"), FitPreviewMode.still)
                ],
                selection: Binding(
                    get: { fitEditor.previewMode },
                    set: { fitEditor.setPreviewMode($0) }
                )
            )
            .frame(width: fitEditorSegmentedPickerWidth, height: 24)
        }

        HStack(spacing: 12) {
            Text(model.localizedString("ズーム"))
                .frame(width: fitEditorRowLabelWidth, alignment: .leading)
            Slider(
                value: fitEditor.zoomBinding(path: path, screenID: screenID),
                in: WallpaperGeometry.zoomRange
            )
            fitEditorValueText(String(format: "%.2fx", zoomValue)) {
                fitEditor.setDraftZoom(1.0, path: path, screenID: screenID)
            }
        }

        HStack(spacing: 12) {
            Text(model.localizedString("横位置"))
                .frame(width: fitEditorRowLabelWidth, alignment: .leading)
            Slider(value: fitEditor.offsetXBinding(path: path, screenID: screenID), in: -1 ... 1)
                .disabled(!canPanX)
            fitEditorValueText(String(format: "%+.0f%%", offsetXValue * 100)) {
                fitEditor.setDraftOffsetX(0, path: path, screenID: screenID)
            }
        }
        .opacity(canPanX ? 1 : 0.5)

        HStack(spacing: 12) {
            Text(model.localizedString("縦位置"))
                .frame(width: fitEditorRowLabelWidth, alignment: .leading)
            Slider(value: fitEditor.offsetYBinding(path: path, screenID: screenID), in: -1 ... 1)
                .disabled(!canPanY)
            fitEditorValueText(String(format: "%+.0f%%", offsetYValue * 100)) {
                fitEditor.setDraftOffsetY(0, path: path, screenID: screenID)
            }
        }
        .opacity(canPanY ? 1 : 0.5)

        if !canPanX, !canPanY {
            Text(model.localizedString("今の表示設定では動かせる余白がありません。ズームを上げるか「拡大」表示にすると位置を調整できます"))
                .font(.caption)
                .foregroundColor(.secondary)
        }

        Text(model.localizedString("ドラッグまたは矢印キーで位置を調整できます（Shift 併用で速く移動）。ピンチまたは Option+スクロールでカーソル位置を中心にズームします"))
            .font(.caption)
            .foregroundColor(.secondary)
        Text(
            fitEditor.liveApplyEnabled
                ? model.localizedString("変更は自動的に壁紙へ反映されます")
                : model.localizedString("この画面ではプレビューのみ更新されます。『保存して再適用』で壁紙に反映されます")
        )
        .font(.caption)
        .foregroundColor(.secondary)
    }

    private func fitEditorPrimaryActions(
        path: String,
        screenID: String,
        isDirty: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Toggle(
                model.localizedString("リアルタイム反映"),
                isOn: Binding(
                    get: { fitEditor.liveApplyEnabled },
                    set: { fitEditor.setLiveApplyEnabled($0, path: path, screenID: screenID) }
                )
            )
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            helpIconButton(for: .fitLiveApply)

            Spacer(minLength: 0)

            if fitEditor.showsSavedFeedback {
                Label(model.localizedString("反映しました"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
                    .transition(.opacity)
            }

            Button(model.localizedString("保存して再適用")) {
                fitEditor.applyDraft(path: path, screenID: screenID)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isDirty)

            Button(model.localizedString("変更を破棄")) {
                fitEditor.discardDraftChanges(path: path, screenID: screenID)
            }
            .buttonStyle(.bordered)
            .disabled(!isDirty)
            .help(model.localizedString("未保存の編集を取り消して、保存済みの状態に戻します"))
        }
        .animation(.easeInOut(duration: 0.15), value: fitEditor.showsSavedFeedback)
    }

    private func fitEditorSecondaryActions(
        path: String,
        screenID: String,
        hasOverride: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Button(model.localizedString("リセット")) {
                fitEditor.resetDraft(path: path, screenID: screenID)
            }
            .buttonStyle(.bordered)
            .help(model.localizedString("ズームと位置を初期値に戻します（保存するまで壁紙には反映されません）"))

            Button(model.localizedString("既定値に従う")) {
                fitEditor.clearOverride(path: path, screenID: screenID)
            }
            .buttonStyle(.bordered)
            .disabled(!hasOverride)
            .help(model.localizedString("この動画・この画面の個別設定を削除して、設定タブの既定値を使います"))

            if fitEditor.screens.count > 1 {
                Button(model.localizedString("全ての画面へ適用")) {
                    fitEditor.applyDraftToAllScreens(path: path, screenID: screenID)
                }
                .buttonStyle(.bordered)
                .help(model.localizedString("現在の編集内容を保存して、接続中のすべての画面へコピーします"))
            }

            Spacer(minLength: 0)
        }
    }

    /// スライダー右側の数値表示。ダブルクリックで初期値に戻せる。
    private func fitEditorValueText(_ text: String, resetAction: @escaping () -> Void) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(width: 50, alignment: .trailing)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: resetAction)
            .help(model.localizedString("ダブルクリックで初期値に戻します"))
    }

    private func fitEditorDimensionsText(path: String, screenID: String) -> String? {
        var parts: [String] = []
        if let videoSize = model.videoNaturalSize(for: path) {
            parts.append(
                "\(model.localizedString("動画")) \(Int(videoSize.width))×\(Int(videoSize.height))"
            )
        }
        if let screenSize = model.screenPixelSize(screenID: screenID) {
            parts.append(
                "\(model.localizedString("画面")) \(Int(screenSize.width))×\(Int(screenSize.height))"
            )
        }
        guard !parts.isEmpty else {
            return nil
        }
        return parts.joined(separator: "  ·  ")
    }
}

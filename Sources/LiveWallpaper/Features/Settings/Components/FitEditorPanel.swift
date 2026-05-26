import SwiftUI

extension SettingsView {
    var wallpaperFitEditorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(model.localizedString("フィット編集"), systemImage: "crop")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }

            if let path = resolvedFitEditorVideoPath(),
               !path.isEmpty
            {
                let screenID = resolvedFitScreenID()
                let zoomValue = fitEditorZoom(path: path, screenID: screenID)
                let offsetXValue = fitEditorOffsetX(path: path, screenID: screenID)
                let offsetYValue = fitEditorOffsetY(path: path, screenID: screenID)
                HStack(spacing: 10) {
                    Text(model.registeredVideoDisplayName(for: path))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !fitEditorScreens.isEmpty {
                        Picker(
                            "",
                            selection: Binding<String>(
                                get: { resolvedFitScreenID() },
                                set: { selectedFitScreenID = $0 }
                            )
                        ) {
                            ForEach(fitEditorScreens) { screen in
                                Text(screen.name).tag(screen.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                }

                wallpaperFitPreview(path: path, screenID: screenID)

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button(model.localizedString("保存して再適用")) {
                        applyFitEditorDraft(path: path, screenID: screenID)
                    }
                    .buttonStyle(.borderedProminent)
                    Button(model.localizedString("リセット")) {
                        resetFitEditorDraft(path: path, screenID: screenID)
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                HStack(spacing: 12) {
                    Text(model.localizedString("表示"))
                        .frame(width: 72, alignment: .leading)
                    Spacer(minLength: 0)
                    EqualSegmentedControl(
                        options: [
                            (model.localizedString("拡大"), VideoFitMode.fill),
                            (model.localizedString("全体"), VideoFitMode.fit)
                        ],
                        selection: fitModeBinding(path: path, screenID: screenID)
                    )
                    .frame(width: fitEditorSegmentedPickerWidth, height: 24)
                }

                HStack(spacing: 12) {
                    Text(model.localizedString("プレビュー"))
                        .lineLimit(1)
                        .frame(width: 72, alignment: .leading)
                    Spacer(minLength: 0)
                    EqualSegmentedControl(
                        options: [
                            (model.localizedString("動画"), FitPreviewMode.video),
                            (model.localizedString("静止画"), FitPreviewMode.still)
                        ],
                        selection: $fitPreviewMode
                    )
                    .frame(width: fitEditorSegmentedPickerWidth, height: 24)
                }

                HStack(spacing: 12) {
                    Text(model.localizedString("ズーム"))
                        .frame(width: 56, alignment: .leading)
                    Slider(value: zoomBinding(path: path, screenID: screenID), in: 1 ... 3)
                    Text(
                        String(
                            format: "%.2fx", zoomValue
                        )
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .trailing)
                }

                HStack(spacing: 12) {
                    Text(model.localizedString("X"))
                        .frame(width: 56, alignment: .leading)
                    Slider(value: offsetXBinding(path: path, screenID: screenID), in: -1 ... 1)
                    Text(
                        String(
                            format: "%.3f", offsetXValue
                        )
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .trailing)
                }

                HStack(spacing: 12) {
                    Text(model.localizedString("Y"))
                        .frame(width: 56, alignment: .leading)
                    Slider(value: offsetYBinding(path: path, screenID: screenID), in: -1 ... 1)
                    Text(
                        String(
                            format: "%.3f", offsetYValue
                        )
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .trailing)
                }

                Text(model.localizedString("矢印キーで位置を調整できます（Shift 併用で速く移動）。左クリックを押したままドラッグでも調整できます"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(model.localizedString("この画面ではプレビューのみ更新されます。『保存して再適用』で壁紙に反映されます"))
                    .font(.caption)
                    .foregroundColor(.secondary)
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
}

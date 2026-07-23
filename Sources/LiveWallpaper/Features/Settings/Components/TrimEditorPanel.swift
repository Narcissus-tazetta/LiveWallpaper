import SwiftUI

extension SettingsView {
    var wallpaperTrimEditorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(model.localizedString("トリム編集"), systemImage: "scissors")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }

            if let path = wallpaperEditor.resolvedVideoPath(), !path.isEmpty {
                trimEditorContent(path: path)
            } else {
                Text(model.localizedString("下の壁紙一覧から動画を選択すると、カットとループ開始位置を編集できます"))
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
    private func trimEditorContent(path: String) -> some View {
        let draft = wallpaperEditor.draft
        let isDirty = wallpaperEditor.isDraftDirty(path: path)
        let duration = draft.assetDuration

        Text(model.registeredVideoDisplayName(for: path))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)

        if duration <= 0 {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.72))
                TrimEditorPreviewPlayer(
                    videoPath: path,
                    loopRange: previewLoopRange(draft: draft),
                    isPlaying: wallpaperEditor.isPreviewPlaying,
                    currentTime: $wallpaperEditor.playheadTime
                )
                .id(path)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 8) {
                Button {
                    wallpaperEditor.isPreviewPlaying.toggle()
                } label: {
                    Image(systemName: wallpaperEditor.isPreviewPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.bordered)

                Text(trimEditorTimeLabel(draft.trimStart))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
                Text(trimEditorTimeLabel(wallpaperEditor.playheadTime))
                    .font(.caption.monospacedDigit())
                Spacer(minLength: 0)
                Text(trimEditorTimeLabel(draft.effectiveTrimEnd))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }

            TrimRangeScrubber(
                duration: duration,
                trimStart: draft.trimStart,
                trimEnd: draft.effectiveTrimEnd,
                loopStart: draft.loopStart,
                playhead: wallpaperEditor.playheadTime,
                onTrimStartChanged: { wallpaperEditor.setDraftTrimStart($0) },
                onTrimEndChanged: { wallpaperEditor.setDraftTrimEnd($0) },
                onLoopStartChanged: { wallpaperEditor.setDraftLoopStart($0) }
            )

            Toggle(
                model.localizedString("途中からループする"),
                isOn: Binding(
                    get: { draft.hasCustomLoopStart },
                    set: { wallpaperEditor.toggleCustomLoopStart($0) }
                )
            )
            .toggleStyle(.checkbox)
            .font(.system(size: 12))

            Text(
                model.localizedString(
                    "オレンジのハンドルでループの開始位置を指定できます。オフのときはカット開始位置からループします"
                )
            )
            .font(.caption)
            .foregroundColor(.secondary)

            trimEditorActions(path: path, isDirty: isDirty)
        }
    }

    private func previewLoopRange(draft: WallpaperEditDraft) -> ClosedRange<Double> {
        let end = max(draft.effectiveTrimEnd, draft.trimStart + wallpaperEditor.minimumSegmentDuration)
        let start = min(draft.loopStart ?? draft.trimStart, end - wallpaperEditor.minimumSegmentDuration)
        return max(start, 0) ... end
    }

    private func trimEditorTimeLabel(_ seconds: Double) -> String {
        let clamped = max(seconds, 0)
        let minutes = Int(clamped) / 60
        let secs = clamped.truncatingRemainder(dividingBy: 60)
        return String(format: "%d:%04.1f", minutes, secs)
    }

    private func trimEditorActions(path: String, isDirty: Bool) -> some View {
        HStack(spacing: 8) {
            if wallpaperEditor.showsSavedFeedback {
                Label(model.localizedString("反映しました"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
                    .transition(.opacity)
            }

            Spacer(minLength: 0)

            Button(model.localizedString("リセット")) {
                wallpaperEditor.resetDraft()
            }
            .buttonStyle(.bordered)
            .help(model.localizedString("カット・ループ範囲を初期値に戻します（保存するまで壁紙には反映されません）"))

            Button(model.localizedString("既定値に従う")) {
                wallpaperEditor.clearOverride(path: path)
            }
            .buttonStyle(.bordered)
            .disabled(!wallpaperEditor.hasOverride)
            .help(model.localizedString("この動画のカット・ループ設定を削除して、全体再生に戻します"))

            Button(model.localizedString("変更を破棄")) {
                wallpaperEditor.discardDraftChanges(path: path)
            }
            .buttonStyle(.bordered)
            .disabled(!isDirty)

            Button(model.localizedString("保存して再適用")) {
                wallpaperEditor.commit(path: path)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isDirty)
        }
        .animation(.easeInOut(duration: 0.15), value: wallpaperEditor.showsSavedFeedback)
    }
}

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
                    trimStart: draft.trimStart,
                    // 本番と同じ「実尺の内側へ収めた終端」を渡す。生の draft.trimEnd
                    // (未設定なら nil)のままだと AVPlayerLooper が区間を作れず、
                    // プレビューが再生されない。
                    trimEnd: draft.loopSafeTrimEnd,
                    loopStart: draft.loopStart,
                    isPlaying: wallpaperEditor.isPreviewPlaying,
                    seekRequest: wallpaperEditor.seekRequest,
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

                TrimTimeField(
                    value: draft.trimStart,
                    accessibilityLabel: model.localizedString("カット開始時刻"),
                    onCommit: { wallpaperEditor.setDraftTrimStart($0) }
                )
                Spacer(minLength: 0)
                Text(trimEditorTimeLabel(wallpaperEditor.playheadTime))
                    .font(.caption.monospacedDigit())
                Spacer(minLength: 0)
                TrimTimeField(
                    value: draft.effectiveTrimEnd,
                    accessibilityLabel: model.localizedString("カット終了時刻"),
                    onCommit: { wallpaperEditor.setDraftTrimEnd($0) }
                )
            }

            TrimRangeScrubber(
                videoPath: path,
                duration: duration,
                trimStart: draft.trimStart,
                trimEnd: draft.effectiveTrimEnd,
                loopStart: draft.loopStart,
                playhead: wallpaperEditor.playheadTime,
                startHandleAccessibilityLabel: model.localizedString("カット開始位置"),
                endHandleAccessibilityLabel: model.localizedString("カット終了位置"),
                loopStartHandleAccessibilityLabel: model.localizedString("ループ開始位置"),
                onTrimStartChanged: { wallpaperEditor.setDraftTrimStart($0) },
                onTrimEndChanged: { wallpaperEditor.setDraftTrimEnd($0) },
                onLoopStartChanged: { wallpaperEditor.setDraftLoopStart($0) },
                onScrub: { wallpaperEditor.seek(to: $0) }
            )

            HStack(spacing: 8) {
                Toggle(
                    model.localizedString("途中からループする"),
                    isOn: Binding(
                        get: { draft.hasCustomLoopStart },
                        set: { wallpaperEditor.toggleCustomLoopStart($0) }
                    )
                )
                .toggleStyle(.checkbox)
                .font(.system(size: 12))

                Spacer(minLength: 0)

                Text(
                    "\(model.localizedString("ループ長")) \(trimEditorTimeLabel(loopDuration(draft: draft)))"
                )
                .font(.caption)
                .foregroundColor(.secondary)

                Button {
                    wallpaperEditor.isPreviewPlaying = true
                    wallpaperEditor.seek(to: seamCheckSeekTime(draft: draft))
                } label: {
                    Label(
                        model.localizedString("継ぎ目を確認"),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(
                    model.localizedString(
                        "カット終了位置の少し手前へ再生位置を移動し、ループの継ぎ目を確認できます"
                    )
                )
            }

            if draft.hasCustomLoopStart {
                Text(
                    model.localizedString(
                        "オレンジのハンドルでループの開始位置を指定できます。初回だけカット開始位置から再生し、2周目以降はここから繰り返します"
                    )
                )
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            trimEditorActions(path: path, isDirty: isDirty)
        }
    }

    private func trimEditorTimeLabel(_ seconds: Double) -> String {
        let clamped = max(seconds, 0)
        let minutes = Int(clamped) / 60
        let secs = clamped.truncatingRemainder(dividingBy: 60)
        return String(format: "%d:%04.1f", minutes, secs)
    }

    /// 2周目以降に実際にループする区間(ループ開始位置 ... カット終了位置)の長さ。
    private func loopDuration(draft: WallpaperEditDraft) -> Double {
        max(draft.effectiveTrimEnd - draft.effectiveLoopStart, 0)
    }

    /// 「継ぎ目を確認」ボタンの飛び先。カット終了位置の少し手前(既定2秒)へ移動し、
    /// ループがシームレスに戻る瞬間を繰り返し眺められるようにする。ループ区間が
    /// 2秒より短い場合はループ開始位置より手前へ飛ばないようクランプする。
    private func seamCheckSeekTime(draft: WallpaperEditDraft) -> Double {
        let seamLeadIn = 2.0
        return max(draft.effectiveLoopStart, draft.effectiveTrimEnd - seamLeadIn)
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

/// トリム開始/終了時刻を "M:SS.s" 形式で直接編集させるフィールド。編集中は外部の
/// `value` 更新で表示を上書きしない(フォーカスを外れた時点でだけ確定・再フォーマット
/// する)ことで、入力途中の文字列がドラッグ由来の値更新で消される事故を避ける。
private struct TrimTimeField: View {
    let value: Double
    let accessibilityLabel: String
    let onCommit: (Double) -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.caption.monospacedDigit())
            .multilineTextAlignment(.center)
            .frame(width: 56)
            .foregroundColor(.secondary)
            .focused($isFocused)
            .accessibilityLabel(accessibilityLabel)
            .onAppear {
                text = Self.format(value)
            }
            .onChange(of: value) { newValue in
                if !isFocused {
                    text = Self.format(newValue)
                }
            }
            .onChange(of: isFocused) { focused in
                if !focused {
                    commit()
                }
            }
            .onSubmit {
                commit()
            }
    }

    private func commit() {
        guard let parsed = Self.parse(text) else {
            text = Self.format(value)
            return
        }
        onCommit(parsed)
    }

    private static func format(_ seconds: Double) -> String {
        let clamped = max(seconds, 0)
        let minutes = Int(clamped) / 60
        let secs = clamped.truncatingRemainder(dividingBy: 60)
        return String(format: "%d:%04.1f", minutes, secs)
    }

    private static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":")
            guard
                parts.count == 2,
                let minutes = Double(parts[0]),
                let seconds = Double(parts[1])
            else {
                return nil
            }
            return minutes * 60 + seconds
        }
        return Double(trimmed)
    }
}

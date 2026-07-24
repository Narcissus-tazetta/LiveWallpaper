import SwiftUI

extension SettingsView {
    var wallpaperTrimEditorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(model.localizedString("トリム編集"), systemImage: "scissors")
                    .font(.system(size: 13, weight: .semibold))

                if let path = wallpaperEditor.resolvedVideoPath(),
                   wallpaperEditor.isDraftDirty(path: path)
                {
                    Text(model.localizedString("未保存"))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.orange.opacity(0.22))
                        )
                        .foregroundColor(.orange)
                }

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
        .sheet(isPresented: $isTrimCopyPickerPresented) {
            trimCopyPickerSheet
        }
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

        if wallpaperEditor.didFailToLoadAsset {
            trimEditorLoadFailure()
        } else if duration <= 0 {
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
                    // 「ループ区間だけを再生」がONなら、イントロを挟まず2周目以降と
                    // 同じ区間だけを回す。継ぎ目を詰めるときに毎回頭から待たされない。
                    trimStart: wallpaperEditor.previewsLoopOnly
                        ? draft.effectiveLoopStart : draft.trimStart,
                    // 本番と同じ「実尺の内側へ収めた終端」を渡す。生の draft.trimEnd
                    // (未設定なら nil)のままだと AVPlayerLooper が区間を作れず、
                    // プレビューが再生されない。
                    trimEnd: draft.loopSafeTrimEnd,
                    loopStart: wallpaperEditor.previewsLoopOnly ? nil : draft.loopStart,
                    isPlaying: wallpaperEditor.isPreviewPlaying,
                    seekRequest: wallpaperEditor.seekRequest,
                    currentTime: $wallpaperEditor.playheadTime
                )
                .id(path)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            trimEditorTransportRow(draft: draft)

            if !wallpaperEditor.timelineWindow.isFullyZoomedOut(assetDuration: duration) {
                TrimTimelineOverview(
                    assetDuration: duration,
                    window: wallpaperEditor.timelineWindow,
                    trimStart: draft.trimStart,
                    trimEnd: draft.effectiveTrimEnd,
                    loopStart: draft.loopStart,
                    playhead: wallpaperEditor.playheadTime,
                    accessibilityLabel: model.localizedString("動画全体の中で表示している範囲"),
                    onCenter: { wallpaperEditor.centerTimeline(on: $0) }
                )
            }

            TrimRangeScrubber(
                videoPath: path,
                assetDuration: duration,
                window: wallpaperEditor.timelineWindow,
                trimStart: draft.trimStart,
                trimEnd: draft.effectiveTrimEnd,
                loopStart: draft.loopStart,
                playhead: wallpaperEditor.playheadTime,
                keyframeTimes: wallpaperEditor.keyframeTimes,
                showsKeyframeMarkers: wallpaperEditor.snapsToKeyframes,
                startHandleAccessibilityLabel: model.localizedString("カット開始位置"),
                endHandleAccessibilityLabel: model.localizedString("カット終了位置"),
                loopStartHandleAccessibilityLabel: model.localizedString("ループ開始位置"),
                onTrimStartChanged: { wallpaperEditor.setDraftTrimStart($0, snapping: $1) },
                onTrimEndChanged: { wallpaperEditor.setDraftTrimEnd($0, snapping: $1) },
                onLoopStartChanged: { wallpaperEditor.setDraftLoopStart($0, snapping: $1) },
                onScrub: { wallpaperEditor.seek(to: $0) },
                onInteractionEnded: { wallpaperEditor.endInteractiveEdit() },
                onWidthChanged: { wallpaperEditor.scrubberWidth = $0 },
                onZoom: { wallpaperEditor.zoomTimeline(by: $0, anchor: $1) }
            )

            trimEditorToolbarRow()

            trimEditorOptionsRow(draft: draft)

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

            trimEditorTransferRow(path: path)

            trimEditorActions(path: path, isDirty: isDirty)
        }
    }

    /// 尺が読めなかったとき。以前はここで無限にスピナーが回り続け、
    /// ファイルが壊れているのか読み込み中なのか判断できなかった。
    private func trimEditorLoadFailure() -> some View {
        VStack(spacing: 8) {
            Label(
                model.localizedString("この動画を読み込めませんでした"),
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundColor(.orange)

            Text(model.localizedString("ファイルが移動・削除されたか、対応していない形式の可能性があります"))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button(model.localizedString("再試行")) {
                wallpaperEditor.retryAssetLoad()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func trimEditorTransportRow(draft: WallpaperEditDraft) -> some View {
        HStack(spacing: 8) {
            Button {
                wallpaperEditor.togglePlayback()
            } label: {
                Image(systemName: wallpaperEditor.isPreviewPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
            .help(model.localizedString("再生/一時停止(Space)"))

            TrimTimeField(
                value: draft.trimStart,
                accessibilityLabel: model.localizedString("カット開始時刻"),
                onCommit: {
                    wallpaperEditor.setDraftTrimStart($0)
                    wallpaperEditor.endInteractiveEdit()
                    return wallpaperEditor.draft.trimStart
                }
            )
            Spacer(minLength: 0)
            Text(trimEditorTimeLabel(wallpaperEditor.playheadTime))
                .font(.caption.monospacedDigit())
            Spacer(minLength: 0)
            TrimTimeField(
                value: draft.effectiveTrimEnd,
                accessibilityLabel: model.localizedString("カット終了時刻"),
                onCommit: {
                    wallpaperEditor.setDraftTrimEnd($0)
                    wallpaperEditor.endInteractiveEdit()
                    return wallpaperEditor.draft.effectiveTrimEnd
                }
            )
        }
    }

    /// タイムラインのズームと取り消し。編集ペインは幅が限られるので、
    /// 頻度の低い操作はアイコンに寄せて1行に収める。
    private func trimEditorToolbarRow() -> some View {
        HStack(spacing: 6) {
            Button {
                wallpaperEditor.zoomTimeline(by: 1 / wallpaperEditor.zoomStepFactor)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!wallpaperEditor.canZoomOut)
            .help(model.localizedString("タイムラインを縮小"))

            Button {
                wallpaperEditor.zoomTimeline(by: wallpaperEditor.zoomStepFactor)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!wallpaperEditor.canZoomIn)
            .help(model.localizedString("タイムラインを拡大(トラックパッドのピンチでも操作できます)"))

            Button(model.localizedString("範囲へ")) {
                wallpaperEditor.zoomTimelineToSelection()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(model.localizedString("カット範囲が画面いっぱいになるまで拡大します"))

            Button(model.localizedString("全体")) {
                wallpaperEditor.zoomTimelineToFull()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!wallpaperEditor.canZoomOut)
            .help(model.localizedString("動画全体を表示します"))

            Spacer(minLength: 0)

            Button {
                wallpaperEditor.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!wallpaperEditor.canUndo)
            .help(model.localizedString("取り消す(⌘Z)"))

            Button {
                wallpaperEditor.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!wallpaperEditor.canRedo)
            .help(model.localizedString("やり直す(⇧⌘Z)"))
        }
    }

    private func trimEditorOptionsRow(draft: WallpaperEditDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Toggle(
                    model.localizedString("途中からループする"),
                    isOn: Binding(
                        get: { draft.hasCustomLoopStart },
                        set: { wallpaperEditor.toggleCustomLoopStart($0) }
                    )
                )
                .toggleStyle(.checkbox)
                .font(.system(size: 12))

                Toggle(
                    model.localizedString("ループ区間だけ再生"),
                    isOn: $wallpaperEditor.previewsLoopOnly
                )
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .help(
                    model.localizedString(
                        "イントロを挟まず、2周目以降と同じ区間だけを繰り返します。継ぎ目の確認用です"
                    )
                )

                Toggle(
                    model.localizedString("キーフレームに吸着"),
                    isOn: $wallpaperEditor.snapsToKeyframes
                )
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .help(
                    model.localizedString(
                        "ハンドルをドラッグしたとき、近くのキーフレームへ合わせます。継ぎ目が滑らかになり、書き出しも速くなります"
                    )
                )

                if wallpaperEditor.isLoadingKeyframes {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                // 再生位置からハンドルを置く操作。キーボードの I/O/L と同じ。
                Button(model.localizedString("開始にする")) {
                    wallpaperEditor.setTrimStartToPlayhead()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(model.localizedString("カット開始位置を今の再生位置にします(I)"))

                Button(model.localizedString("終了にする")) {
                    wallpaperEditor.setTrimEndToPlayhead()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(model.localizedString("カット終了位置を今の再生位置にします(O)"))

                Button(model.localizedString("ループ開始にする")) {
                    wallpaperEditor.setLoopStartToPlayhead()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(model.localizedString("ループ開始位置を今の再生位置にします(L)"))

                Spacer(minLength: 0)

                Text(
                    "\(model.localizedString("ループ長")) \(trimEditorTimeLabel(loopDuration(draft: draft)))"
                )
                .font(.caption)
                .foregroundColor(.secondary)

                // 警告は文言ごと並べると行が溢れるので、アイコンだけ出して
                // 理由はツールチップに逃がす。
                if loopDuration(draft: draft) < shortLoopWarningThreshold {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .help(model.localizedString("ループが短すぎると再生負荷が上がります"))
                }

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
        }
    }

    /// 他の壁紙へのコピーとファイル書き出し。
    private func trimEditorTransferRow(path: String) -> some View {
        HStack(spacing: 8) {
            if let progress = wallpaperEditor.exportProgress {
                ProgressView(value: progress)
                    .controlSize(.small)
                    .frame(width: 120)
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                Button(model.localizedString("中止")) {
                    wallpaperEditor.cancelExport()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if let message = wallpaperEditor.transferMessage {
                Label(
                    message,
                    systemImage: wallpaperEditor.transferMessageIsError
                        ? "exclamationmark.triangle" : "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundColor(wallpaperEditor.transferMessageIsError ? .orange : .green)
            }

            Spacer(minLength: 0)

            Button(model.localizedString("他の壁紙へコピー…")) {
                trimCopySelection = []
                trimCopySearchText = ""
                isTrimCopyPickerPresented = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.allRegisteredVideoPaths.count < 2)
            .help(model.localizedString("いまのカット・ループ設定を、選んだ壁紙にもそのまま適用します"))

            Menu {
                Button(model.localizedString("そのまま書き出す(高速・無劣化)")) {
                    wallpaperEditor.beginExport(preset: .passthrough)
                }
                Button(model.localizedString("再エンコードして書き出す(正確)")) {
                    wallpaperEditor.beginExport(preset: .reEncode)
                }
            } label: {
                Text(model.localizedString("書き出し…"))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(wallpaperEditor.isExporting || path.isEmpty)
            .help(model.localizedString("カット範囲だけを含む動画ファイルを作ります"))
        }
    }

    private func trimEditorTimeLabel(_ seconds: Double) -> String {
        let clamped = max(seconds.isFinite ? seconds : 0, 0)
        let minutes = Int(clamped) / 60
        let secs = clamped.truncatingRemainder(dividingBy: 60)
        return String(format: "%d:%04.1f", minutes, secs)
    }

    /// これより短いループは、シーク・デコードが頻繁に走って再生負荷が上がる。
    private var shortLoopWarningThreshold: Double {
        1.5
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
    /// 入力値を反映し、**クランプ後に実際に採用された値**を返す。戻り値を
    /// もらわないと、クランプ結果が偶然いまと同じだったときに `value` が
    /// 変化せず、入力した生文字列("999")がフィールドに残り続ける。
    let onCommit: (Double) -> Double

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
        text = Self.format(onCommit(parsed))
    }

    private static func format(_ seconds: Double) -> String {
        let clamped = max(seconds.isFinite ? seconds : 0, 0)
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

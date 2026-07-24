import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// 編集内容を「外へ出す」操作 — 他の壁紙へのコピーと、カット済みファイルの
/// 書き出し。どちらも複数の動画やディスクI/Oを跨ぐため、失敗しても編集中の
/// ドラフトには一切触らない(保存済みメタデータだけを書く)方針で統一している。
extension WallpaperEditorController {
    // MARK: - 他の壁紙へコピー

    /// いま編集中の内容(保存時と同じ正規化を通したもの)を他の動画へ複製する。
    ///
    /// カット範囲は秒の絶対値なので、コピー先が短ければそのままでは使えない。
    /// 尺を読んで `TrimEditCopyPlanner` に通し、収まらない動画は書き換えずに
    /// 数だけ報告する。黙って丸めると、再生できない壁紙を量産しかねない。
    func copyCurrentEdit(to paths: [String]) {
        let source = WallpaperEditMetadata(
            trimStart: draft.trimStart,
            trimEnd: draft.loopSafeTrimEnd ?? draft.trimEnd,
            loopStart: draft.loopSafeLoopStart(minimumSegment: minimumSegmentDuration)
        )
        let targets = paths.filter { $0 != draft.path }
        guard !targets.isEmpty else {
            return
        }

        Task { [weak self] in
            var applied = 0
            var skipped = 0
            for path in targets {
                let asset = AVURLAsset(url: URL(fileURLWithPath: path))
                let duration = await (try? asset.load(.duration).seconds) ?? 0
                guard let self else {
                    return
                }
                guard
                    let plan = TrimEditCopyPlanner.plan(
                        source: source,
                        targetDuration: duration,
                        minimumSegment: minimumSegmentDuration,
                        endGuard: WallpaperLoopBuilder.loopEndGuard
                    )
                else {
                    skipped += 1
                    continue
                }
                model.setWallpaperEdit(
                    trimStart: plan.trimStart,
                    trimEnd: plan.trimEnd,
                    loopStart: plan.loopStart,
                    path: path
                )
                applied += 1
            }
            guard let self else {
                return
            }
            showTransferMessage(
                copyResultMessage(applied: applied, skipped: skipped),
                isError: applied == 0
            )
        }
    }

    private func copyResultMessage(applied: Int, skipped: Int) -> String {
        let appliedText =
            "\(applied)\(model.localizedString("件にコピーしました"))"
        guard skipped > 0 else {
            return appliedText
        }
        return
            "\(appliedText)(\(skipped)\(model.localizedString("件は尺が足りずスキップしました"))）"
    }

    // MARK: - ファイルの書き出し

    var isExporting: Bool {
        exportProgress != nil
    }

    /// 保存先を尋ねてから、カット範囲だけのファイルを書き出す。
    func beginExport(preset: WallpaperTrimExporter.Preset) {
        guard !isExporting else {
            return
        }
        guard let path = resolvedVideoPath(), !path.isEmpty else {
            return
        }
        guard
            let timeRange = WallpaperTrimExporter.makeTimeRange(
                trimStart: draft.trimStart,
                trimEnd: draft.trimEnd,
                assetDuration: draft.assetDuration
            )
        else {
            showTransferMessage(
                model.localizedString("書き出す範囲がありません"),
                isError: true
            )
            return
        }

        let fileExtension = WallpaperTrimExporter.preferredFileExtension(
            sourcePath: path,
            preset: preset
        )
        let panel = NSSavePanel()
        panel.allowedContentTypes = [fileExtension == "mov" ? .quickTimeMovie : .mpeg4Movie]
        panel.nameFieldStringValue = WallpaperTrimExporter.suggestedFileName(
            sourcePath: path,
            fileExtension: fileExtension
        )
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }

        exportProgress = 0
        transferMessage = nil
        exportTask = Task { [weak self] in
            do {
                try await WallpaperTrimExporter.export(
                    sourcePath: path,
                    destination: destination,
                    timeRange: timeRange,
                    preset: preset,
                    progress: { [weak self] value in
                        // すでに終わっている(=nil に戻した)進捗は上書きしない。
                        guard let self, exportProgress != nil else {
                            return
                        }
                        exportProgress = min(max(value, 0), 1)
                    }
                )
                guard let self else {
                    return
                }
                exportProgress = nil
                exportTask = nil
                showTransferMessage(
                    model.localizedString("書き出しました"),
                    isError: false
                )
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                guard let self, !Task.isCancelled else {
                    return
                }
                exportProgress = nil
                exportTask = nil
                let message =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                showTransferMessage(model.localizedString(message), isError: true)
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        exportProgress = nil
    }

    func showTransferMessage(_ message: String, isError: Bool) {
        transferMessageTask?.cancel()
        transferMessage = message
        transferMessageIsError = isError
        transferMessageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !Task.isCancelled else {
                return
            }
            transferMessageTask = nil
            transferMessage = nil
        }
    }
}

import AppKit
import SwiftUI

/// フィット編集ドラフト(読み書き・編集・バインディング・オフセット正規化・保存)。
extension FitEditorController {
    // MARK: - ドラフトの読み書き

    func syncDraftWithCurrentSelection() {
        guard isActive else {
            return
        }
        guard let path = resolvedVideoPath(), !path.isEmpty else {
            clearDraft()
            return
        }
        loadDraft(path: path, screenID: resolvedScreenID())
    }

    func loadDraft(path: String, screenID: String) {
        let loaded = FitEditorDraft(
            path: path,
            screenID: screenID,
            fitMode: model.wallpaperFitMode(path: path, screenID: screenID),
            zoom: model.wallpaperZoom(path: path, screenID: screenID),
            offsetX: model.wallpaperOffsetX(path: path, screenID: screenID),
            offsetY: model.wallpaperOffsetY(path: path, screenID: screenID)
        )

        guard draft != loaded else {
            return
        }

        cancelDeferredWork()
        draft = loaded
    }

    func clearDraft() {
        guard draft.isActive else {
            return
        }
        cancelDeferredWork()
        draft = FitEditorDraft()
    }

    /// ドラフトの切り替え時に、旧ドラフト宛の遅延処理(正規化・リアルタイム反映)を破棄する。
    private func cancelDeferredWork() {
        normalizeThrottleTask?.cancel()
        normalizeThrottleTask = nil
        normalizeGeneration &+= 1
        liveApplyTask?.cancel()
        liveApplyTask = nil
    }

    func ensureDraft(path: String, screenID: String) {
        if draft.matches(path: path, screenID: screenID) {
            return
        }
        loadDraft(path: path, screenID: screenID)
    }

    func fitMode(path: String, screenID: String) -> VideoFitMode {
        guard draft.matches(path: path, screenID: screenID) else {
            return model.wallpaperFitMode(path: path, screenID: screenID)
        }
        return draft.fitMode
    }

    func zoom(path: String, screenID: String) -> Double {
        guard draft.matches(path: path, screenID: screenID) else {
            return model.wallpaperZoom(path: path, screenID: screenID)
        }
        return draft.zoom
    }

    func offsetX(path: String, screenID: String) -> Double {
        guard draft.matches(path: path, screenID: screenID) else {
            return model.wallpaperOffsetX(path: path, screenID: screenID)
        }
        return draft.offsetX
    }

    func offsetY(path: String, screenID: String) -> Double {
        guard draft.matches(path: path, screenID: screenID) else {
            return model.wallpaperOffsetY(path: path, screenID: screenID)
        }
        return draft.offsetY
    }

    func isDraftDirty(path: String, screenID: String) -> Bool {
        guard draft.matches(path: path, screenID: screenID) else {
            return false
        }
        return draft.fitMode != model.wallpaperFitMode(path: path, screenID: screenID)
            || draft.zoom != model.wallpaperZoom(path: path, screenID: screenID)
            || draft.offsetX != model.wallpaperOffsetX(path: path, screenID: screenID)
            || draft.offsetY != model.wallpaperOffsetY(path: path, screenID: screenID)
    }

    // MARK: - ドラフトの編集

    /// ドラフト変更後の共通処理。オフセット正規化と、有効時のリアルタイム反映を予約する。
    private func draftDidChange(path: String, screenID: String) {
        throttledNormalizeDraftOffsets(path: path, screenID: screenID)
        scheduleLiveApplyIfNeeded(path: path, screenID: screenID)
    }

    /// Applies `edit` to the draft and records the state before it as an undo step.
    /// Edits with the same `coalescingKey` between two mouse or key presses merge
    /// into one step; nil always makes a step of its own.
    private func editDraft(
        path: String,
        screenID: String,
        coalescingKey: String?,
        _ edit: () -> Void
    ) {
        ensureDraft(path: path, screenID: screenID)
        let before = draft
        edit()
        guard draft != before else {
            return
        }
        draftHistories[Self.historyKey(path: path, screenID: screenID), default: EditHistory()]
            .record(before, coalescingKey: coalescingKey)
        draftDidChange(path: path, screenID: screenID)
    }

    func setDraftFitMode(_ fitMode: VideoFitMode, path: String, screenID: String) {
        editDraft(path: path, screenID: screenID, coalescingKey: "fitMode") {
            draft.fitMode = fitMode
        }
    }

    /// anchor はプレビューキャンバス中心を原点とした y 下向きの座標。
    /// 指定するとその点直下のコンテンツを保ったままズームする(カーソル中心ズーム)。
    func setDraftZoom(
        _ zoom: Double,
        anchor: CGPoint? = nil,
        path: String,
        screenID: String
    ) {
        editDraft(path: path, screenID: screenID, coalescingKey: "zoom") {
            applyZoom(zoom, anchor: anchor, path: path, screenID: screenID)
        }
    }

    private func applyZoom(_ zoom: Double, anchor: CGPoint?, path: String, screenID: String) {
        let newZoom = WallpaperGeometry.clampZoom(zoom)
        if let anchor, newZoom != draft.zoom {
            let container = resolvedConstraintFrameSize(screenID: screenID)
            let before = model.wallpaperRenderGeometry(
                path: path,
                screenID: screenID,
                containerSize: container,
                fitMode: draft.fitMode,
                zoom: draft.zoom,
                offsetX: draft.offsetX,
                offsetY: draft.offsetY
            )
            let after = model.wallpaperRenderGeometry(
                path: path,
                screenID: screenID,
                containerSize: container,
                fitMode: draft.fitMode,
                zoom: newZoom,
                offsetX: draft.offsetX,
                offsetY: draft.offsetY
            )
            let contentX =
                (Double(anchor.x) - Double(before.translation.width))
                / max(Double(before.renderedSize.width), 1)
            let contentY =
                (Double(anchor.y) - Double(before.translation.height))
                / max(Double(before.renderedSize.height), 1)
            let translationX = Double(anchor.x) - contentX * Double(after.renderedSize.width)
            let translationY = Double(anchor.y) - contentY * Double(after.renderedSize.height)
            draft.offsetX = normalizedOffset(
                translation: translationX,
                maxPan: Double(after.maxPan.width)
            )
            draft.offsetY = normalizedOffset(
                translation: translationY,
                maxPan: Double(after.maxPan.height)
            )
        }
        draft.zoom = newZoom
    }

    func setDraftOffsetX(_ offsetX: Double, path: String, screenID: String) {
        editDraft(path: path, screenID: screenID, coalescingKey: "offset") {
            draft.offsetX = WallpaperGeometry.clampOffset(offsetX)
        }
    }

    func setDraftOffsetY(_ offsetY: Double, path: String, screenID: String) {
        editDraft(path: path, screenID: screenID, coalescingKey: "offset") {
            draft.offsetY = WallpaperGeometry.clampOffset(offsetY)
        }
    }

    func moveDraftOffset(dx: Double, dy: Double, path: String, screenID: String) {
        editDraft(path: path, screenID: screenID, coalescingKey: "offset") {
            draft.offsetX = WallpaperGeometry.clampOffset(draft.offsetX + dx)
            draft.offsetY = WallpaperGeometry.clampOffset(draft.offsetY + dy)
        }
    }

    /// A drag on the preview. Near the centre the picture snaps to it; the unsnapped
    /// position keeps following the pointer, so moving on leaves the centre again.
    /// `snapDistance` is how near counts, in offset units per axis.
    func dragDraftOffset(
        dx: Double,
        dy: Double,
        snapDistance: CGSize,
        snaps: Bool,
        path: String,
        screenID: String
    ) {
        ensureDraft(path: path, screenID: screenID)
        let start = dragRawOffset ?? CGPoint(x: draft.offsetX, y: draft.offsetY)
        let raw = CGPoint(
            x: WallpaperGeometry.clampOffset(start.x + dx),
            y: WallpaperGeometry.clampOffset(start.y + dy)
        )
        dragRawOffset = raw
        let axes = FitSnappedAxes(
            x: snaps && abs(raw.x) <= snapDistance.width,
            y: snaps && abs(raw.y) <= snapDistance.height
        )
        if snappedAxes != axes {
            snappedAxes = axes
        }
        editDraft(path: path, screenID: screenID, coalescingKey: "offset") {
            draft.offsetX = axes.x ? 0 : raw.x
            draft.offsetY = axes.y ? 0 : raw.y
        }
    }

    func endDraftDrag() {
        dragRawOffset = nil
        if snappedAxes != FitSnappedAxes() {
            snappedAxes = FitSnappedAxes()
        }
    }

    // MARK: - 取り消し・やり直し

    struct DraftHistoryKey: Hashable {
        var path: String
        var screenID: String
    }

    static func historyKey(path: String, screenID: String) -> DraftHistoryKey {
        DraftHistoryKey(path: path, screenID: screenID)
    }

    func canUndoDraft(path: String, screenID: String) -> Bool {
        draftHistories[Self.historyKey(path: path, screenID: screenID)]?.canUndo ?? false
    }

    func canRedoDraft(path: String, screenID: String) -> Bool {
        draftHistories[Self.historyKey(path: path, screenID: screenID)]?.canRedo ?? false
    }

    func undoDraft(path: String, screenID: String) {
        stepDraftHistory(path: path, screenID: screenID) { $0.undo(current: $1) }
    }

    func redoDraft(path: String, screenID: String) {
        stepDraftHistory(path: path, screenID: screenID) { $0.redo(current: $1) }
    }

    /// Ends the current drag or key repeat, so the next edit is a new undo step.
    func breakDraftHistoryCoalescing() {
        guard draft.isActive else {
            return
        }
        draftHistories[Self.historyKey(path: draft.path, screenID: draft.screenID)]?
            .breakCoalescing()
    }

    private func stepDraftHistory(
        path: String,
        screenID: String,
        _ step: (inout EditHistory<FitEditorDraft>, FitEditorDraft) -> FitEditorDraft?
    ) {
        ensureDraft(path: path, screenID: screenID)
        let key = Self.historyKey(path: path, screenID: screenID)
        guard var history = draftHistories[key], let restored = step(&history, draft) else {
            return
        }
        draftHistories[key] = history
        draft = restored
        draftDidChange(path: path, screenID: screenID)
    }

    // MARK: - ビュー用バインディング

    func fitModeBinding(path: String, screenID: String) -> Binding<VideoFitMode> {
        Binding(
            get: { self.fitMode(path: path, screenID: screenID) },
            set: { self.setDraftFitMode($0, path: path, screenID: screenID) }
        )
    }

    func zoomBinding(path: String, screenID: String) -> Binding<Double> {
        Binding(
            get: { self.zoom(path: path, screenID: screenID) },
            set: { self.setDraftZoom($0, path: path, screenID: screenID) }
        )
    }

    func offsetXBinding(path: String, screenID: String) -> Binding<Double> {
        Binding(
            get: { self.offsetX(path: path, screenID: screenID) },
            set: { self.setDraftOffsetX($0, path: path, screenID: screenID) }
        )
    }

    func offsetYBinding(path: String, screenID: String) -> Binding<Double> {
        Binding(
            get: { self.offsetY(path: path, screenID: screenID) },
            set: { self.setDraftOffsetY($0, path: path, screenID: screenID) }
        )
    }

    // MARK: - オフセットの正規化

    /// wallpaperRenderGeometry の再計算コストを避けるため、正規化は最大60Hzに間引く。
    /// 直近の呼び出しから間隔が空いていない場合は末尾に1回分だけ予約し、取りこぼしを防ぐ。
    private func throttledNormalizeDraftOffsets(path: String, screenID: String) {
        let minInterval: TimeInterval = 1.0 / 60.0
        let now = Date()
        let expectedGeneration = normalizeGeneration
        if now.timeIntervalSince(lastNormalizeAt) >= minInterval {
            normalizeThrottleTask?.cancel()
            normalizeThrottleTask = nil
            lastNormalizeAt = now
            normalizeDraftOffsets(path: path, screenID: screenID)
            return
        }
        guard normalizeThrottleTask == nil else {
            return
        }
        normalizeThrottleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minInterval * 1_000_000_000))
            guard let self, !Task.isCancelled else {
                return
            }
            normalizeThrottleTask = nil
            guard normalizeGeneration == expectedGeneration else {
                return
            }
            guard draft.matches(path: path, screenID: screenID) else {
                return
            }
            lastNormalizeAt = Date()
            normalizeDraftOffsets(path: path, screenID: screenID)
        }
    }

    func updatePreviewFrameSize(_ frameSize: CGSize, path: String, screenID: String) {
        guard previewFrameSize != frameSize else {
            return
        }
        previewFrameSize = frameSize
        guard draft.matches(path: path, screenID: screenID) else {
            return
        }
        normalizeDraftOffsets(path: path, screenID: screenID)
    }

    func normalizeDraftOffsets(path: String, screenID: String) {
        ensureDraft(path: path, screenID: screenID)

        let constraintFrame = resolvedConstraintFrameSize(screenID: screenID)
        let geometry = model.wallpaperRenderGeometry(
            path: path,
            screenID: screenID,
            containerSize: constraintFrame,
            fitMode: draft.fitMode,
            zoom: draft.zoom,
            offsetX: draft.offsetX,
            offsetY: draft.offsetY
        )

        draft.offsetX = normalizedOffset(
            translation: Double(geometry.translation.width),
            maxPan: Double(geometry.maxPan.width)
        )
        draft.offsetY = normalizedOffset(
            translation: Double(geometry.translation.height),
            maxPan: Double(geometry.maxPan.height)
        )
    }

    func resolvedConstraintFrameSize(screenID: String) -> CGSize {
        if previewFrameSize.width > 1, previewFrameSize.height > 1 {
            return previewFrameSize
        }

        let aspect = max(screenAspect(for: screenID), 0.2)
        let width: CGFloat = 420
        let height = width / aspect
        return CGSize(width: width, height: height)
    }

    private func normalizedOffset(translation: Double, maxPan: Double) -> Double {
        guard maxPan > 0.5 else {
            return 0
        }
        let clampedTranslation = min(max(translation, -maxPan), maxPan)
        return WallpaperGeometry.clampOffset(clampedTranslation / maxPan)
    }

    // MARK: - 保存・破棄

    func applyDraft(path: String, screenID: String, showFeedback: Bool = true) {
        ensureDraft(path: path, screenID: screenID)
        normalizeThrottleTask?.cancel()
        normalizeThrottleTask = nil
        lastNormalizeAt = Date()
        normalizeDraftOffsets(path: path, screenID: screenID)
        model.setWallpaperPresentation(
            fitMode: draft.fitMode,
            zoom: draft.zoom,
            offsetX: draft.offsetX,
            offsetY: draft.offsetY,
            path: path,
            screenID: screenID
        )
        loadDraft(path: path, screenID: screenID)
        if showFeedback {
            showSavedFeedback()
        }
    }

    func resetDraft(path: String, screenID: String) {
        editDraft(path: path, screenID: screenID, coalescingKey: nil) {
            draft.fitMode = model.fitMode
            draft.zoom = 1.0
            draft.offsetX = 0.0
            draft.offsetY = 0.0
        }
    }

    /// 未保存の編集を破棄して、保存済みの値へ戻す。
    func discardDraftChanges(path: String, screenID: String) {
        editDraft(path: path, screenID: screenID, coalescingKey: nil) {
            loadDraft(path: path, screenID: screenID)
        }
    }

    /// 個別設定を削除して既定値へ戻し、ドラフトも同期する。
    func clearOverride(path: String, screenID: String) {
        model.clearWallpaperPresentation(path: path, screenID: screenID)
        loadDraft(path: path, screenID: screenID)
        showSavedFeedback()
    }

    /// 現在のドラフトを保存したうえで、すべての画面へ同じ設定をコピーする。
    func applyDraftToAllScreens(path: String, screenID: String) {
        applyDraft(path: path, screenID: screenID, showFeedback: false)
        model.applyWallpaperPresentationToAllScreens(path: path, fromScreenID: screenID)
        showSavedFeedback()
    }

    func setLiveApplyEnabled(_ enabled: Bool, path: String, screenID: String) {
        liveApplyEnabled = enabled
        guard enabled else {
            liveApplyTask?.cancel()
            liveApplyTask = nil
            return
        }
        if isDraftDirty(path: path, screenID: screenID) {
            applyDraft(path: path, screenID: screenID, showFeedback: false)
        }
    }

    /// リアルタイム反映。連続操作(ドラッグ・スライダー)中の書き込み連打を避けるため 250ms デバウンスする。
    private func scheduleLiveApplyIfNeeded(path: String, screenID: String) {
        guard liveApplyEnabled else {
            return
        }
        liveApplyTask?.cancel()
        liveApplyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else {
                return
            }
            liveApplyTask = nil
            guard liveApplyEnabled else {
                return
            }
            guard draft.matches(path: path, screenID: screenID) else {
                return
            }
            applyDraft(path: path, screenID: screenID, showFeedback: false)
        }
    }

    func showSavedFeedback() {
        savedFeedbackTask?.cancel()
        showsSavedFeedback = true
        savedFeedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard let self, !Task.isCancelled else {
                return
            }
            savedFeedbackTask = nil
            showsSavedFeedback = false
        }
    }
}

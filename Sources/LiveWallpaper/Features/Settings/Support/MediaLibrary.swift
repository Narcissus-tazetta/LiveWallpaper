import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    func setThumbnailVisibility(path: String, isVisible: Bool) {
        thumbnailCache.setVisible(path: path, isVisible: isVisible)
    }

    func requestWallpaperThumbnail(path: String) {
        thumbnailCache.request(path: path)
    }

    func processThumbnailQueue() {
        thumbnailCache.processQueue()
    }

    func pruneMissingWallpaperThumbnails() {
        let valid = Set(model.allRegisteredVideoPaths)
        thumbnailCache.prune(validPaths: valid)
        Self.fitPreviewPathExistsCache = Self.fitPreviewPathExistsCache.filter { valid.contains($0.key) }
        fitPreviewStillImages = fitPreviewStillImages.filter { valid.contains($0.key) }
        fitPreviewStillImageOrder = fitPreviewStillImageOrder.filter { valid.contains($0) }
        fitPreviewStillImageInFlight = fitPreviewStillImageInFlight.filter { valid.contains($0) }
        for (path, task) in fitPreviewStillImageTasks where !valid.contains(path) {
            task.cancel()
            fitPreviewStillImageTasks.removeValue(forKey: path)
        }
        fitPreviewStillImageGeneration = fitPreviewStillImageGeneration.filter { valid.contains($0.key) }
        if let selected = fitEditorSelectedVideoPath, !valid.contains(selected) {
            fitEditorSelectedVideoPath = nil
        }
        if let editingPath = editingWallpaperPath, !valid.contains(editingPath) {
            cancelWallpaperNameEdit()
        }
    }

    private var fitPreviewStillImageLimit: Int { 10 }

    func trimFitPreviewStillImagesIfNeeded() {
        guard fitPreviewStillImageOrder.count > fitPreviewStillImageLimit else {
            return
        }
        let overflow = fitPreviewStillImageOrder.count - fitPreviewStillImageLimit
        for path in fitPreviewStillImageOrder.prefix(overflow) {
            fitPreviewStillImages.removeValue(forKey: path)
        }
        fitPreviewStillImageOrder.removeFirst(overflow)
    }

    func cancelFitPreviewStillGeneration(exceptPath: String?) {
        for (path, task) in fitPreviewStillImageTasks where path != exceptPath {
            task.cancel()
            fitPreviewStillImageTasks.removeValue(forKey: path)
            fitPreviewStillImageInFlight.remove(path)
            fitPreviewStillImageGeneration.removeValue(forKey: path)
        }
    }

    func resolvedFitEditorVideoPath() -> String? {
        let allPaths = model.allRegisteredVideoPaths
        if let selected = fitEditorSelectedVideoPath,
           allPaths.contains(selected)
        {
            return selected
        }
        if let current = model.currentVideoPath,
           allPaths.contains(current)
        {
            return current
        }
        return allPaths.first
    }

    func syncFitEditorSelectionWithCurrentVideoIfNeeded() {
        fitEditorSelectedVideoPath = resolvedFitEditorVideoPath()
    }

    func selectFitEditorVideo(path: String) {
        guard model.allRegisteredVideoPaths.contains(path) else {
            return
        }
        cancelFitPreviewStillGeneration(exceptPath: path)
        invalidateFitPreviewPathExistsCache(path: path)
        fitEditorSelectedVideoPath = path
        isFitEditorInteractionEnabled = false
        syncFitEditorDraftWithCurrentSelection()
        prepareFitPreviewStillImageIfNeeded()
    }

    func prepareFitPreviewStillImageIfNeeded() {
        guard selectedTab == .wallpaperFit else {
            return
        }
        guard fitPreviewMode == .still else {
            return
        }
        guard let path = resolvedFitEditorVideoPath(), !path.isEmpty else {
            return
        }
        requestFitPreviewStillImage(path: path)
    }

    func requestFitPreviewStillImage(path: String) {
        guard selectedTab == .wallpaperFit else {
            return
        }
        guard fitPreviewMode == .still else {
            return
        }
        guard path == resolvedFitEditorVideoPath() else {
            return
        }
        guard fitPreviewStillImages[path] == nil else {
            return
        }
        guard !fitPreviewStillImageInFlight.contains(path) else {
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return
        }

        fitPreviewStillImageInFlight.insert(path)

        let generation = UUID()
        fitPreviewStillImageGeneration[path] = generation

        let task = Task.detached(priority: .userInitiated) {
            let image = await FitPreviewService.generateStillImage(path: path)
            await MainActor.run {
                // A newer request for the same path may have superseded this one
                // (e.g. rapid A -> B -> A selection); only this generation's
                // completion may mutate the shared in-flight/task bookkeeping.
                guard fitPreviewStillImageGeneration[path] == generation else {
                    return
                }
                if !Task.isCancelled, let image {
                    fitPreviewStillImages[path] = image
                    fitPreviewStillImageOrder.removeAll { $0 == path }
                    fitPreviewStillImageOrder.append(path)
                    trimFitPreviewStillImagesIfNeeded()
                }
                fitPreviewStillImageInFlight.remove(path)
                fitPreviewStillImageTasks.removeValue(forKey: path)
                fitPreviewStillImageGeneration.removeValue(forKey: path)
            }
        }
        fitPreviewStillImageTasks[path] = task
    }

    func addToNewPlaylist(path: String) {
        guard let playlistID = model.createPlaylist() else {
            return
        }
        _ = model.addRegisteredVideo(path: path, to: playlistID)
        model.selectPlaylist(playlistID)
    }

    func handleDroppedVideoProviders(_ providers: [NSItemProvider]) -> Bool {
        guard
            let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            })
        else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var resolvedURL: URL?
            if let data = item as? Data {
                resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
            } else if let url = item as? URL {
                resolvedURL = url
            } else if let text = item as? String,
                      let url = URL(string: text)
            {
                resolvedURL = url
            }

            guard let url = resolvedURL else {
                return
            }

            DispatchQueue.main.async {
                prepareDroppedVideo(url)
            }
        }

        return true
    }

    /// ドロップされた動画をそのままライブラリへ登録して再生する。
    /// プレイリスト選択中はそのプレイリストにも追加される(setVideoの挙動に従う)。
    func prepareDroppedVideo(_ url: URL) {
        let fileURL = url.isFileURL ? url : URL(fileURLWithPath: url.path)
        guard fileURL.isFileURL else {
            return
        }
        let ext = fileURL.pathExtension
        guard let type = UTType(filenameExtension: ext), type.conforms(to: .movie) else {
            return
        }
        Task { @MainActor in
            await model.setVideo(path: fileURL.path)
            selectedTab = .wallpaper
        }
    }

    func resetLibrarySearchState() {
        librarySearchText = ""
        isLibrarySearchFocused = false
    }

    /// 動画名・プレイリスト名・Web壁紙名、いずれかの編集を開始する前に他の編集を閉じる。
    /// 複数の名前編集フィールドが同時に開いたままになるのを防ぐ。
    func cancelAllNameEdits() {
        cancelPlaylistNameEdit()
        cancelWallpaperNameEdit()
        cancelWebWallpaperNameEdit()
    }

    func startWallpaperNameEdit(path: String) {
        cancelAllNameEdits()
        editingWallpaperPath = path
        editingWallpaperNameInput = model.registeredVideoDisplayName(for: path)
        focusedWallpaperPath = path
    }

    func startPlaylistNameEdit(playlistID: UUID) {
        cancelAllNameEdits()
        editingPlaylistID = playlistID
        editingPlaylistNameInput = model.playlistName(for: playlistID)
        focusedPlaylistID = playlistID
    }

    func commitPlaylistNameEdit(playlistID: UUID) {
        model.setPlaylistName(editingPlaylistNameInput, for: playlistID)
        cancelPlaylistNameEdit()
    }

    func cancelPlaylistNameEdit() {
        editingPlaylistID = nil
        editingPlaylistNameInput = ""
        focusedPlaylistID = nil
    }

    func commitWallpaperNameEdit(path: String) {
        model.setRegisteredVideoDisplayName(editingWallpaperNameInput, for: path)
        cancelWallpaperNameEdit()
    }

    func cancelWallpaperNameEdit() {
        editingWallpaperPath = nil
        editingWallpaperNameInput = ""
        focusedWallpaperPath = nil
    }

    func syncFitEditorDraftWithCurrentSelection() {
        guard selectedTab == .wallpaperFit else {
            return
        }
        guard let path = resolvedFitEditorVideoPath(), !path.isEmpty else {
            clearFitEditorDraft()
            return
        }
        loadFitEditorDraft(path: path, screenID: resolvedFitScreenID())
    }

    func loadFitEditorDraft(path: String, screenID: String) {
        let draft = FitEditorDraft(
            path: path,
            screenID: screenID,
            fitMode: model.wallpaperFitMode(path: path, screenID: screenID),
            zoom: model.wallpaperZoom(path: path, screenID: screenID),
            offsetX: model.wallpaperOffsetX(path: path, screenID: screenID),
            offsetY: model.wallpaperOffsetY(path: path, screenID: screenID)
        )

        guard fitEditorDraft != draft else {
            return
        }

        cancelFitEditorDeferredWork()
        fitEditorDraft = draft
    }

    func clearFitEditorDraft() {
        guard fitEditorDraft.isActive else {
            return
        }
        cancelFitEditorDeferredWork()
        fitEditorDraft = FitEditorDraft()
    }

    /// ドラフトの切り替え時に、旧ドラフト宛の遅延処理(正規化・リアルタイム反映)を破棄する。
    private func cancelFitEditorDeferredWork() {
        fitEditorNormalizeThrottleWorkItem?.cancel()
        fitEditorNormalizeThrottleWorkItem = nil
        fitEditorNormalizeGeneration &+= 1
        fitEditorLiveApplyWorkItem?.cancel()
        fitEditorLiveApplyWorkItem = nil
    }

    func ensureFitEditorDraft(path: String, screenID: String) {
        if fitEditorDraft.matches(path: path, screenID: screenID) {
            return
        }
        loadFitEditorDraft(path: path, screenID: screenID)
    }

    func fitEditorFitMode(path: String, screenID: String) -> VideoFitMode {
        guard fitEditorDraft.matches(path: path, screenID: screenID) else {
            return model.wallpaperFitMode(path: path, screenID: screenID)
        }
        return fitEditorDraft.fitMode
    }

    func fitEditorZoom(path: String, screenID: String) -> Double {
        guard fitEditorDraft.matches(path: path, screenID: screenID) else {
            return model.wallpaperZoom(path: path, screenID: screenID)
        }
        return fitEditorDraft.zoom
    }

    func fitEditorOffsetX(path: String, screenID: String) -> Double {
        guard fitEditorDraft.matches(path: path, screenID: screenID) else {
            return model.wallpaperOffsetX(path: path, screenID: screenID)
        }
        return fitEditorDraft.offsetX
    }

    func fitEditorOffsetY(path: String, screenID: String) -> Double {
        guard fitEditorDraft.matches(path: path, screenID: screenID) else {
            return model.wallpaperOffsetY(path: path, screenID: screenID)
        }
        return fitEditorDraft.offsetY
    }

    func isFitEditorDraftDirty(path: String, screenID: String) -> Bool {
        guard fitEditorDraft.matches(path: path, screenID: screenID) else {
            return false
        }
        return fitEditorDraft.fitMode != model.wallpaperFitMode(path: path, screenID: screenID)
            || fitEditorDraft.zoom != model.wallpaperZoom(path: path, screenID: screenID)
            || fitEditorDraft.offsetX != model.wallpaperOffsetX(path: path, screenID: screenID)
            || fitEditorDraft.offsetY != model.wallpaperOffsetY(path: path, screenID: screenID)
    }

    /// ドラフト変更後の共通処理。オフセット正規化と、有効時のリアルタイム反映を予約する。
    private func fitEditorDraftDidChange(path: String, screenID: String) {
        throttledNormalizeFitEditorDraftOffsets(path: path, screenID: screenID)
        scheduleFitEditorLiveApplyIfNeeded(path: path, screenID: screenID)
    }

    func setFitEditorDraftFitMode(_ fitMode: VideoFitMode, path: String, screenID: String) {
        ensureFitEditorDraft(path: path, screenID: screenID)
        fitEditorDraft.fitMode = fitMode
        fitEditorDraftDidChange(path: path, screenID: screenID)
    }

    /// anchor はプレビューキャンバス中心を原点とした y 下向きの座標。
    /// 指定するとその点直下のコンテンツを保ったままズームする(カーソル中心ズーム)。
    func setFitEditorDraftZoom(
        _ zoom: Double,
        anchor: CGPoint? = nil,
        path: String,
        screenID: String
    ) {
        ensureFitEditorDraft(path: path, screenID: screenID)
        let newZoom = WallpaperGeometry.clampZoom(zoom)
        if let anchor, newZoom != fitEditorDraft.zoom {
            let container = resolvedFitEditorConstraintFrameSize(screenID: screenID)
            let before = model.wallpaperRenderGeometry(
                path: path,
                screenID: screenID,
                containerSize: container,
                fitMode: fitEditorDraft.fitMode,
                zoom: fitEditorDraft.zoom,
                offsetX: fitEditorDraft.offsetX,
                offsetY: fitEditorDraft.offsetY
            )
            let after = model.wallpaperRenderGeometry(
                path: path,
                screenID: screenID,
                containerSize: container,
                fitMode: fitEditorDraft.fitMode,
                zoom: newZoom,
                offsetX: fitEditorDraft.offsetX,
                offsetY: fitEditorDraft.offsetY
            )
            let contentX = (Double(anchor.x) - Double(before.translation.width))
                / max(Double(before.renderedSize.width), 1)
            let contentY = (Double(anchor.y) - Double(before.translation.height))
                / max(Double(before.renderedSize.height), 1)
            let translationX = Double(anchor.x) - contentX * Double(after.renderedSize.width)
            let translationY = Double(anchor.y) - contentY * Double(after.renderedSize.height)
            fitEditorDraft.offsetX = normalizedOffset(
                translation: translationX,
                maxPan: Double(after.maxPan.width)
            )
            fitEditorDraft.offsetY = normalizedOffset(
                translation: translationY,
                maxPan: Double(after.maxPan.height)
            )
        }
        fitEditorDraft.zoom = newZoom
        fitEditorDraftDidChange(path: path, screenID: screenID)
    }

    func setFitEditorDraftOffsetX(_ offsetX: Double, path: String, screenID: String) {
        ensureFitEditorDraft(path: path, screenID: screenID)
        fitEditorDraft.offsetX = WallpaperGeometry.clampOffset(offsetX)
        fitEditorDraftDidChange(path: path, screenID: screenID)
    }

    func setFitEditorDraftOffsetY(_ offsetY: Double, path: String, screenID: String) {
        ensureFitEditorDraft(path: path, screenID: screenID)
        fitEditorDraft.offsetY = WallpaperGeometry.clampOffset(offsetY)
        fitEditorDraftDidChange(path: path, screenID: screenID)
    }

    func moveFitEditorDraftOffset(dx: Double, dy: Double, path: String, screenID: String) {
        ensureFitEditorDraft(path: path, screenID: screenID)
        fitEditorDraft.offsetX = WallpaperGeometry.clampOffset(fitEditorDraft.offsetX + dx)
        fitEditorDraft.offsetY = WallpaperGeometry.clampOffset(fitEditorDraft.offsetY + dy)
        fitEditorDraftDidChange(path: path, screenID: screenID)
    }

    /// wallpaperRenderGeometry の再計算コストを避けるため、正規化は最大60Hzに間引く。
    /// 直近の呼び出しから間隔が空いていない場合は末尾に1回分だけ予約し、取りこぼしを防ぐ。
    func throttledNormalizeFitEditorDraftOffsets(path: String, screenID: String) {
        let minInterval: TimeInterval = 1.0 / 60.0
        let now = Date()
        let expectedGeneration = fitEditorNormalizeGeneration
        if now.timeIntervalSince(fitEditorLastNormalizeAt) >= minInterval {
            fitEditorNormalizeThrottleWorkItem?.cancel()
            fitEditorNormalizeThrottleWorkItem = nil
            fitEditorLastNormalizeAt = now
            normalizeFitEditorDraftOffsets(path: path, screenID: screenID)
            return
        }
        guard fitEditorNormalizeThrottleWorkItem == nil else {
            return
        }
        let workItem = DispatchWorkItem { [self] in
            fitEditorNormalizeThrottleWorkItem = nil
            guard fitEditorNormalizeGeneration == expectedGeneration else {
                return
            }
            guard fitEditorDraft.matches(path: path, screenID: screenID) else {
                return
            }
            fitEditorLastNormalizeAt = Date()
            normalizeFitEditorDraftOffsets(path: path, screenID: screenID)
        }
        fitEditorNormalizeThrottleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + minInterval, execute: workItem)
    }

    func updateFitEditorPreviewFrameSize(_ frameSize: CGSize, path: String, screenID: String) {
        guard fitEditorPreviewFrameSize != frameSize else {
            return
        }
        fitEditorPreviewFrameSize = frameSize
        guard fitEditorDraft.matches(path: path, screenID: screenID) else {
            return
        }
        normalizeFitEditorDraftOffsets(path: path, screenID: screenID)
    }

    func normalizeFitEditorDraftOffsets(path: String, screenID: String) {
        ensureFitEditorDraft(path: path, screenID: screenID)

        let constraintFrame = resolvedFitEditorConstraintFrameSize(screenID: screenID)
        let geometry = model.wallpaperRenderGeometry(
            path: path,
            screenID: screenID,
            containerSize: constraintFrame,
            fitMode: fitEditorDraft.fitMode,
            zoom: fitEditorDraft.zoom,
            offsetX: fitEditorDraft.offsetX,
            offsetY: fitEditorDraft.offsetY
        )

        fitEditorDraft.offsetX = normalizedOffset(
            translation: Double(geometry.translation.width),
            maxPan: Double(geometry.maxPan.width)
        )
        fitEditorDraft.offsetY = normalizedOffset(
            translation: Double(geometry.translation.height),
            maxPan: Double(geometry.maxPan.height)
        )
    }

    func resolvedFitEditorConstraintFrameSize(screenID: String) -> CGSize {
        if fitEditorPreviewFrameSize.width > 1, fitEditorPreviewFrameSize.height > 1 {
            return fitEditorPreviewFrameSize
        }

        let aspect = max(screenAspect(for: screenID), 0.2)
        let width: CGFloat = 420
        let height = width / aspect
        return CGSize(width: width, height: height)
    }

    func normalizedOffset(translation: Double, maxPan: Double) -> Double {
        guard maxPan > 0.5 else {
            return 0
        }
        let clampedTranslation = min(max(translation, -maxPan), maxPan)
        return WallpaperGeometry.clampOffset(clampedTranslation / maxPan)
    }

    func applyFitEditorDraft(path: String, screenID: String, showFeedback: Bool = true) {
        ensureFitEditorDraft(path: path, screenID: screenID)
        fitEditorNormalizeThrottleWorkItem?.cancel()
        fitEditorNormalizeThrottleWorkItem = nil
        fitEditorLastNormalizeAt = Date()
        normalizeFitEditorDraftOffsets(path: path, screenID: screenID)
        model.setWallpaperPresentation(
            fitMode: fitEditorDraft.fitMode,
            zoom: fitEditorDraft.zoom,
            offsetX: fitEditorDraft.offsetX,
            offsetY: fitEditorDraft.offsetY,
            path: path,
            screenID: screenID
        )
        loadFitEditorDraft(path: path, screenID: screenID)
        if showFeedback {
            showFitEditorSavedFeedback()
        }
    }

    func resetFitEditorDraft(path: String, screenID: String) {
        ensureFitEditorDraft(path: path, screenID: screenID)
        fitEditorDraft.fitMode = model.fitMode
        fitEditorDraft.zoom = 1.0
        fitEditorDraft.offsetX = 0.0
        fitEditorDraft.offsetY = 0.0
        fitEditorDraftDidChange(path: path, screenID: screenID)
    }

    /// 未保存の編集を破棄して、保存済みの値へ戻す。
    func discardFitEditorDraftChanges(path: String, screenID: String) {
        loadFitEditorDraft(path: path, screenID: screenID)
    }

    /// 個別設定を削除して既定値へ戻し、ドラフトも同期する。
    func clearFitEditorOverride(path: String, screenID: String) {
        model.clearWallpaperPresentation(path: path, screenID: screenID)
        loadFitEditorDraft(path: path, screenID: screenID)
        showFitEditorSavedFeedback()
    }

    /// 現在のドラフトを保存したうえで、すべての画面へ同じ設定をコピーする。
    func applyFitEditorDraftToAllScreens(path: String, screenID: String) {
        applyFitEditorDraft(path: path, screenID: screenID, showFeedback: false)
        model.applyWallpaperPresentationToAllScreens(path: path, fromScreenID: screenID)
        showFitEditorSavedFeedback()
    }

    func setFitEditorLiveApplyEnabled(_ enabled: Bool, path: String, screenID: String) {
        fitEditorLiveApplyEnabled = enabled
        guard enabled else {
            fitEditorLiveApplyWorkItem?.cancel()
            fitEditorLiveApplyWorkItem = nil
            return
        }
        if isFitEditorDraftDirty(path: path, screenID: screenID) {
            applyFitEditorDraft(path: path, screenID: screenID, showFeedback: false)
        }
    }

    /// リアルタイム反映。連続操作(ドラッグ・スライダー)中の書き込み連打を避けるため 250ms デバウンスする。
    func scheduleFitEditorLiveApplyIfNeeded(path: String, screenID: String) {
        guard fitEditorLiveApplyEnabled else {
            return
        }
        fitEditorLiveApplyWorkItem?.cancel()
        let workItem = DispatchWorkItem { [self] in
            fitEditorLiveApplyWorkItem = nil
            guard fitEditorLiveApplyEnabled else {
                return
            }
            guard fitEditorDraft.matches(path: path, screenID: screenID) else {
                return
            }
            applyFitEditorDraft(path: path, screenID: screenID, showFeedback: false)
        }
        fitEditorLiveApplyWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    func showFitEditorSavedFeedback() {
        fitEditorSavedFeedbackWorkItem?.cancel()
        fitEditorShowsSavedFeedback = true
        let workItem = DispatchWorkItem { [self] in
            fitEditorSavedFeedbackWorkItem = nil
            fitEditorShowsSavedFeedback = false
        }
        fitEditorSavedFeedbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: workItem)
    }
}

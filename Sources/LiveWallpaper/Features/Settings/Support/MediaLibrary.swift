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

    func prepareDroppedVideo(_ url: URL) {
        let fileURL = url.isFileURL ? url : URL(fileURLWithPath: url.path)
        guard fileURL.isFileURL else {
            return
        }
        let ext = fileURL.pathExtension
        guard let type = UTType(filenameExtension: ext), type.conforms(to: .movie) else {
            return
        }
        pendingDroppedVideoURL = fileURL
        isDropPlaylistDialogPresented = true
    }

    func applyDroppedVideo(to playlistID: UUID?) async {
        guard let droppedURL = pendingDroppedVideoURL else {
            return
        }

        let targetPlaylistID: UUID
        if let playlistID {
            targetPlaylistID = playlistID
        } else {
            guard let created = model.createPlaylist() else {
                pendingDroppedVideoURL = nil
                return
            }
            targetPlaylistID = created
        }

        if await model.addVideo(
            path: droppedURL.path,
            to: targetPlaylistID,
            activateAfterAdding: true
        ) {
            selectedTab = .wallpaper
        }
        pendingDroppedVideoURL = nil
    }

    func playlistDropTargetBinding(for playlistID: UUID) -> Binding<Bool> {
        Binding(
            get: { hoveredPlaylistDropTargetID == playlistID },
            set: { isTargeted in
                if isTargeted {
                    hoveredPlaylistDropTargetID = playlistID
                } else if hoveredPlaylistDropTargetID == playlistID {
                    hoveredPlaylistDropTargetID = nil
                }
            }
        )
    }

    func handleDraggedWallpaperDropToSelectedPlaylist(_ providers: [NSItemProvider]) -> Bool {
        guard let selectedID = model.selectedPlaylistID else {
            return false
        }
        return handleDraggedWallpaperDrop(providers, to: selectedID)
    }

    func handleDraggedWallpaperDrop(_ providers: [NSItemProvider], to playlistID: UUID)
        -> Bool
    {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) })
        else {
            return false
        }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? NSString else {
                return
            }
            let path = text as String
            DispatchQueue.main.async {
                _ = model.addRegisteredVideo(path: path, to: playlistID)
                hoveredPlaylistDropTargetID = nil
            }
        }
        return true
    }

    func startWallpaperNameEdit(path: String) {
        cancelPlaylistNameEdit()
        editingWallpaperPath = path
        editingWallpaperNameInput = model.registeredVideoDisplayName(for: path)
        focusedWallpaperPath = path
    }

    func startPlaylistNameEdit(playlistID: UUID) {
        cancelWallpaperNameEdit()
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
        let fitMode = model.wallpaperFitMode(path: path, screenID: screenID)
        let zoom = model.wallpaperZoom(path: path, screenID: screenID)
        let offsetX = model.wallpaperOffsetX(path: path, screenID: screenID)
        let offsetY = model.wallpaperOffsetY(path: path, screenID: screenID)

        guard fitEditorDraftPath != path
            || fitEditorDraftScreenID != screenID
            || fitEditorDraftFitMode != fitMode
            || fitEditorDraftZoom != zoom
            || fitEditorDraftOffsetX != offsetX
            || fitEditorDraftOffsetY != offsetY
        else {
            return
        }

        fitEditorNormalizeThrottleWorkItem?.cancel()
        fitEditorNormalizeThrottleWorkItem = nil
        fitEditorNormalizeGeneration &+= 1

        fitEditorDraftPath = path
        fitEditorDraftScreenID = screenID
        fitEditorDraftFitMode = fitMode
        fitEditorDraftZoom = zoom
        fitEditorDraftOffsetX = offsetX
        fitEditorDraftOffsetY = offsetY
    }

    func clearFitEditorDraft() {
        guard !fitEditorDraftPath.isEmpty || !fitEditorDraftScreenID.isEmpty else {
            return
        }
        fitEditorNormalizeThrottleWorkItem?.cancel()
        fitEditorNormalizeThrottleWorkItem = nil
        fitEditorNormalizeGeneration &+= 1
        fitEditorDraftPath = ""
        fitEditorDraftScreenID = ""
        fitEditorDraftFitMode = .fill
        fitEditorDraftZoom = 1.0
        fitEditorDraftOffsetX = 0.0
        fitEditorDraftOffsetY = 0.0
    }

    func ensureFitEditorDraft(path: String, screenID: String) {
        if fitEditorDraftPath == path, fitEditorDraftScreenID == screenID {
            return
        }
        loadFitEditorDraft(path: path, screenID: screenID)
    }

    func fitEditorFitMode(path: String, screenID: String) -> VideoFitMode {
        guard fitEditorDraftPath == path, fitEditorDraftScreenID == screenID else {
            return model.wallpaperFitMode(path: path, screenID: screenID)
        }
        return fitEditorDraftFitMode
    }

    func fitEditorZoom(path: String, screenID: String) -> Double {
        guard fitEditorDraftPath == path, fitEditorDraftScreenID == screenID else {
            return model.wallpaperZoom(path: path, screenID: screenID)
        }
        return fitEditorDraftZoom
    }

    func fitEditorOffsetX(path: String, screenID: String) -> Double {
        guard fitEditorDraftPath == path, fitEditorDraftScreenID == screenID else {
            return model.wallpaperOffsetX(path: path, screenID: screenID)
        }
        return fitEditorDraftOffsetX
    }

    func fitEditorOffsetY(path: String, screenID: String) -> Double {
        guard fitEditorDraftPath == path, fitEditorDraftScreenID == screenID else {
            return model.wallpaperOffsetY(path: path, screenID: screenID)
        }
        return fitEditorDraftOffsetY
    }

    func setFitEditorDraftFitMode(_ fitMode: VideoFitMode, path: String, screenID: String) {
        ensureFitEditorDraft(path: path, screenID: screenID)
        fitEditorDraftFitMode = fitMode
        throttledNormalizeFitEditorDraftOffsets(path: path, screenID: screenID)
    }

    func setFitEditorDraftZoom(_ zoom: Double, path: String, screenID: String) {
        ensureFitEditorDraft(path: path, screenID: screenID)
        fitEditorDraftZoom = min(max(zoom, 1.0), 3.0)
        throttledNormalizeFitEditorDraftOffsets(path: path, screenID: screenID)
    }

    func setFitEditorDraftOffsetX(_ offsetX: Double, path: String, screenID: String) {
        ensureFitEditorDraft(path: path, screenID: screenID)
        fitEditorDraftOffsetX = WallpaperGeometry.clampOffset(offsetX)
        throttledNormalizeFitEditorDraftOffsets(path: path, screenID: screenID)
    }

    func setFitEditorDraftOffsetY(_ offsetY: Double, path: String, screenID: String) {
        ensureFitEditorDraft(path: path, screenID: screenID)
        fitEditorDraftOffsetY = WallpaperGeometry.clampOffset(offsetY)
        throttledNormalizeFitEditorDraftOffsets(path: path, screenID: screenID)
    }

    func moveFitEditorDraftOffset(dx: Double, dy: Double, path: String, screenID: String) {
        ensureFitEditorDraft(path: path, screenID: screenID)
        fitEditorDraftOffsetX = WallpaperGeometry.clampOffset(fitEditorDraftOffsetX + dx)
        fitEditorDraftOffsetY = WallpaperGeometry.clampOffset(fitEditorDraftOffsetY + dy)
        throttledNormalizeFitEditorDraftOffsets(path: path, screenID: screenID)
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
            guard fitEditorDraftPath == path, fitEditorDraftScreenID == screenID else {
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
        guard fitEditorDraftPath == path, fitEditorDraftScreenID == screenID else {
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
            fitMode: fitEditorDraftFitMode,
            zoom: fitEditorDraftZoom,
            offsetX: fitEditorDraftOffsetX,
            offsetY: fitEditorDraftOffsetY
        )

        fitEditorDraftOffsetX = normalizedOffset(
            translation: Double(geometry.translation.width),
            maxPan: Double(geometry.maxPan.width)
        )
        fitEditorDraftOffsetY = normalizedOffset(
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

    func applyFitEditorDraft(path: String, screenID: String) {
        ensureFitEditorDraft(path: path, screenID: screenID)
        fitEditorNormalizeThrottleWorkItem?.cancel()
        fitEditorNormalizeThrottleWorkItem = nil
        fitEditorLastNormalizeAt = Date()
        normalizeFitEditorDraftOffsets(path: path, screenID: screenID)
        model.setWallpaperPresentation(
            fitMode: fitEditorDraftFitMode,
            zoom: fitEditorDraftZoom,
            offsetX: fitEditorDraftOffsetX,
            offsetY: fitEditorDraftOffsetY,
            path: path,
            screenID: screenID
        )
        loadFitEditorDraft(path: path, screenID: screenID)
    }

    func resetFitEditorDraft(path: String, screenID: String) {
        ensureFitEditorDraft(path: path, screenID: screenID)
        fitEditorDraftFitMode = model.fitMode
        fitEditorDraftZoom = 1.0
        fitEditorDraftOffsetX = 0.0
        fitEditorDraftOffsetY = 0.0
    }
}

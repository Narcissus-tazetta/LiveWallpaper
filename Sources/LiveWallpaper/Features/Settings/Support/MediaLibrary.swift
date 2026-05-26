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
        fitPreviewStillImages = fitPreviewStillImages.filter { valid.contains($0.key) }
        fitPreviewStillImageInFlight = fitPreviewStillImageInFlight.filter { valid.contains($0) }
        if let selected = fitEditorSelectedVideoPath, !valid.contains(selected) {
            fitEditorSelectedVideoPath = nil
        }
        if let editingPath = editingWallpaperPath, !valid.contains(editingPath) {
            cancelWallpaperNameEdit()
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

        Task.detached(priority: .userInitiated) {
            let image = await FitPreviewService.generateStillImage(path: path)
            await MainActor.run {
                if let image {
                    fitPreviewStillImages[path] = image
                }
                fitPreviewStillImageInFlight.remove(path)
            }
        }
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
            fitEditorDraftPath = ""
            fitEditorDraftScreenID = ""
            return
        }
        loadFitEditorDraft(path: path, screenID: resolvedFitScreenID())
    }

    func loadFitEditorDraft(path: String, screenID: String) {
        fitEditorDraftPath = path
        fitEditorDraftScreenID = screenID
        fitEditorDraftFitMode = model.wallpaperFitMode(path: path, screenID: screenID)
        fitEditorDraftZoom = model.wallpaperZoom(path: path, screenID: screenID)
        fitEditorDraftOffsetX = model.wallpaperOffsetX(path: path, screenID: screenID)
        fitEditorDraftOffsetY = model.wallpaperOffsetY(path: path, screenID: screenID)
    }

    func ensureFitEditorDraft(path: String, screenID: String) {
        if fitEditorDraftPath == path, fitEditorDraftScreenID == screenID {
            return
        }
        loadFitEditorDraft(path: path, screenID: screenID)
    }

    func fitEditorFitMode(path: String, screenID: String) -> VideoFitMode {
        ensureFitEditorDraft(path: path, screenID: screenID)
        return fitEditorDraftFitMode
    }

    func fitEditorZoom(path: String, screenID: String) -> Double {
        ensureFitEditorDraft(path: path, screenID: screenID)
        return fitEditorDraftZoom
    }

    func fitEditorOffsetX(path: String, screenID: String) -> Double {
        ensureFitEditorDraft(path: path, screenID: screenID)
        return fitEditorDraftOffsetX
    }

    func fitEditorOffsetY(path: String, screenID: String) -> Double {
        ensureFitEditorDraft(path: path, screenID: screenID)
        return fitEditorDraftOffsetY
    }

    func setFitEditorDraftFitMode(_ fitMode: VideoFitMode, path: String, screenID: String) {
        ensureFitEditorDraft(path: path, screenID: screenID)
        fitEditorDraftFitMode = fitMode
        normalizeFitEditorDraftOffsets(path: path, screenID: screenID)
    }

    func setFitEditorDraftZoom(_ zoom: Double, path: String, screenID: String) {
        ensureFitEditorDraft(path: path, screenID: screenID)
        fitEditorDraftZoom = min(max(zoom, 1.0), 3.0)
        normalizeFitEditorDraftOffsets(path: path, screenID: screenID)
    }

    func setFitEditorDraftOffsetX(_ offsetX: Double, path: String, screenID: String) {
        ensureFitEditorDraft(path: path, screenID: screenID)
        fitEditorDraftOffsetX = WallpaperGeometry.clampOffset(offsetX)
        normalizeFitEditorDraftOffsets(path: path, screenID: screenID)
    }

    func setFitEditorDraftOffsetY(_ offsetY: Double, path: String, screenID: String) {
        ensureFitEditorDraft(path: path, screenID: screenID)
        fitEditorDraftOffsetY = WallpaperGeometry.clampOffset(offsetY)
        normalizeFitEditorDraftOffsets(path: path, screenID: screenID)
    }

    func moveFitEditorDraftOffset(dx: Double, dy: Double, path: String, screenID: String) {
        ensureFitEditorDraft(path: path, screenID: screenID)
        fitEditorDraftOffsetX = WallpaperGeometry.clampOffset(fitEditorDraftOffsetX + dx)
        fitEditorDraftOffsetY = WallpaperGeometry.clampOffset(fitEditorDraftOffsetY + dy)
        normalizeFitEditorDraftOffsets(path: path, screenID: screenID)
    }

    func updateFitEditorPreviewFrameSize(_ frameSize: CGSize, path: String, screenID: String) {
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

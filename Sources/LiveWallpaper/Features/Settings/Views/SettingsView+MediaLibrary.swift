import AppKit
import AVFoundation
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
            let image = await SettingsView.generateFitPreviewStillImage(path: path)
            await MainActor.run {
                if let image {
                    fitPreviewStillImages[path] = image
                }
                fitPreviewStillImageInFlight.remove(path)
            }
        }
    }

    static func generateFitPreviewStillImage(path: String) async -> NSImage? {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)

        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            duration = CMTime(seconds: 8.0, preferredTimescale: 600)
        }
        let durationSeconds = CMTimeGetSeconds(duration)
        let usableDuration: Double =
            (durationSeconds.isFinite && durationSeconds > 0.3) ? durationSeconds : 8.0
        let rawCandidates: [Double] = [0.18, 0.32, 0.46, 0.60, 0.74]
        let candidateTimes: [CMTime] = rawCandidates.map { ratio in
            let t = min(max(usableDuration * ratio, 0.12), max(usableDuration - 0.12, 0.12))
            return CMTime(seconds: t, preferredTimescale: 600)
        }

        var bestImage: CGImage?
        var bestScore: Double = -1

        for time in candidateTimes {
            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
                continue
            }
            let score = SettingsView.fitPreviewImageScore(cgImage)
            if score > bestScore {
                bestScore = score
                bestImage = cgImage
            }
        }

        if let bestImage {
            return NSImage(
                cgImage: bestImage, size: NSSize(width: bestImage.width, height: bestImage.height)
            )
        }

        let fallbackTimes: [CMTime] = [
            CMTime(seconds: 0.2, preferredTimescale: 600),
            CMTime(seconds: 1.0, preferredTimescale: 600)
        ]
        for time in fallbackTimes {
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                return NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: cgImage.width, height: cgImage.height)
                )
            }
        }

        return nil
    }

    static func fitPreviewImageScore(_ image: CGImage) -> Double {
        let width = 128
        let height = 72
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = bytesPerRow * height
        var raw = [UInt8](repeating: 0, count: totalBytes)

        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: &raw,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return 0
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var luma = [Double](repeating: 0, count: width * height)
        var sum: Double = 0

        for y in 0 ..< height {
            for x in 0 ..< width {
                let i = y * bytesPerRow + x * bytesPerPixel
                let r = Double(raw[i])
                let g = Double(raw[i + 1])
                let b = Double(raw[i + 2])
                let value = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let p = y * width + x
                luma[p] = value
                sum += value
            }
        }

        let count = Double(width * height)
        let mean = sum / count
        var variance: Double = 0
        for v in luma {
            let d = v - mean
            variance += d * d
        }
        variance /= count

        var edgeSum: Double = 0
        var edgeCount: Double = 0
        for y in 0 ..< (height - 1) {
            for x in 0 ..< (width - 1) {
                let p = y * width + x
                let dx = abs(luma[p] - luma[p + 1])
                let dy = abs(luma[p] - luma[p + width])
                edgeSum += dx + dy
                edgeCount += 2
            }
        }
        let edge = edgeCount > 0 ? (edgeSum / edgeCount) : 0

        return variance + edge * 8
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

    func applyDroppedVideo(to playlistID: UUID?) {
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

        if model.addVideo(path: droppedURL.path, to: targetPlaylistID, activateAfterAdding: true) {
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

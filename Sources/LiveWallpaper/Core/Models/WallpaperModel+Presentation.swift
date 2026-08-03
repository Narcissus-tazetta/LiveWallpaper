import AppKit
import AVFoundation
import Foundation

@MainActor
extension WallpaperModel {
    func setFitMode(_ mode: VideoFitMode) {
        guard fitMode != mode else {
            return
        }
        fitMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: PrefsKey.fitMode)
        refreshPlayerPresentations()
    }

    func applyPlayerPresentation(to playerView: PlayerView, screen: NSScreen?) {
        let presentation = resolvedPresentation(for: currentVideoPath, screen: screen)
        let isFitMode: Bool = presentation.fitMode == .fit
        let screenID = displayIDString(for: screen)
        let videoAspect = resolvedVideoAspectRatio(for: currentVideoPath, screenID: screenID)
        let roundedZoom = (presentation.zoom * 10000).rounded() / 10000
        let roundedOffsetX = (presentation.offsetX * 10000).rounded() / 10000
        let roundedOffsetY = (presentation.offsetY * 10000).rounded() / 10000
        let roundedAspect = (videoAspect * 10000).rounded() / 10000
        let key = PresentationCacheKey(
            screenID: screenID,
            boundsWidth: playerView.bounds.width,
            boundsHeight: playerView.bounds.height,
            fitMode: presentation.fitMode,
            zoom: roundedZoom,
            offsetX: roundedOffsetX,
            offsetY: roundedOffsetY,
            videoAspectRatio: roundedAspect
        )
        let playerID = ObjectIdentifier(playerView)
        if presentationCacheByPlayerView[playerID] == key {
            return
        }

        let geometry = WallpaperGeometry.resolve(
            containerSize: playerView.bounds.size,
            videoAspectRatio: videoAspect,
            fitMode: presentation.fitMode,
            zoom: presentation.zoom,
            offsetX: presentation.offsetX,
            offsetY: presentation.offsetY
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerView.playerLayer.videoGravity = isFitMode ? .resizeAspect : .resizeAspectFill
        playerView.playerLayer.backgroundColor = NSColor.black.cgColor
        playerView.playerLayer.setAffineTransform(.identity)

        let containerWidth = max(playerView.bounds.width, 1)
        let containerHeight = max(playerView.bounds.height, 1)
        let renderedWidth = max(CGFloat(geometry.renderedSize.width), 1)
        let renderedHeight = max(CGFloat(geometry.renderedSize.height), 1)
        let tx = CGFloat(geometry.translation.width)
        let ty = CGFloat(geometry.translation.height)
        let originX = ((containerWidth - renderedWidth) * 0.5) + tx
        let originY = ((containerHeight - renderedHeight) * 0.5) + ty

        playerView.playerLayer.frame = CGRect(
            x: originX,
            y: originY,
            width: renderedWidth,
            height: renderedHeight
        )
        CATransaction.commit()
        presentationCacheByPlayerView[playerID] = key
    }

    private func defaultPresentation() -> WallpaperPresentation {
        WallpaperPresentation(fitMode: fitMode, zoom: 1.0, offsetX: 0.0, offsetY: 0.0)
    }

    private func resolvedPresentation(
        for path: String?,
        screen: NSScreen?
    ) -> WallpaperPresentation {
        guard let path else {
            return defaultPresentation()
        }
        let screenID = displayIDString(for: screen)
        if let presentation = wallpaperPresentationByPath[path]?[screenID] {
            return presentation
        }
        return defaultPresentation()
    }

    private func screenForID(_ screenID: String) -> NSScreen? {
        NSScreen.screens.first { displayIDString(for: $0) == screenID }
    }

    private func presentation(for path: String, screenID: String) -> WallpaperPresentation {
        if let presentation = wallpaperPresentationByPath[path]?[screenID] {
            return presentation
        }
        return defaultPresentation()
    }

    private func updatePresentation(
        _ presentation: WallpaperPresentation, for path: String, screenID: String
    ) {
        var pathMap = wallpaperPresentationByPath[path] ?? [:]
        pathMap[screenID] = presentation
        wallpaperPresentationByPath[path] = pathMap
        persistWallpaperPresentationState()
        refreshPlayerPresentations()
    }

    private func screenAspectRatio(for screenID: String) -> Double {
        guard let screen = screenForID(screenID) else {
            return 16.0 / 9.0
        }
        let width = Double(max(screen.frame.width, 1))
        let height = Double(max(screen.frame.height, 1))
        return width / height
    }

    private func videoAspectRatio(for path: String) -> Double {
        if let cached = videoAspectRatioByPath[path] {
            return cached
        }

        ensureVideoAspectRatioLoaded(for: path)
        return 16.0 / 9.0
    }

    private func resolvedVideoAspectRatio(for path: String?, screenID: String) -> Double {
        guard let path else {
            return screenAspectRatio(for: screenID)
        }
        return videoAspectRatio(for: path)
    }

    private func ensureVideoAspectRatioLoaded(for path: String) {
        guard videoAspectRatioByPath[path] == nil else {
            return
        }
        guard !loadingVideoAspectRatioPaths.contains(path) else {
            return
        }
        loadingVideoAspectRatioPaths.insert(path)

        let url = URL(fileURLWithPath: path)
        Task { [weak self] in
            guard let self else {
                return
            }

            let ratio: Double
            var naturalPixelSize: CGSize?
            do {
                let asset = AVURLAsset(url: url)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                if let track = tracks.first {
                    let naturalSize = try await track.load(.naturalSize)
                    let preferredTransform = try await track.load(.preferredTransform)
                    let transformed = naturalSize.applying(preferredTransform)
                    let width = Double(max(abs(transformed.width), 1))
                    let height = Double(max(abs(transformed.height), 1))
                    ratio = width / height
                    naturalPixelSize = CGSize(width: width.rounded(), height: height.rounded())
                } else {
                    ratio = 16.0 / 9.0
                }
            } catch {
                ratio = 16.0 / 9.0
            }

            videoAspectRatioByPath[path] = ratio
            if let naturalPixelSize {
                videoNaturalSizeByPath[path] = naturalPixelSize
            }
            loadingVideoAspectRatioPaths.remove(path)
            refreshPlayerPresentations()
        }
    }

    private func clampedOffset(
        x: Double,
        y: Double,
        for _: WallpaperPresentation,
        path _: String,
        screenID _: String
    ) -> (x: Double, y: Double) {
        let clampedX = WallpaperGeometry.clampOffset(x)
        let clampedY = WallpaperGeometry.clampOffset(y)
        return (x: clampedX, y: clampedY)
    }

    func wallpaperFitMode(path: String, screenID: String) -> VideoFitMode {
        presentation(for: path, screenID: screenID).fitMode
    }

    func wallpaperZoom(path: String, screenID: String) -> Double {
        presentation(for: path, screenID: screenID).zoom
    }

    func wallpaperOffsetX(path: String, screenID: String) -> Double {
        presentation(for: path, screenID: screenID).offsetX
    }

    func wallpaperOffsetY(path: String, screenID: String) -> Double {
        presentation(for: path, screenID: screenID).offsetY
    }

    func wallpaperOffsetLimitX(path: String, screenID: String) -> Double {
        let current = presentation(for: path, screenID: screenID)
        let geometry = WallpaperGeometry.resolve(
            containerSize: screenForID(screenID)?.frame.size ?? CGSize(width: 1920, height: 1080),
            videoAspectRatio: videoAspectRatio(for: path),
            fitMode: current.fitMode,
            zoom: current.zoom,
            offsetX: current.offsetX,
            offsetY: current.offsetY
        )
        return geometry.maxPan.width
    }

    func wallpaperOffsetLimitY(path: String, screenID: String) -> Double {
        let current = presentation(for: path, screenID: screenID)
        let geometry = WallpaperGeometry.resolve(
            containerSize: screenForID(screenID)?.frame.size ?? CGSize(width: 1920, height: 1080),
            videoAspectRatio: videoAspectRatio(for: path),
            fitMode: current.fitMode,
            zoom: current.zoom,
            offsetX: current.offsetX,
            offsetY: current.offsetY
        )
        return geometry.maxPan.height
    }

    func wallpaperRenderGeometry(path: String, screenID: String, containerSize: CGSize)
        -> WallpaperRenderGeometry
    {
        let current = presentation(for: path, screenID: screenID)
        return WallpaperGeometry.resolve(
            containerSize: containerSize,
            videoAspectRatio: videoAspectRatio(for: path),
            fitMode: current.fitMode,
            zoom: current.zoom,
            offsetX: current.offsetX,
            offsetY: current.offsetY
        )
    }

    func wallpaperRenderGeometry(
        path: String,
        screenID _: String,
        containerSize: CGSize,
        fitMode: VideoFitMode,
        zoom: Double,
        offsetX: Double,
        offsetY: Double
    ) -> WallpaperRenderGeometry {
        WallpaperGeometry.resolve(
            containerSize: containerSize,
            videoAspectRatio: videoAspectRatio(for: path),
            fitMode: fitMode,
            zoom: zoom,
            offsetX: offsetX,
            offsetY: offsetY
        )
    }

    func setWallpaperPresentation(
        fitMode: VideoFitMode,
        zoom: Double,
        offsetX: Double,
        offsetY: Double,
        path: String,
        screenID: String
    ) {
        var current = presentation(for: path, screenID: screenID)
        current.fitMode = fitMode
        current.zoom = WallpaperGeometry.clampZoom(zoom)
        let clamped = clampedOffset(
            x: offsetX,
            y: offsetY,
            for: current,
            path: path,
            screenID: screenID
        )
        current.offsetX = clamped.x
        current.offsetY = clamped.y
        updatePresentation(current, for: path, screenID: screenID)
    }

    func setWallpaperFitMode(_ mode: VideoFitMode, path: String, screenID: String) {
        var current = presentation(for: path, screenID: screenID)
        current.fitMode = mode
        let clamped = clampedOffset(
            x: current.offsetX,
            y: current.offsetY,
            for: current,
            path: path,
            screenID: screenID
        )
        current.offsetX = clamped.x
        current.offsetY = clamped.y
        updatePresentation(current, for: path, screenID: screenID)
    }

    func setWallpaperZoom(_ zoom: Double, path: String, screenID: String) {
        var current = presentation(for: path, screenID: screenID)
        current.zoom = WallpaperGeometry.clampZoom(zoom)
        let clamped = clampedOffset(
            x: current.offsetX,
            y: current.offsetY,
            for: current,
            path: path,
            screenID: screenID
        )
        current.offsetX = clamped.x
        current.offsetY = clamped.y
        updatePresentation(current, for: path, screenID: screenID)
    }

    func setWallpaperOffset(x: Double, y: Double, path: String, screenID: String) {
        var current = presentation(for: path, screenID: screenID)
        let clamped = clampedOffset(
            x: x,
            y: y,
            for: current,
            path: path,
            screenID: screenID
        )
        current.offsetX = clamped.x
        current.offsetY = clamped.y
        updatePresentation(current, for: path, screenID: screenID)
    }

    func moveWallpaperOffset(dx: Double, dy: Double, path: String, screenID: String) {
        let current = presentation(for: path, screenID: screenID)
        setWallpaperOffset(
            x: current.offsetX + dx,
            y: current.offsetY + dy,
            path: path,
            screenID: screenID
        )
    }

    func resetWallpaperPresentation(path: String, screenID: String) {
        updatePresentation(defaultPresentation(), for: path, screenID: screenID)
    }

    func hasWallpaperPresentationOverride(path: String, screenID: String) -> Bool {
        wallpaperPresentationByPath[path]?[screenID] != nil
    }

    /// この動画・この画面の個別設定を削除して既定値に従わせる。
    /// resetWallpaperPresentation と違い既定値のスナップショットを残さないため、
    /// 後から設定タブの既定フィットを変えてもこの動画に反映される。
    func clearWallpaperPresentation(path: String, screenID: String) {
        guard var pathMap = wallpaperPresentationByPath[path],
              pathMap.removeValue(forKey: screenID) != nil
        else {
            return
        }
        if pathMap.isEmpty {
            wallpaperPresentationByPath.removeValue(forKey: path)
        } else {
            wallpaperPresentationByPath[path] = pathMap
        }
        persistWallpaperPresentationState()
        refreshPlayerPresentations()
    }

    /// 指定画面の設定を、接続中のすべての画面へコピーする。
    func applyWallpaperPresentationToAllScreens(path: String, fromScreenID screenID: String) {
        let source = presentation(for: path, screenID: screenID)
        var pathMap = wallpaperPresentationByPath[path] ?? [:]
        for screen in availableDisplayScreens() {
            pathMap[screen.id] = source
        }
        pathMap[screenID] = source
        wallpaperPresentationByPath[path] = pathMap
        persistWallpaperPresentationState()
        refreshPlayerPresentations()
    }

    func videoNaturalSize(for path: String) -> CGSize? {
        videoNaturalSizeByPath[path]
    }

    func screenPixelSize(screenID: String) -> CGSize? {
        guard let screen = screenForID(screenID) else {
            return nil
        }
        let scale = screen.backingScaleFactor
        return CGSize(
            width: (screen.frame.width * scale).rounded(),
            height: (screen.frame.height * scale).rounded()
        )
    }

    func commitWallpaperPresentation(path: String, screenID: String) {
        let current = presentation(for: path, screenID: screenID)
        updatePresentation(current, for: path, screenID: screenID)
    }

    func refreshPlayerPresentations() {
        let screens = targetScreens()
        for index in playerViews.indices {
            let screen = index < screens.count ? screens[index] : nil
            applyPlayerPresentation(to: playerViews[index], screen: screen)
        }
    }
}

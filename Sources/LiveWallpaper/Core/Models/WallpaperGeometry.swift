import CoreGraphics

struct WallpaperRenderGeometry: Equatable {
    let renderedSize: CGSize
    let translation: CGSize
    let maxPan: CGSize
}

enum WallpaperGeometry {
    static func clampOffset(_ value: Double) -> Double {
        min(max(value, -1.0), 1.0)
    }

    static func resolve(
        containerSize: CGSize,
        videoAspectRatio: Double,
        fitMode: VideoFitMode,
        zoom: Double,
        offsetX: Double,
        offsetY: Double
    ) -> WallpaperRenderGeometry {
        let containerWidth: Double = max(Double(containerSize.width), 1.0)
        let containerHeight: Double = max(Double(containerSize.height), 1.0)
        let aspect: Double = max(videoAspectRatio, 0.05)
        let containerAspect: Double = containerWidth / containerHeight

        let baseSize: CGSize
        switch fitMode {
        case .fit:
            if containerAspect > aspect {
                let height: Double = containerHeight
                baseSize = CGSize(width: height * aspect, height: height)
            } else {
                let width: Double = containerWidth
                baseSize = CGSize(width: width, height: width / aspect)
            }
        case .fill:
            if containerAspect > aspect {
                let width: Double = containerWidth
                baseSize = CGSize(width: width, height: width / aspect)
            } else {
                let height: Double = containerHeight
                baseSize = CGSize(width: height * aspect, height: height)
            }
        }

        let normalizedZoom: Double = max(zoom, 1.0)
        let renderedWidth = Double(baseSize.width) * normalizedZoom
        let renderedHeight = Double(baseSize.height) * normalizedZoom

        let maxPanX: Double = max((renderedWidth - containerWidth) * 0.5, 0.0)
        let maxPanY: Double = max((renderedHeight - containerHeight) * 0.5, 0.0)

        let normalizedX: Double = clampOffset(offsetX)
        let normalizedY: Double = clampOffset(offsetY)
        let tx: Double = normalizedX * maxPanX
        let ty: Double = normalizedY * maxPanY

        return WallpaperRenderGeometry(
            renderedSize: CGSize(width: renderedWidth, height: renderedHeight),
            translation: CGSize(width: tx, height: ty),
            maxPan: CGSize(width: maxPanX, height: maxPanY)
        )
    }
}

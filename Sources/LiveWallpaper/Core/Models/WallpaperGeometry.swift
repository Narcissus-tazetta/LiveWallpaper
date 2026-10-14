import CoreGraphics

struct WallpaperRenderGeometry: Equatable {
    let renderedSize: CGSize
    let translation: CGSize
    let maxPan: CGSize
}

enum WallpaperGeometry {
    /// ズームの許容範囲。UI(スライダー・ピンチ)とモデル側の clamp はすべてここを参照する。
    static let zoomRange: ClosedRange<Double> = 1.0 ... 3.0

    static func clampZoom(_ value: Double) -> Double {
        min(max(value, zoomRange.lowerBound), zoomRange.upperBound)
    }

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

    /// The part of the video a container shows, in video UV (origin top-left, clamped
    /// to 0...1). The container's y axis points up, as in the desktop's PlayerView.
    static func visibleVideoRect(containerSize: CGSize, geometry: WallpaperRenderGeometry) -> CGRect {
        let width = max(Double(geometry.renderedSize.width), 1)
        let height = max(Double(geometry.renderedSize.height), 1)
        let originX = (Double(containerSize.width) - width) * 0.5 + Double(geometry.translation.width)
        let originY = (Double(containerSize.height) - height) * 0.5 + Double(geometry.translation.height)
        func clamp(_ value: Double) -> Double {
            min(max(value, 0), 1)
        }
        let minX = clamp(-originX / width)
        let maxX = clamp((Double(containerSize.width) - originX) / width)
        let minY = clamp((originY + height - Double(containerSize.height)) / height)
        let maxY = clamp((originY + height) / height)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

import CoreGraphics
import Foundation

struct ForegroundCoverageDisplay: Equatable {
    let id: String
    let frames: [CGRect]

    init(id: String, frame: CGRect) {
        self.id = id
        self.frames = [frame]
    }

    init(id: String, frames: [CGRect]) {
        self.id = id
        self.frames = frames.filter { !$0.isNull && !$0.isEmpty }
    }
}

struct ForegroundCoverageWindow: Equatable {
    let bounds: CGRect
    let alpha: Double
    let layer: Int
    let isMiniaturized: Bool

    init(
        bounds: CGRect,
        alpha: Double = 1,
        layer: Int = 0,
        isMiniaturized: Bool = false
    ) {
        self.bounds = bounds
        self.alpha = alpha
        self.layer = layer
        self.isMiniaturized = isMiniaturized
    }
}

enum ForegroundCoverageGeometry {
    static func coveredDisplayIDs(
        by windows: [ForegroundCoverageWindow],
        displays: [ForegroundCoverageDisplay],
        minimumWindowSize: CGSize = CGSize(width: 120, height: 120),
        coverageThreshold: CGFloat
    ) -> Set<String> {
        guard !windows.isEmpty, !displays.isEmpty else {
            return []
        }

        var covered: Set<String> = []
        for window in windows where isRelevant(window, minimumWindowSize: minimumWindowSize) {
            for display in displays {
                if display.frames.contains(where: { frame in
                    let intersection = window.bounds.intersection(frame)
                    guard !intersection.isNull, !intersection.isEmpty else {
                        return false
                    }
                    let area = max(frame.width * frame.height, 1)
                    let ratio = (intersection.width * intersection.height) / area
                    return ratio >= coverageThreshold
                }) {
                    covered.insert(display.id)
                }
            }
        }
        return covered
    }

    private static func isRelevant(
        _ window: ForegroundCoverageWindow,
        minimumWindowSize: CGSize
    ) -> Bool {
        guard !window.isMiniaturized else {
            return false
        }
        guard window.alpha > 0.01, window.layer >= 0 else {
            return false
        }
        guard window.bounds.width >= minimumWindowSize.width,
              window.bounds.height >= minimumWindowSize.height
        else {
            return false
        }
        return true
    }
}

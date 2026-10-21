import QuartzCore
import SwiftUI

/// What the editor preview shows besides the scene itself: the playback position, the
/// zoomed-in view, the comparison state and the simulated time of day and cursor.
/// None of it is saved or undoable.
@MainActor
final class ScenePreviewController: ObservableObject {
    static let zoomRange = 0.5 ... 8.0

    @Published private(set) var isPlaying = true
    /// Media time at which the loop started, while playing.
    private var anchor = CACurrentMediaTime()
    @Published private(set) var pausedTime: Double = 0
    /// Whether the preview's window can be seen; the playhead stops redrawing while not.
    @Published private(set) var isWindowVisible = true

    @Published private(set) var zoom = 1.0
    /// Canvas UV at the middle of the preview.
    @Published private(set) var center = SIMD2<Double>(0.5, 0.5)

    @Published var isComparing = false
    /// The part of the day the preview shows; nil is now.
    @Published var simulatedTimeOfDay: SceneTimeOfDay?
    /// Where the preview takes the cursor to be, -1...1 per axis (+y down); nil
    /// follows the pointer over the preview.
    @Published var simulatedCursor: SIMD2<Float>?

    /// Seconds into the loop (not wrapped).
    var time: Double {
        isPlaying ? CACurrentMediaTime() - anchor : pausedTime
    }

    func play(from seconds: Double? = nil) {
        anchor = CACurrentMediaTime() - (seconds ?? time)
        isPlaying = true
    }

    func pause() {
        pausedTime = time
        isPlaying = false
    }

    func setWindowVisible(_ visible: Bool) {
        guard isWindowVisible != visible else { return }
        isWindowVisible = visible
    }

    func seek(to seconds: Double) {
        pausedTime = seconds
        isPlaying = false
    }

    /// Origin and size in canvas UV.
    var viewport: SIMD4<Float> {
        let size = 1 / zoom
        return SIMD4(Float(center.x - size / 2), Float(center.y - size / 2), Float(size), Float(size))
    }

    /// Keeps `point` (canvas UV) under the pointer.
    func zoom(by factor: Double, around point: SIMD2<Double>) {
        let newZoom = min(max(zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        guard newZoom != zoom else {
            return
        }
        center = point + (center - point) * (zoom / newZoom)
        zoom = newZoom
        clampCenter()
    }

    func zoom(to value: Double) {
        zoom(by: value / zoom, around: center)
    }

    func pan(by delta: SIMD2<Double>) {
        center += delta
        clampCenter()
    }

    func resetView() {
        zoom = 1
        center = SIMD2(0.5, 0.5)
    }

    /// For another wallpaper: whole view, playing from the start, nothing compared.
    func reset() {
        resetView()
        isComparing = false
        simulatedTimeOfDay = nil
        simulatedCursor = nil
        play(from: 0)
    }

    /// Zoomed in, the view stays on the canvas; zoomed out, the canvas stays centred.
    private func clampCenter() {
        let half = 0.5 / zoom
        for axis in 0 ..< 2 {
            center[axis] = half >= 0.5 ? 0.5 : min(max(center[axis], half), 1 - half)
        }
    }
}

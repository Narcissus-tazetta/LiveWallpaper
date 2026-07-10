import AppKit
import SwiftUI

struct LeftDragCaptureView: NSViewRepresentable {
    var isEnabled: Bool = true
    var onActivate: (() -> Void)?
    var onDelta: (CGSize) -> Void
    var onScrollDelta: ((CGSize) -> Void)?
    var currentZoom: (() -> Double)?
    /// ズーム変更。anchor はビュー中心を原点とした y 下向きの座標で、
    /// カーソル中心ズームの支点として使う(nil は中心ズーム)。
    var onZoomChange: ((Double, CGPoint?) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isEnabled: isEnabled,
            onActivate: onActivate,
            onDelta: onDelta,
            onScrollDelta: onScrollDelta,
            currentZoom: currentZoom,
            onZoomChange: onZoomChange
        )
    }

    func makeNSView(context: Context) -> LeftDragCaptureNSView {
        let view = LeftDragCaptureNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: LeftDragCaptureNSView, context: Context) {
        nsView.coordinator = context.coordinator
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onActivate = onActivate
        context.coordinator.onDelta = onDelta
        context.coordinator.onScrollDelta = onScrollDelta
        context.coordinator.currentZoom = currentZoom
        context.coordinator.onZoomChange = onZoomChange
    }

    final class Coordinator {
        var isEnabled: Bool
        var onActivate: (() -> Void)?
        var onDelta: (CGSize) -> Void
        var onScrollDelta: ((CGSize) -> Void)?
        var currentZoom: (() -> Double)?
        var onZoomChange: ((Double, CGPoint?) -> Void)?
        var lastGestureMagnification: CGFloat = 0

        init(
            isEnabled: Bool = true,
            onActivate: (() -> Void)? = nil,
            onDelta: @escaping (CGSize) -> Void,
            onScrollDelta: ((CGSize) -> Void)? = nil,
            currentZoom: (() -> Double)? = nil,
            onZoomChange: ((Double, CGPoint?) -> Void)? = nil
        ) {
            self.isEnabled = isEnabled
            self.onActivate = onActivate
            self.onDelta = onDelta
            self.onScrollDelta = onScrollDelta
            self.currentZoom = currentZoom
            self.onZoomChange = onZoomChange
        }

        func handleActivate() {
            onActivate?()
        }

        func handleDelta(_ delta: CGSize) {
            onDelta(delta)
        }

        func handleScrollDelta(_ delta: CGSize) {
            onScrollDelta?(delta)
        }

        func zoomBy(multiplier: Double, at anchor: CGPoint?) {
            guard isEnabled else {
                return
            }
            let current = currentZoom?() ?? 1.0
            let next = WallpaperGeometry.clampZoom(current * multiplier)
            onZoomChange?(next, anchor)
        }

        func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
            guard isEnabled else {
                lastGestureMagnification = 0
                return
            }

            switch gesture.state {
            case .began:
                lastGestureMagnification = 0
            case .changed:
                let delta = gesture.magnification - lastGestureMagnification
                lastGestureMagnification = gesture.magnification
                let multiplier = max(0.2, 1.0 + Double(delta))
                let anchor = gesture.view.map { view in
                    zoomAnchor(for: gesture.location(in: view), in: view)
                }
                zoomBy(multiplier: multiplier, at: anchor)
            default:
                lastGestureMagnification = 0
            }
        }

        /// ビュー座標(非フリップ・左下原点)を「中心原点・y 下向き」へ変換する。
        /// プレビューの translation と同じ座標系に合わせるため。
        func zoomAnchor(for location: CGPoint, in view: NSView) -> CGPoint {
            CGPoint(
                x: location.x - view.bounds.midX,
                y: view.isFlipped
                    ? location.y - view.bounds.midY
                    : view.bounds.midY - location.y
            )
        }
    }
}

final class LeftDragCaptureNSView: NSView {
    weak var coordinator: LeftDragCaptureView.Coordinator?
    private lazy var dragGesture: NSPanGestureRecognizer = {
        let gesture = NSPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        gesture.buttonMask = 0x1
        return gesture
    }()

    private lazy var magnificationGesture: NSMagnificationGestureRecognizer = .init(
        target: self,
        action: #selector(handleMagnification(_:))
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addGestureRecognizer(dragGesture)
        addGestureRecognizer(magnificationGesture)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addGestureRecognizer(dragGesture)
        addGestureRecognizer(magnificationGesture)
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func scrollWheel(with event: NSEvent) {
        guard let coordinator, coordinator.isEnabled else {
            nextResponder?.scrollWheel(with: event)
            return
        }

        var deltaX = event.scrollingDeltaX
        var deltaY = event.scrollingDeltaY

        if !event.hasPreciseScrollingDeltas {
            deltaX *= 10
            deltaY *= 10
        }

        if event.modifierFlags.contains(.option) {
            // Option+スクロールはズーム。「上へスクロール=ズームイン」に統一する。
            var zoomDelta = deltaY
            if event.isDirectionInvertedFromDevice {
                zoomDelta *= -1
            }
            let location = convert(event.locationInWindow, from: nil)
            let anchor = coordinator.zoomAnchor(for: location, in: self)
            coordinator.zoomBy(multiplier: pow(1.003, Double(zoomDelta)), at: anchor)
            return
        }

        if !event.isDirectionInvertedFromDevice {
            deltaX *= -1
            deltaY *= -1
        }

        coordinator.handleScrollDelta(CGSize(width: deltaX, height: deltaY))
    }

    override func mouseDown(with event: NSEvent) {
        coordinator?.handleActivate()
        super.mouseDown(with: event)
    }

    @objc
    private func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
        coordinator?.handleMagnification(gesture)
    }

    @objc
    private func handleDrag(_ gesture: NSPanGestureRecognizer) {
        guard coordinator?.isEnabled == true else {
            gesture.setTranslation(.zero, in: self)
            return
        }

        switch gesture.state {
        case .began, .changed:
            let translation = gesture.translation(in: self)
            coordinator?.handleDelta(
                CGSize(width: translation.x, height: translation.y)
            )
            gesture.setTranslation(.zero, in: self)
        default:
            gesture.setTranslation(.zero, in: self)
        }
    }
}

import AppKit
import SwiftUI

/// What a click or drag on the editor preview does.
enum ScenePreviewInteraction: Equatable {
    /// The pointer stands in for the cursor on the desktop.
    case hover
    /// Strokes go to the painter, in this layer's UV.
    case paint(layerID: UUID)
    /// A click picks a point in this layer's UV.
    case pickPoint(layerID: UUID)
}

/// A point drawn over the preview, in a layer's UV.
struct ScenePreviewMarker: Equatable {
    enum Style {
        case anchor
        case mover
        case center
    }

    let layerID: UUID
    let point: SIMD2<Float>
    let style: Style
    let isSelected: Bool
}

/// The editor's live preview: the same renderer as the desktop, animating on wall
/// time while the window is on screen.
struct ScenePreviewView: NSViewRepresentable {
    let document: SceneDocument
    let videoPath: String
    var interaction: ScenePreviewInteraction = .hover
    var painter: SceneMaskPainter?
    var onPickPoint: ((SIMD2<Float>) -> Void)?
    var markers: [ScenePreviewMarker] = []
    /// Seconds into the loop to hold the preview at; nil plays it.
    var fixedTime: Double?

    func makeNSView(context _: Context) -> ScenePreviewNSView {
        ScenePreviewNSView()
    }

    func updateNSView(_ view: ScenePreviewNSView, context _: Context) {
        view.interaction = interaction
        view.painter = painter
        view.onPickPoint = onPickPoint
        painter?.previewLayer = view.sceneLayer
        view.fixedTime = fixedTime
        view.show(document, videoPath: videoPath)
        view.markers = markers
    }

    static func dismantleNSView(_ view: ScenePreviewNSView, coordinator _: ()) {
        view.tearDown()
    }
}

final class ScenePreviewNSView: NSView {
    var interaction: ScenePreviewInteraction = .hover {
        didSet {
            if interaction != oldValue {
                sceneLayer?.setCursor(nil, parallax: .zero)
                window?.invalidateCursorRects(for: self)
            }
        }
    }

    weak var painter: SceneMaskPainter?
    var onPickPoint: ((SIMD2<Float>) -> Void)?
    var markers: [ScenePreviewMarker] = [] {
        didSet {
            if markers != oldValue {
                layoutMarkers()
            }
        }
    }

    private var markerLayers: [CAShapeLayer] = []

    var fixedTime: Double? {
        didSet {
            if fixedTime != oldValue {
                sceneLayer?.clockDidChange()
                layoutMarkers()
            }
        }
    }

    var sceneLayer: SceneMetalLayer? {
        layer as? SceneMetalLayer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        sceneLayer?.hostView = self
        sceneLayer?.clock = { [weak self] in
            if let fixed = self?.fixedTime {
                return SceneClockReading(time: fixed, isRunning: false)
            }
            // Only while the settings window can actually be seen.
            let visible = self?.window?.occlusionState.contains(.visible) ?? false
            return SceneClockReading(time: CACurrentMediaTime(), isRunning: visible)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func makeBackingLayer() -> CALayer {
        SceneMetalLayer()
    }

    func show(_ document: SceneDocument, videoPath: String) {
        do {
            try sceneLayer?.show(document, videoPath: videoPath)
        } catch {
            AppLog.windowRefresh.error("scene preview failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    override func layout() {
        super.layout()
        layoutMarkers()
    }

    /// Markers follow the layer's placement at the frame last drawn.
    private func layoutMarkers() {
        guard let sceneLayer else {
            return
        }
        while markerLayers.count < markers.count {
            let shape = CAShapeLayer()
            shape.lineWidth = 2
            sceneLayer.addSublayer(shape)
            markerLayers.append(shape)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, shape) in markerLayers.enumerated() {
            guard index < markers.count,
                  let canvas = sceneLayer.renderer?.canvasUV(layerUV: markers[index].point, layerID: markers[index].layerID)
            else {
                shape.isHidden = true
                continue
            }
            let marker = markers[index]
            let center = CGPoint(x: CGFloat(canvas.x) * bounds.width, y: CGFloat(1 - canvas.y) * bounds.height)
            let radius: CGFloat = marker.isSelected ? 7 : 5
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            switch marker.style {
            case .anchor:
                shape.path = CGPath(rect: rect.insetBy(dx: 1, dy: 1), transform: nil)
                shape.fillColor = NSColor.systemGray.cgColor
            case .mover:
                shape.path = CGPath(ellipseIn: rect, transform: nil)
                shape.fillColor = NSColor.systemOrange.cgColor
            case .center:
                let path = CGMutablePath()
                path.addEllipse(in: rect)
                path.move(to: CGPoint(x: center.x - radius * 1.6, y: center.y))
                path.addLine(to: CGPoint(x: center.x + radius * 1.6, y: center.y))
                path.move(to: CGPoint(x: center.x, y: center.y - radius * 1.6))
                path.addLine(to: CGPoint(x: center.x, y: center.y + radius * 1.6))
                shape.path = path
                shape.fillColor = NSColor.clear.cgColor
            }
            shape.strokeColor = NSColor.white.cgColor
            shape.shadowOpacity = 0.6
            shape.shadowRadius = 1.5
            shape.shadowOffset = .zero
            shape.isHidden = false
        }
        CATransaction.commit()
    }

    private var occlusionObserver: NSObjectProtocol?

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    func tearDown() {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        sceneLayer?.clear()
        painter = nil
        onPickPoint = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
        occlusionObserver = window.map { window in
            NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sceneLayer?.clockDidChange()
                }
            }
        }
        if window == nil {
            sceneLayer?.suspend()
        } else {
            sceneLayer?.clockDidChange()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        sceneLayer?.contentsScale = window?.backingScaleFactor ?? 2
        sceneLayer?.redraw()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        sceneLayer?.setNeedsDisplay()
    }

    override func resetCursorRects() {
        if interaction != .hover {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        if interaction == .hover {
            follow(event)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if interaction == .hover {
            follow(event)
        }
    }

    override func mouseExited(with _: NSEvent) {
        sceneLayer?.setCursor(nil, parallax: .zero)
    }

    override func mouseDown(with event: NSEvent) {
        switch interaction {
        case .hover:
            super.mouseDown(with: event)
        case let .paint(layerID):
            if let point = layerUV(of: event, layerID: layerID) {
                painter?.strokeBegan(at: point)
            }
        case let .pickPoint(layerID):
            if let point = layerUV(of: event, layerID: layerID) {
                onPickPoint?(SIMD2(min(max(point.x, 0), 1), min(max(point.y, 0), 1)))
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if case let .paint(layerID) = interaction, let point = layerUV(of: event, layerID: layerID) {
            painter?.strokeMoved(to: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .paint = interaction {
            painter?.strokeEnded()
        } else {
            super.mouseUp(with: event)
        }
    }

    private func layerPoint(of event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return isFlipped ? CGPoint(x: point.x, y: bounds.height - point.y) : point
    }

    private func layerUV(of event: NSEvent, layerID: UUID) -> SIMD2<Float>? {
        guard let sceneLayer, let canvas = sceneLayer.canvasUV(of: layerPoint(of: event)) else {
            return nil
        }
        return sceneLayer.renderer?.layerUV(canvasUV: canvas, layerID: layerID)
    }

    private func follow(_ event: NSEvent) {
        guard bounds.width > 0, bounds.height > 0 else {
            return
        }
        let point = layerPoint(of: event)
        let parallax = CGPoint(x: point.x / bounds.width * 2 - 1, y: point.y / bounds.height * 2 - 1)
        sceneLayer?.setCursor(point, parallax: parallax)
    }
}

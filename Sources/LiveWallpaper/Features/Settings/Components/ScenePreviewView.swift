import AppKit
import SwiftUI

/// What a click or drag on the editor preview does.
enum ScenePreviewInteraction: Equatable {
    /// The pointer stands in for the cursor on the desktop; clicks do nothing.
    case hover
    /// Also stands in for the cursor; a click picks a layer and a drag places it.
    case arrange(selectedLayerID: UUID?)
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

/// The editor's live preview: the same renderer as the desktop, on the editor's own
/// clock and zoom.
struct ScenePreviewView: NSViewRepresentable {
    let document: SceneDocument
    let videoPath: String
    @ObservedObject var controller: ScenePreviewController
    var interaction: ScenePreviewInteraction = .hover
    var painter: SceneMaskPainter?
    var onPickPoint: ((SIMD2<Float>) -> Void)?
    var onSelectLayer: ((UUID) -> Void)?
    /// The placement a drag changes for this layer, or nil when it cannot be moved
    /// (locked, or moving over time with no keyframe chosen).
    var editableTransform: ((SceneLayer) -> SceneTransform?)?
    var onTransformLayer: ((UUID, SceneTransform) -> Void)?
    var markers: [ScenePreviewMarker] = []
    /// Seconds into the loop to hold the preview at; nil follows the controller.
    var fixedTime: Double?
    var onScriptIssues: (([SceneScriptIssue]) -> Void)?
    var onScriptLogs: (([UUID: String]) -> Void)?

    func makeNSView(context _: Context) -> ScenePreviewNSView {
        ScenePreviewNSView()
    }

    func updateNSView(_ view: ScenePreviewNSView, context _: Context) {
        view.controller = controller
        view.interaction = interaction
        view.painter = painter
        view.onPickPoint = onPickPoint
        view.onSelectLayer = onSelectLayer
        view.editableTransform = editableTransform
        view.onTransformLayer = onTransformLayer
        painter?.previewLayer = view.sceneLayer
        painter?.onPreviewChange = { [weak view] in
            view?.layoutOverlays()
        }
        view.sceneLayer?.renderer?.showsPaintTint = painter?.showsOverlay ?? true
        view.sceneLayer?.viewport = controller.viewport
        view.sceneLayer?.timeOfDay = controller.simulatedTimeOfDay ?? document.timeOfDay(at: Date())
        view.sceneLayer?.simulatedCursor = controller.simulatedCursor
        view.sceneLayer?.scriptIssueHandler = onScriptIssues
        view.sceneLayer?.scriptLogHandler = onScriptLogs
        view.clockState = ScenePreviewNSView.ClockState(
            fixedTime: fixedTime, isPlaying: controller.isPlaying, pausedTime: controller.pausedTime
        )
        view.show(document, videoPath: videoPath)
        view.markers = markers
        view.layoutOverlays()
    }

    static func dismantleNSView(_ view: ScenePreviewNSView, coordinator _: ()) {
        view.tearDown()
    }
}

final class ScenePreviewNSView: NSView {
    struct ClockState: Equatable {
        var fixedTime: Double?
        var isPlaying: Bool
        var pausedTime: Double
    }

    private enum Drag {
        case move(layerID: UUID, start: SceneTransform, from: SIMD2<Float>)
        case scale(layerID: UUID, start: SceneTransform, from: SIMD2<Float>, center: SIMD2<Float>)
        case rotate(layerID: UUID, start: SceneTransform, from: SIMD2<Float>, center: SIMD2<Float>)
        case pan(from: CGPoint)
    }

    weak var controller: ScenePreviewController?
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
    var onSelectLayer: ((UUID) -> Void)?
    var editableTransform: ((SceneLayer) -> SceneTransform?)?
    var onTransformLayer: ((UUID, SceneTransform) -> Void)?
    var markers: [ScenePreviewMarker] = []

    var clockState = ClockState(fixedTime: nil, isPlaying: true, pausedTime: 0) {
        didSet {
            if clockState != oldValue {
                sceneLayer?.clockDidChange()
            }
        }
    }

    private var markerLayers: [CAShapeLayer] = []
    private let selectionLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()
    private let guideLayer = CAShapeLayer()
    private let brushLayer = CAShapeLayer()
    private let flowLayer = CAShapeLayer()
    private let hitTester = SceneHitTester()
    private var drag: Drag?
    private var snapGuides: [SIMD2<Float>?] = []
    /// Pointer position (this layer's coordinates) for the brush outline.
    private var pointer: CGPoint?

    private static let handleRadius: CGFloat = 5
    private static let rotateHandleDistance: CGFloat = 22
    private static let snapDistance: CGFloat = 6

    var sceneLayer: SceneMetalLayer? {
        layer as? SceneMetalLayer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        sceneLayer?.hostView = self
        sceneLayer?.clock = { [weak self] in
            guard let self else {
                return SceneClockReading(time: 0, isRunning: false)
            }
            if let fixed = clockState.fixedTime {
                return SceneClockReading(time: fixed, isRunning: false)
            }
            // Only while the settings window can actually be seen.
            let visible = window?.occlusionState.contains(.visible) ?? false
            return SceneClockReading(
                time: controller?.time ?? CACurrentMediaTime(), isRunning: clockState.isPlaying && visible
            )
        }
        sceneLayer?.didDraw = { [weak self] in
            // Frames, markers and the brush follow a layer that moves over time.
            if self?.sceneLayer?.renderer?.document.isAnimated == true {
                self?.layoutOverlays()
            }
        }
        for shape in [flowLayer, brushLayer, selectionLayer, guideLayer, handleLayer] {
            shape.fillColor = nil
            shape.shadowOpacity = 0.6
            shape.shadowRadius = 1.5
            shape.shadowOffset = .zero
            shape.actions = ["path": NSNull(), "hidden": NSNull()]
            sceneLayer?.addSublayer(shape)
        }
        selectionLayer.strokeColor = NSColor.controlAccentColor.cgColor
        selectionLayer.lineWidth = 1.5
        handleLayer.strokeColor = NSColor.controlAccentColor.cgColor
        handleLayer.fillColor = NSColor.white.cgColor
        handleLayer.lineWidth = 1.5
        guideLayer.strokeColor = NSColor.systemPink.cgColor
        guideLayer.lineWidth = 1
        brushLayer.strokeColor = NSColor.white.cgColor
        brushLayer.lineWidth = 1
        brushLayer.lineDashPattern = [4, 3]
        flowLayer.strokeColor = NSColor.systemCyan.cgColor
        flowLayer.lineWidth = 1.5
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
        layoutOverlays()
    }

    // MARK: - Overlays

    private func point(_ canvas: SIMD2<Float>) -> CGPoint {
        sceneLayer?.point(ofCanvasUV: canvas) ?? .zero
    }

    /// Markers, the selection frame, snap guides, the brush and the flow arrows follow
    /// the layer's placement at the frame last drawn.
    func layoutOverlays() {
        guard let sceneLayer, let renderer = sceneLayer.renderer else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutMarkers(renderer: renderer)
        layoutSelection(renderer: renderer)
        layoutGuides()
        layoutBrush(renderer: renderer)
        layoutFlow(renderer: renderer)
        CATransaction.commit()
    }

    private func layoutMarkers(renderer: SceneRenderer) {
        while markerLayers.count < markers.count {
            let shape = CAShapeLayer()
            shape.lineWidth = 2
            shape.actions = ["path": NSNull(), "hidden": NSNull()]
            sceneLayer?.insertSublayer(shape, below: handleLayer)
            markerLayers.append(shape)
        }
        for (index, shape) in markerLayers.enumerated() {
            guard index < markers.count,
                  let canvas = renderer.canvasUV(layerUV: markers[index].point, layerID: markers[index].layerID)
            else {
                shape.isHidden = true
                continue
            }
            let marker = markers[index]
            let center = point(canvas)
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
    }

    private var selectedLayer: SceneLayer? {
        guard case let .arrange(id?) = interaction else {
            return nil
        }
        guard let layer = sceneLayer?.renderer?.currentLayer(layerID: id), layer.isVisible else { return nil }
        return layer
    }

    /// The selected layer's corners (top-left, top-right, bottom-right, bottom-left)
    /// and rotation handle, in this layer's coordinates.
    private func frame(of layer: SceneLayer, renderer: SceneRenderer) -> (corners: [CGPoint], rotate: CGPoint)? {
        guard let transform = renderer.currentTransform(layerID: layer.id) else {
            return nil
        }
        let corners = [SIMD2<Float>(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)].map { uv in
            point(renderer.canvasUV(layerUV: uv, layer: layer, transform: transform))
        }
        let top = CGPoint(x: (corners[0].x + corners[1].x) / 2, y: (corners[0].y + corners[1].y) / 2)
        let middle = CGPoint(x: (corners[0].x + corners[2].x) / 2, y: (corners[0].y + corners[2].y) / 2)
        let dx = top.x - middle.x
        let dy = top.y - middle.y
        let length = max((dx * dx + dy * dy).squareRoot(), 0.001)
        let rotate = CGPoint(
            x: top.x + dx / length * Self.rotateHandleDistance, y: top.y + dy / length * Self.rotateHandleDistance
        )
        return (corners, rotate)
    }

    private func layoutSelection(renderer: SceneRenderer) {
        guard let layer = selectedLayer, let frame = frame(of: layer, renderer: renderer) else {
            selectionLayer.isHidden = true
            handleLayer.isHidden = true
            return
        }
        let outline = CGMutablePath()
        outline.addLines(between: frame.corners)
        outline.closeSubpath()
        selectionLayer.path = outline
        selectionLayer.isHidden = false
        // A layer that cannot be placed shows its frame dashed, without handles.
        let editable = editableTransform?(layer) != nil
        selectionLayer.lineDashPattern = editable ? nil : [4, 3]
        guard editable else {
            handleLayer.isHidden = true
            return
        }
        let handles = CGMutablePath()
        let r = Self.handleRadius
        for corner in frame.corners {
            handles.addRect(CGRect(x: corner.x - r, y: corner.y - r, width: r * 2, height: r * 2))
        }
        let top = CGPoint(x: (frame.corners[0].x + frame.corners[1].x) / 2, y: (frame.corners[0].y + frame.corners[1].y) / 2)
        handles.move(to: top)
        handles.addLine(to: frame.rotate)
        handles.addEllipse(in: CGRect(x: frame.rotate.x - r, y: frame.rotate.y - r, width: r * 2, height: r * 2))
        handleLayer.path = handles
        handleLayer.isHidden = false
    }

    private func layoutGuides() {
        let path = CGMutablePath()
        for guide in snapGuides {
            guard let guide else {
                continue
            }
            if guide.x.isFinite {
                let x = point(SIMD2(guide.x, 0)).x
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: bounds.height))
            }
            if guide.y.isFinite {
                let y = point(SIMD2(0, guide.y)).y
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: bounds.width, y: y))
            }
        }
        guideLayer.path = path
        guideLayer.isHidden = snapGuides.isEmpty
    }

    private func layoutBrush(renderer: SceneRenderer) {
        guard case let .paint(layerID) = interaction, let painter, painter.target != nil, let pointer,
              let sceneLayer, let canvas = sceneLayer.canvasUV(of: pointer),
              let center = renderer.layerUV(canvasUV: canvas, layerID: layerID)
        else {
            brushLayer.isHidden = true
            return
        }
        // Round in the layer's pixels, so a turned or stretched layer turns it too.
        let radius = painter.brushRadiusUV
        let path = CGMutablePath()
        for step in 0 ... 48 {
            let angle = Float(step) / 48 * 2 * .pi
            let uv = center + SIMD2(cos(angle), sin(angle)) * radius
            let p = renderer.canvasUV(layerUV: uv, layerID: layerID).map(point) ?? .zero
            if step == 0 {
                path.move(to: p)
            } else {
                path.addLine(to: p)
            }
        }
        brushLayer.path = path
        brushLayer.isHidden = false
    }

    private func layoutFlow(renderer: SceneRenderer) {
        guard case let .paint(layerID) = interaction, let painter, painter.showsOverlay,
              painter.target?.kind == .flow
        else {
            flowLayer.isHidden = true
            return
        }
        let path = CGMutablePath()
        for arrow in painter.flowArrows(columns: 24) {
            guard let start = renderer.canvasUV(layerUV: arrow.position - arrow.flow * 0.4, layerID: layerID),
                  let end = renderer.canvasUV(layerUV: arrow.position + arrow.flow * 0.4, layerID: layerID)
            else {
                continue
            }
            let a = point(start)
            let b = point(end)
            path.move(to: a)
            path.addLine(to: b)
            let dx = b.x - a.x
            let dy = b.y - a.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 2 else {
                continue
            }
            let head = min(length * 0.4, 5)
            let ux = dx / length
            let uy = dy / length
            path.move(to: CGPoint(x: b.x - ux * head - uy * head * 0.6, y: b.y - uy * head + ux * head * 0.6))
            path.addLine(to: b)
            path.addLine(to: CGPoint(x: b.x - ux * head + uy * head * 0.6, y: b.y - uy * head - ux * head * 0.6))
        }
        flowLayer.path = path
        flowLayer.isHidden = false
    }

    // MARK: - Lifecycle

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
        painter?.onPreviewChange = nil
        painter = nil
        onPickPoint = nil
        onSelectLayer = nil
        onTransformLayer = nil
        editableTransform = nil
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
        switch interaction {
        case .paint, .pickPoint:
            addCursorRect(bounds, cursor: .crosshair)
        case .hover, .arrange:
            break
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

    // MARK: - Pointer

    override func mouseMoved(with event: NSEvent) {
        pointer = layerPoint(of: event)
        switch interaction {
        case .hover, .arrange:
            follow(event)
        case .paint:
            layoutOverlays()
        case .pickPoint:
            break
        }
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with _: NSEvent) {
        pointer = nil
        sceneLayer?.setCursor(nil, parallax: .zero)
        layoutOverlays()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        switch interaction {
        case .hover:
            beginPanIfZoomed(event)
        case let .arrange(selectedID):
            beginArrange(event, selectedID: selectedID)
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
        pointer = layerPoint(of: event)
        if case let .paint(layerID) = interaction {
            if let point = layerUV(of: event, layerID: layerID) {
                painter?.strokeMoved(to: point)
            }
            return
        }
        continueDrag(event)
    }

    override func mouseUp(with event: NSEvent) {
        sceneLayer?.unfreezeScripts()
        if case .paint = interaction {
            painter?.strokeEnded()
            return
        }
        drag = nil
        snapGuides = []
        layoutOverlays()
        if case .hover = interaction {
            super.mouseUp(with: event)
        }
    }

    // MARK: - Zoom and pan (viewing only, never the wallpaper's placement)

    override func magnify(with event: NSEvent) {
        guard let controller, let canvas = canvasPoint(of: event) else {
            return
        }
        controller.zoom(by: 1 + event.magnification, around: SIMD2(Double(canvas.x), Double(canvas.y)))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let controller else {
            super.scrollWheel(with: event)
            return
        }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            guard let canvas = canvasPoint(of: event) else {
                return
            }
            let factor = exp(Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1))
            controller.zoom(by: factor, around: SIMD2(Double(canvas.x), Double(canvas.y)))
            return
        }
        // At the whole view the settings page scrolls as usual.
        guard controller.zoom > 1, bounds.width > 0, bounds.height > 0 else {
            super.scrollWheel(with: event)
            return
        }
        let size = 1 / controller.zoom
        controller.pan(by: SIMD2(
            -Double(event.scrollingDeltaX) / Double(bounds.width) * size,
            -Double(event.scrollingDeltaY) / Double(bounds.height) * size
        ))
    }

    private func beginPanIfZoomed(_ event: NSEvent) {
        if let controller, controller.zoom > 1 {
            drag = .pan(from: layerPoint(of: event))
        }
    }

    // MARK: - Placing layers

    private func beginArrange(_ event: NSEvent, selectedID: UUID?) {
        guard let sceneLayer, let renderer = sceneLayer.renderer else {
            return
        }
        let location = layerPoint(of: event)
        guard let canvas = sceneLayer.canvasUV(of: location) else {
            return
        }
        if renderer.document.scripts.contains(where: \.canRun) {
            controller?.pause()
            sceneLayer.freezeScriptsForEditing()
        }
        // The selected layer's handles come first, even over other layers.
        if let layer = selectedLayer, let transform = editableTransform?(layer),
           let frame = frame(of: layer, renderer: renderer)
        {
            if distance(location, frame.rotate) <= Self.handleRadius + 3 {
                let drawn = renderer.currentTransform(layerID: layer.id)!
                drag = .rotate(layerID: layer.id, start: transform, from: canvas,
                               center: SIMD2(Float(drawn.offsetX), Float(drawn.offsetY)) + 0.5)
                return
            }
            if frame.corners.contains(where: { distance(location, $0) <= Self.handleRadius + 3 }) {
                let drawn = renderer.currentTransform(layerID: layer.id)!
                drag = .scale(layerID: layer.id, start: transform, from: canvas,
                              center: SIMD2(Float(drawn.offsetX), Float(drawn.offsetY)) + 0.5)
                return
            }
        }
        let hit = hitLayer(at: canvas, renderer: renderer)
        if let hit, hit.id != selectedID {
            onSelectLayer?(hit.id)
        }
        // Inside the selected layer's frame a drag moves it, even through its holes.
        let target = hit ?? selectedLayer.flatMap { layer in
            renderer.layerUV(canvasUV: canvas, layerID: layer.id).map { uv in
                (0 ... 1).contains(uv.x) && (0 ... 1).contains(uv.y) ? layer : nil
            } ?? nil
        }
        if let target, let transform = editableTransform?(target) {
            drag = .move(layerID: target.id, start: transform, from: canvas)
        } else if target == nil {
            beginPanIfZoomed(event)
        }
    }

    /// The topmost visible, unlocked image layer drawn at `canvas`.
    private func hitLayer(at canvas: SIMD2<Float>, renderer: SceneRenderer) -> SceneLayer? {
        for saved in renderer.document.layers.reversed() {
            let layer = renderer.currentLayer(layerID: saved.id)!
            guard layer.isVisible, !layer.isLocked, layer.kind == .image,
                  renderer.currentOpacity(layerID: layer.id)! > 0.02 else { continue }
            guard let uv = renderer.layerUV(canvasUV: canvas, layerID: layer.id), let videoPath = sceneLayer?.videoPath
            else {
                continue
            }
            if hitTester.isOpaque(fileURL: SceneStore.imageURL(layer, videoPath: videoPath), at: uv) {
                return layer
            }
        }
        return nil
    }

    private func continueDrag(_ event: NSEvent) {
        guard let drag, let sceneLayer, let renderer = sceneLayer.renderer else {
            return
        }
        let location = layerPoint(of: event)
        if case let .pan(from) = drag {
            if let controller, bounds.width > 0, bounds.height > 0 {
                let size = 1 / controller.zoom
                controller.pan(by: SIMD2(
                    -Double(location.x - from.x) / Double(bounds.width) * size,
                    Double(location.y - from.y) / Double(bounds.height) * size
                ))
            }
            self.drag = .pan(from: location)
            return
        }
        guard let canvas = sceneLayer.canvasUV(of: location) else {
            return
        }
        let aspect = Float(renderer.document.aspectRatio)
        // Distances and angles in a space with the canvas's proportions.
        func shaped(_ v: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2(v.x * aspect, v.y)
        }
        switch drag {
        case let .move(layerID, start, from):
            var transform = start
            transform.offsetX = start.offsetX + Double(canvas.x - from.x)
            transform.offsetY = start.offsetY + Double(canvas.y - from.y)
            if let layer = renderer.document.layers.first(where: { $0.id == layerID }), !renderer.document.scripts.contains(where: \.canRun) {
                transform = snapped(transform, layer: layer, renderer: renderer, enabled: !event.modifierFlags.contains(.command))
            }
            onTransformLayer?(layerID, transform)
        case let .scale(layerID, start, from, center):
            let before = length(shaped(from - center))
            let now = length(shaped(canvas - center))
            guard before > 0.0001 else {
                return
            }
            var transform = start
            let range = SceneTransform.scaleRange
            transform.scale = min(max(start.scale * Double(now / before), range.lowerBound), range.upperBound)
            onTransformLayer?(layerID, transform)
        case let .rotate(layerID, start, from, center):
            let a = shaped(from - center)
            let b = shaped(canvas - center)
            // y points down, so a growing angle turns clockwise like `rotation`.
            let turn = Double(atan2(b.y, b.x) - atan2(a.y, a.x)) * 180 / .pi
            var degrees = start.rotation + turn
            if event.modifierFlags.contains(.shift) {
                degrees = (degrees / 15).rounded() * 15
            }
            degrees = (degrees + 180).truncatingRemainder(dividingBy: 360)
            degrees = (degrees < 0 ? degrees + 360 : degrees) - 180
            var transform = start
            transform.rotation = degrees
            onTransformLayer?(layerID, transform)
        case .pan:
            break
        }
    }

    /// Pulls the layer's centre to the canvas centre and its edges to the canvas
    /// edges when they come within a few points, and shows a guide for each.
    private func snapped(
        _ transform: SceneTransform,
        layer: SceneLayer,
        renderer: SceneRenderer,
        enabled: Bool
    ) -> SceneTransform {
        snapGuides = []
        guard enabled, let viewport = sceneLayer?.viewport, bounds.width > 0, bounds.height > 0 else {
            return transform
        }
        let corners = [SIMD2<Float>(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)].map { uv in
            renderer.canvasUV(layerUV: uv, layer: layer, transform: transform)
        }
        let threshold = SIMD2(
            Float(Self.snapDistance / bounds.width) * viewport.z, Float(Self.snapDistance / bounds.height) * viewport.w
        )
        var result = transform
        for axis in 0 ..< 2 {
            let values = corners.map { $0[axis] }
            let center = Float(axis == 0 ? transform.offsetX : transform.offsetY) + 0.5
            let candidates: [(value: Float, target: Float)] = [
                (center, 0.5), (values.min()!, 0), (values.max()!, 1), (values.min()!, 0.5), (values.max()!, 0.5)
            ]
            guard let best = candidates.min(by: { abs($0.target - $0.value) < abs($1.target - $1.value) }),
                  abs(best.target - best.value) <= threshold[axis]
            else {
                continue
            }
            let shift = Double(best.target - best.value)
            if axis == 0 {
                result.offsetX += shift
                snapGuides.append(SIMD2(best.target, .infinity))
            } else {
                result.offsetY += shift
                snapGuides.append(SIMD2(.infinity, best.target))
            }
        }
        return result
    }

    // MARK: - Coordinates

    private func layerPoint(of event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return isFlipped ? CGPoint(x: point.x, y: bounds.height - point.y) : point
    }

    private func canvasPoint(of event: NSEvent) -> SIMD2<Float>? {
        sceneLayer?.canvasUV(of: layerPoint(of: event))
    }

    private func layerUV(of event: NSEvent, layerID: UUID) -> SIMD2<Float>? {
        guard let sceneLayer, let canvas = sceneLayer.canvasUV(of: layerPoint(of: event)) else {
            return nil
        }
        return sceneLayer.renderer?.layerUV(canvasUV: canvas, layerID: layerID)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private func length(_ v: SIMD2<Float>) -> Float {
        (v.x * v.x + v.y * v.y).squareRoot()
    }

    /// The pointer stands in for the desktop cursor. Parallax follows the view, not
    /// the zoomed canvas, as it follows the whole screen on the desktop.
    private func follow(_ event: NSEvent) {
        guard bounds.width > 0, bounds.height > 0 else {
            return
        }
        let point = layerPoint(of: event)
        let parallax = CGPoint(x: point.x / bounds.width * 2 - 1, y: point.y / bounds.height * 2 - 1)
        sceneLayer?.setCursor(point, parallax: parallax)
    }
}

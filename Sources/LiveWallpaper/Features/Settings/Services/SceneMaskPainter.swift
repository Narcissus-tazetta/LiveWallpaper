import Foundation

/// Paints an effect's mask (where it applies), its time offset (when it moves), or
/// a flow map (which way it flows) on the editor preview. Strokes show on the preview immediately and are
/// saved as a new file when each stroke ends, so the scene's undo history covers them.
@MainActor
final class SceneMaskPainter: ObservableObject {
    enum Tool: String, CaseIterable {
        case paint
        case erase
    }

    struct Target: Equatable {
        let path: String
        let layerID: UUID
        let effectID: UUID
        let kind: ScenePaintOverride.Target
        /// The effect moves the picture against its flow vectors: a stroke is stored
        /// reversed, so the picture still flows the way it was drawn.
        var storesFlowReversed = false
    }

    @Published var tool: Tool = .paint
    /// Brush radius as a fraction of the layer's height.
    @Published var brushSize = 0.08
    /// 0 fades from the centre, 1 is a hard edge.
    @Published var hardness = 0.5
    @Published private(set) var target: Target?
    /// Tints the painted area and draws the flow's arrows on the preview.
    @Published var showsOverlay = true

    weak var previewLayer: SceneMetalLayer?
    /// Called after the painted pixels or the target changed, to redraw guides.
    var onPreviewChange: (() -> Void)?
    /// Saves the painted file name into the scene, with the painted area's box for a mask.
    var onCommit: ((Target, String, SceneAreaBounds?) -> Void)?
    var onError: ((Error) -> Void)?

    private var width = 0
    private var height = 0
    private var bytes: [UInt8] = []
    /// The file `bytes` were read from or last saved as.
    private var currentFile: String?
    private var lastPoint: SIMD2<Float>?
    private var strokeChanged = false

    /// Masks are soft, so this is plenty and keeps strokes fast.
    private static let maxMaskEdge = 1024
    private static let maxFlowEdge = 512

    private var bytesPerPixel: Int {
        target?.kind.isGrey == true ? 1 : 4
    }

    /// `existingFile` is the effect's current mask or flow file, if any.
    func begin(_ target: Target, existingFile: String?, layerPixelSize: CGSize) {
        end()
        let maxEdge = target.kind.isGrey ? Self.maxMaskEdge : Self.maxFlowEdge
        let scale = min(1, Double(maxEdge) / Double(max(layerPixelSize.width, layerPixelSize.height, 1)))
        width = max(Int(Double(layerPixelSize.width) * scale), 8)
        height = max(Int(Double(layerPixelSize.height) * scale), 8)
        self.target = target
        load(existingFile)
    }

    /// Follows the scene after undo or redo put a different file in place.
    func reload(existingFile: String?) {
        guard target != nil, existingFile != currentFile else {
            return
        }
        lastPoint = nil
        load(existingFile)
    }

    private func load(_ existingFile: String?) {
        guard let target else {
            return
        }
        currentFile = existingFile
        if let existingFile {
            do {
                bytes = try SceneStore.readPaintImage(
                    existingFile, width: width, height: height, target: target.kind, videoPath: target.path
                )
            } catch {
                onError?(error)
                bytes = blank()
            }
        } else {
            bytes = blank()
        }
        pushPreview()
    }

    func end() {
        guard target != nil else {
            return
        }
        target = nil
        bytes = []
        currentFile = nil
        previewLayer?.setPaintOverride(nil)
        onPreviewChange?()
    }

    /// The brush's radius in layer UV per axis (it is round in pixels).
    var brushRadiusUV: SIMD2<Float> {
        guard width > 0, height > 0 else {
            return .zero
        }
        return SIMD2(brushRadiusInPixels / Float(width), brushRadiusInPixels / Float(height))
    }

    /// The painted flow on a grid of about `columns` across: each cell's centre and
    /// its flow (layer UV per unit, up to 1), skipping still cells.
    func flowArrows(columns: Int) -> [(position: SIMD2<Float>, flow: SIMD2<Float>)] {
        guard target?.kind == .flow, width > 0, height > 0, bytes.count == width * height * 4 else {
            return []
        }
        let step = max(width / max(columns, 1), 1)
        var arrows: [(position: SIMD2<Float>, flow: SIMD2<Float>)] = []
        for y in stride(from: step / 2, to: height, by: step) {
            for x in stride(from: step / 2, to: width, by: step) {
                let index = (y * width + x) * 4
                let stored = SIMD2((Float(bytes[index]) - 128) / 127, (Float(bytes[index + 1]) - 128) / 127)
                let flow = target?.storesFlowReversed == true ? -stored : stored
                guard (flow.x * flow.x + flow.y * flow.y) > 0.01 else {
                    continue
                }
                arrows.append((
                    SIMD2((Float(x) + 0.5) / Float(width), (Float(y) + 0.5) / Float(height)),
                    SIMD2(flow.x * Float(step) / Float(width), flow.y * Float(step) / Float(height))
                ))
            }
        }
        return arrows
    }

    // MARK: - Strokes (points in layer UV, origin top-left)

    func strokeBegan(at point: SIMD2<Float>) {
        guard target != nil else {
            return
        }
        lastPoint = point
        strokeChanged = false
        stamp(at: point, direction: nil)
        pushPreview()
    }

    func strokeMoved(to point: SIMD2<Float>) {
        guard target != nil, let lastPoint else {
            return
        }
        let delta = SIMD2<Float>((point.x - lastPoint.x) * Float(width), (point.y - lastPoint.y) * Float(height))
        let length = (delta.x * delta.x + delta.y * delta.y).squareRoot()
        guard length > 0.5 else {
            return
        }
        let direction = delta / length
        let radius = brushRadiusInPixels
        let steps = max(Int(length / max(radius * 0.25, 1)), 1)
        for step in 1 ... steps {
            let t = Float(step) / Float(steps)
            stamp(at: lastPoint + (point - lastPoint) * t, direction: direction)
        }
        self.lastPoint = point
        pushPreview()
    }

    func strokeEnded() {
        guard target != nil, lastPoint != nil else {
            return
        }
        lastPoint = nil
        if strokeChanged {
            commit()
        }
    }

    func fillAll() {
        guard let target, target.kind.isGrey else {
            return
        }
        bytes = [UInt8](repeating: 255, count: width * height)
        pushPreview()
        commit()
    }

    func clearAll() {
        guard target != nil else {
            return
        }
        bytes = blank()
        pushPreview()
        commit()
    }

    // MARK: - Private

    private var brushRadiusInPixels: Float {
        max(Float(brushSize) * Float(height), 1)
    }

    private func blank() -> [UInt8] {
        guard target?.kind == .flow else {
            return [UInt8](repeating: 0, count: width * height)
        }
        var still = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: still.count, by: 4) {
            still[index] = 128
            still[index + 1] = 128
            still[index + 3] = 255
        }
        return still
    }

    /// `direction` (unit, pixel space) is the stroke's heading; flow maps need one.
    private func stamp(at point: SIMD2<Float>, direction: SIMD2<Float>?) {
        guard let target else {
            return
        }
        if target.kind == .flow, tool == .paint, direction == nil {
            return
        }
        let radius = brushRadiusInPixels
        let centerX = point.x * Float(width)
        let centerY = point.y * Float(height)
        let inner = radius * Float(min(max(hardness, 0), 0.99))
        let minX = max(Int(centerX - radius), 0)
        let maxX = min(Int(centerX + radius), width - 1)
        let minY = max(Int(centerY - radius), 0)
        let maxY = min(Int(centerY + radius), height - 1)
        guard minX <= maxX, minY <= maxY else {
            return
        }
        for y in minY ... maxY {
            for x in minX ... maxX {
                let dx = Float(x) + 0.5 - centerX
                let dy = Float(y) + 0.5 - centerY
                let distance = (dx * dx + dy * dy).squareRoot()
                guard distance < radius else {
                    continue
                }
                let falloff = distance <= inner ? 1 : 1 - (distance - inner) / max(radius - inner, 0.001)
                let index = (y * width + x) * bytesPerPixel
                if target.kind.isGrey {
                    let value = Float(bytes[index])
                    let updated = tool == .paint ? max(value, falloff * 255) : min(value, (1 - falloff) * 255)
                    if UInt8(updated.rounded()) != bytes[index] {
                        bytes[index] = UInt8(updated.rounded())
                        strokeChanged = true
                    }
                } else {
                    let heading = (direction ?? .zero) * (target.storesFlowReversed ? -1 : 1)
                    let goal = tool == .paint ? heading : .zero
                    let currentX = (Float(bytes[index]) - 128) / 127
                    let currentY = (Float(bytes[index + 1]) - 128) / 127
                    let weight = falloff * 0.5
                    let newX = currentX + (goal.x - currentX) * weight
                    let newY = currentY + (goal.y - currentY) * weight
                    bytes[index] = UInt8(min(max(128 + newX * 127, 0), 255).rounded())
                    bytes[index + 1] = UInt8(min(max(128 + newY * 127, 0), 255).rounded())
                    strokeChanged = true
                }
            }
        }
    }

    private func pushPreview() {
        guard let target else {
            return
        }
        previewLayer?.setPaintOverride(ScenePaintOverride(
            effectID: target.effectID, target: target.kind, width: width, height: height, bytes: bytes
        ))
        onPreviewChange?()
    }

    private func commit() {
        guard let target else {
            return
        }
        do {
            let fileName = try SceneStore.writePaintImage(
                bytes, width: width, height: height, target: target.kind, videoPath: target.path
            )
            currentFile = fileName
            let bounds = target.kind == .mask ? SceneAreaBounds.of(bytes, width: width, height: height) : nil
            onCommit?(target, fileName, bounds)
        } catch {
            onError?(error)
        }
    }
}

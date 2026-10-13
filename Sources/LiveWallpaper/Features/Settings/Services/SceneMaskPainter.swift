import Foundation

/// Paints an effect's mask (where it applies) or a water-flow map (which way it
/// flows) on the editor preview. Strokes show on the preview immediately and are
/// saved as a new file when each stroke ends.
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
    }

    @Published var tool: Tool = .paint
    /// Brush radius as a fraction of the layer's height.
    @Published var brushSize = 0.08
    /// 0 fades from the centre, 1 is a hard edge.
    @Published var hardness = 0.5
    @Published private(set) var target: Target?
    @Published private(set) var canUndo = false

    weak var previewLayer: SceneMetalLayer?
    /// Saves the painted file name into the scene.
    var onCommit: ((Target, String) -> Void)?
    var onError: ((Error) -> Void)?

    private var width = 0
    private var height = 0
    private var bytes: [UInt8] = []
    private var undoStack: [[UInt8]] = []
    private var lastPoint: SIMD2<Float>?
    private var strokeChanged = false

    private static let maxUndo = 30
    /// Masks are soft, so this is plenty and keeps strokes fast.
    private static let maxMaskEdge = 1024
    private static let maxFlowEdge = 512

    private var bytesPerPixel: Int {
        target?.kind == .mask ? 1 : 4
    }

    /// `existingFile` is the effect's current mask or flow file, if any.
    func begin(_ target: Target, existingFile: String?, layerPixelSize: CGSize) {
        end()
        let maxEdge = target.kind == .mask ? Self.maxMaskEdge : Self.maxFlowEdge
        let scale = min(1, Double(maxEdge) / Double(max(layerPixelSize.width, layerPixelSize.height, 1)))
        width = max(Int(Double(layerPixelSize.width) * scale), 8)
        height = max(Int(Double(layerPixelSize.height) * scale), 8)
        self.target = target
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
        undoStack = []
        canUndo = false
        pushPreview()
    }

    func end() {
        guard target != nil else {
            return
        }
        target = nil
        bytes = []
        undoStack = []
        canUndo = false
        previewLayer?.setPaintOverride(nil)
    }

    // MARK: - Strokes (points in layer UV, origin top-left)

    func strokeBegan(at point: SIMD2<Float>) {
        guard target != nil else {
            return
        }
        pushUndo()
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
        } else {
            undoStack.removeLast()
            canUndo = !undoStack.isEmpty
        }
    }

    func fillAll() {
        guard let target, target.kind == .mask else {
            return
        }
        pushUndo()
        bytes = [UInt8](repeating: 255, count: width * height)
        pushPreview()
        commit()
    }

    func clearAll() {
        guard target != nil else {
            return
        }
        pushUndo()
        bytes = blank()
        pushPreview()
        commit()
    }

    func undo() {
        guard let previous = undoStack.popLast() else {
            return
        }
        bytes = previous
        canUndo = !undoStack.isEmpty
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

    private func pushUndo() {
        undoStack.append(bytes)
        if undoStack.count > Self.maxUndo {
            undoStack.removeFirst()
        }
        canUndo = true
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
                if target.kind == .mask {
                    let value = Float(bytes[index])
                    let updated = tool == .paint ? max(value, falloff * 255) : min(value, (1 - falloff) * 255)
                    if UInt8(updated.rounded()) != bytes[index] {
                        bytes[index] = UInt8(updated.rounded())
                        strokeChanged = true
                    }
                } else {
                    let goal = tool == .paint ? (direction ?? .zero) : .zero
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
    }

    private func commit() {
        guard let target else {
            return
        }
        do {
            let fileName = try SceneStore.writePaintImage(
                bytes, width: width, height: height, target: target.kind, videoPath: target.path
            )
            onCommit?(target, fileName)
        } catch {
            onError?(error)
        }
    }
}

import AppKit

/// 矢印キーの keyCode(HIToolbox の kVK_* 相当)。
private enum FitArrowKeyCode {
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
}

/// フィット編集タブでの矢印キー操作(プレビューのパン)。
extension FitEditorController {
    func installKeyMonitorIfNeeded() {
        guard keyEventMonitor == nil else {
            return
        }

        keyEventMonitor =
            NSEvent
            .addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, isActive, isSubModeActive else {
                    return event
                }
                // A text field (name edit, search, ...) is being edited: let the
                // arrow keys move the caret/selection instead of panning the
                // preview. The field editor backing any focused NSTextField or
                // SwiftUI TextField is an NSTextView, a subclass of NSText.
                if (event.window ?? NSApp.keyWindow)?.firstResponder is NSText {
                    return event
                }
                guard let path = resolvedVideoPath(), !path.isEmpty else {
                    return event
                }

                let step = event.modifierFlags.contains(.shift) ? 0.01 : 0.002
                let screenID = resolvedScreenID()

                switch event.keyCode {
                case FitArrowKeyCode.left:
                    moveDraftOffset(dx: -step, dy: 0, path: path, screenID: screenID)
                    return nil
                case FitArrowKeyCode.right:
                    moveDraftOffset(dx: step, dy: 0, path: path, screenID: screenID)
                    return nil
                case FitArrowKeyCode.down:
                    moveDraftOffset(dx: 0, dy: step, path: path, screenID: screenID)
                    return nil
                case FitArrowKeyCode.up:
                    moveDraftOffset(dx: 0, dy: -step, path: path, screenID: screenID)
                    return nil
                default:
                    return event
                }
            }
    }

    func removeKeyMonitor() {
        guard let monitor = keyEventMonitor else {
            return
        }
        NSEvent.removeMonitor(monitor)
        keyEventMonitor = nil
    }
}

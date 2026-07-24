import AppKit

/// トリム編集のキーボード操作。ノンリニア編集ソフトの慣習に合わせ、
/// **矢印キーは再生位置を動かし、I/O/L がその位置にハンドルを置く**。
/// ハンドルそのものを矢印で動かす方式にしていないのは、「今どのハンドルが
/// 選ばれているか」という見えない状態を持たずに済み、かつ「見たいコマまで
/// 送ってから確定する」という編集の流れにそのまま乗るため。
private enum TrimKeyCode {
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let space: UInt16 = 49
    static let letterI: UInt16 = 34
    static let letterO: UInt16 = 31
    static let letterL: UInt16 = 37
    static let letterZ: UInt16 = 6
}

extension WallpaperEditorController {
    func installKeyMonitorIfNeeded() {
        guard keyEventMonitor == nil else {
            return
        }
        guard isActive, isSubModeActive else {
            return
        }

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, isActive, isSubModeActive else {
                return event
            }
            // テキストフィールド編集中(時刻の直接入力、検索欄…)は矢印キーも
            // ⌘Z もそちらのものなので手を出さない。SwiftUI の TextField を
            // 支えるフィールドエディタは NSText のサブクラス。
            if (event.window ?? NSApp.keyWindow)?.firstResponder is NSText {
                return event
            }
            guard draft.assetDuration > 0 else {
                return event
            }
            return handle(event) ? nil : event
        }
    }

    func removeKeyMonitor() {
        guard let monitor = keyEventMonitor else {
            return
        }
        NSEvent.removeMonitor(monitor)
        keyEventMonitor = nil
    }

    /// - Returns: 処理したので食べてよければ true。
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = flags.contains(.command)
        let hasShift = flags.contains(.shift)

        if hasCommand {
            guard event.keyCode == TrimKeyCode.letterZ else {
                return false
            }
            if hasShift {
                redo()
            } else {
                undo()
            }
            return true
        }

        // ⌥/⌃ 付きは他の機能のショートカットかもしれないので触らない。
        guard !flags.contains(.option), !flags.contains(.control) else {
            return false
        }

        switch event.keyCode {
        case TrimKeyCode.left:
            if hasShift {
                stepPlayhead(bySeconds: -1)
            } else {
                stepPlayhead(byFrames: -1)
            }
            return true
        case TrimKeyCode.right:
            if hasShift {
                stepPlayhead(bySeconds: 1)
            } else {
                stepPlayhead(byFrames: 1)
            }
            return true
        case TrimKeyCode.space:
            togglePlayback()
            return true
        case TrimKeyCode.letterI:
            setTrimStartToPlayhead()
            return true
        case TrimKeyCode.letterO:
            setTrimEndToPlayhead()
            return true
        case TrimKeyCode.letterL:
            setLoopStartToPlayhead()
            return true
        default:
            return false
        }
    }
}

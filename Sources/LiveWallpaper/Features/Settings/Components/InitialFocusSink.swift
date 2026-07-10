import AppKit
import SwiftUI

/// ウィンドウが開いた際、AppKitのキービューループが最初に見つけたコントロール
/// (プレイリストメニューなど)へ自動でファーストレスポンダを割り当て、
/// そのコントロールに未操作なのに青いフォーカスリングが付いてしまう問題を避けるための
/// 見えないダミービュー。自身が代わりにファーストレスポンダを引き受ける。
struct InitialFocusSink: NSViewRepresentable {
    final class SinkView: NSView {
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, window.firstResponder === window else {
                    return
                }
                window.makeFirstResponder(self)
            }
        }
    }

    func makeNSView(context: Context) -> SinkView {
        SinkView(frame: .zero)
    }

    func updateNSView(_ nsView: SinkView, context: Context) {}
}

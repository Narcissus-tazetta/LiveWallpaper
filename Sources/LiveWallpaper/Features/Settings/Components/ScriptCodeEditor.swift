import AppKit
import SwiftUI

struct ScriptCodeEditor: NSViewRepresentable {
    @Binding var text: String
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollablePlainDocumentContentTextView()
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.clipsToBounds = true
        let view = scroll.documentView as! NSTextView
        view.allowsUndo = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .textColor
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 8, height: 10)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.usesFindBar = true
        view.delegate = context.coordinator
        view.string = text
        context.coordinator.colorize(view, dark: colorScheme == .dark)
        scroll.documentView = view
        let ruler = ScriptLineRuler(scrollView: scroll, orientation: .verticalRuler)
        ruler.clientView = view
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let view = scroll.documentView as! NSTextView
        if view.string != text {
            view.string = text
            view.undoManager?.removeAllActions()
        }
        context.coordinator.colorize(view, dark: colorScheme == .dark)
        scroll.verticalRulerView?.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScriptCodeEditor
        private var previousText: String?
        private var previousDark: Bool?
        private var isColorizing = false
        init(_ parent: ScriptCodeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !isColorizing else { return }
            let view = notification.object as! NSTextView
            parent.text = view.string
            colorize(view, dark: parent.colorScheme == .dark)
            view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        func colorize(_ view: NSTextView, dark: Bool) {
            guard previousText != view.string || previousDark != dark else { return }
            previousText = view.string
            previousDark = dark
            isColorizing = true
            defer { isColorizing = false }
            let storage = view.textStorage!
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: full)
            for token in JavaScriptSyntax.tokens(in: view.string) {
                storage.addAttribute(.foregroundColor, value: color(token.kind, dark: dark), range: token.range)
            }
            storage.endEditing()
            view.typingAttributes = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.textColor]
        }

        private func color(_ kind: JavaScriptSyntax.Kind, dark: Bool) -> NSColor {
            let rgb: (CGFloat, CGFloat, CGFloat)
            switch kind {
            case .keyword: rgb = dark ? (0.82, 0.56, 1) : (0.48, 0.15, 0.62)
            case .literal: rgb = dark ? (1, 0.64, 0.78) : (0.62, 0.15, 0.37)
            case .number: rgb = dark ? (0.46, 0.8, 1) : (0.05, 0.36, 0.6)
            case .string, .regex: rgb = dark ? (1, 0.73, 0.46) : (0.62, 0.25, 0.1)
            case .comment: rgb = dark ? (0.6, 0.67, 0.65) : (0.37, 0.44, 0.41)
            case .function: rgb = dark ? (0.52, 0.9, 0.7) : (0, 0.4, 0.26)
            case .property: rgb = dark ? (0.6, 0.77, 1) : (0.16, 0.32, 0.57)
            }
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
    }
}

private final class ScriptLineRuler: NSRulerView {
    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        ruleThickness = 44
        // AppKit no longer clips NSViews by default; a ruler dirty rect can extend over sibling controls.
        clipsToBounds = true
    }
    required init(coder: NSCoder) { super.init(coder: coder) }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        guard let text = scrollView?.documentView as? NSTextView,
              let layout = text.layoutManager, let container = text.textContainer else { return }
        let string = text.string as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor
        ]
        var index = 0
        var number = 1
        while index < string.length {
            let glyph = layout.glyphIndexForCharacter(at: index)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = line.minY + text.textContainerInset.height - text.visibleRect.minY
            if y > bounds.maxY { break }
            if y + line.height >= 0 {
                ("\(number)" as NSString).draw(at: NSPoint(x: 5, y: y), withAttributes: attributes)
            }
            let range = string.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(range)
            number += 1
        }
        if string.length == 0 || text.string.hasSuffix("\n") {
            let glyphs = layout.glyphRange(for: container)
            let y = layout.extraLineFragmentRect.minY + text.textContainerInset.height - text.visibleRect.minY
            if glyphs.length == 0 || y < bounds.maxY {
                ("\(number)" as NSString).draw(at: NSPoint(x: 5, y: y), withAttributes: attributes)
            }
        }
    }
}

import AppKit
import SwiftUI

private final class ClickableSearchTextField: NSTextField {
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

struct LibrarySearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = ClickableSearchTextField(string: "")
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 11)
        field.alignment = .left
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.field = nsView

        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }

        context.coordinator.syncFocus(for: nsView, isFocused: isFocused)
        context.coordinator.refreshClickOutsideMonitor(for: nsView)
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        coordinator.stopClickOutsideMonitor()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        @Binding var isFocused: Bool
        private var isUpdatingFocus = false
        private var clickOutsideMonitor: Any?
        weak var field: NSTextField?

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            _text = text
            _isFocused = isFocused
        }

        deinit {
            stopClickOutsideMonitor()
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else {
                return
            }
            text = field.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            guard !isUpdatingFocus else {
                return
            }
            isFocused = true
            refreshClickOutsideMonitor(for: field)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard !isUpdatingFocus else {
                return
            }
            isFocused = false
            stopClickOutsideMonitor()
        }

        func syncFocus(for field: NSTextField, isFocused: Bool) {
            let isEditing = isFieldEditing(field)
            guard isFocused != isEditing else {
                refreshClickOutsideMonitor(for: field)
                return
            }

            isUpdatingFocus = true
            defer { isUpdatingFocus = false }

            if isFocused {
                field.window?.makeFirstResponder(field)
            } else if isEditing {
                field.window?.makeFirstResponder(nil)
            }
            refreshClickOutsideMonitor(for: field)
        }

        func refreshClickOutsideMonitor(for field: NSTextField?) {
            guard let field else {
                stopClickOutsideMonitor()
                return
            }

            if isFieldEditing(field) || isFocused {
                startClickOutsideMonitor(for: field)
            } else {
                stopClickOutsideMonitor()
            }
        }

        func startClickOutsideMonitor(for field: NSTextField) {
            guard clickOutsideMonitor == nil else {
                return
            }

            clickOutsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
                [weak self] event in
                self?.handleOutsideClick(event, field: field)
                return event
            }
        }

        func stopClickOutsideMonitor() {
            if let clickOutsideMonitor {
                NSEvent.removeMonitor(clickOutsideMonitor)
                self.clickOutsideMonitor = nil
            }
        }

        private func handleOutsideClick(_ event: NSEvent, field: NSTextField) {
            guard self.field === field else {
                return
            }
            guard isFieldEditing(field) || isFocused else {
                return
            }
            guard let window = field.window, event.window === window else {
                return
            }

            if isEventInsideField(event, field: field) {
                return
            }

            dismissFocus(for: field)
        }

        private func isFieldEditing(_ field: NSTextField) -> Bool {
            field.currentEditor() != nil || field.window?.firstResponder === field
        }

        private func isEventInsideField(_ event: NSEvent, field: NSTextField) -> Bool {
            let location = event.locationInWindow

            if let editor = field.currentEditor() {
                let editorFrame = editor.convert(editor.bounds, to: nil)
                if editorFrame.contains(location) {
                    return true
                }
            }

            let fieldFrame = field.convert(field.bounds, to: nil)
            if fieldFrame.contains(location) {
                return true
            }

            guard let contentView = field.window?.contentView,
                  let hitView = contentView.hitTest(location)
            else {
                return false
            }

            if hitView === field || hitView === field.currentEditor() {
                return true
            }

            return hitView.isDescendant(of: field)
        }

        private func dismissFocus(for field: NSTextField) {
            isUpdatingFocus = true
            isFocused = false
            field.window?.makeFirstResponder(nil)
            stopClickOutsideMonitor()
            isUpdatingFocus = false
        }
    }
}

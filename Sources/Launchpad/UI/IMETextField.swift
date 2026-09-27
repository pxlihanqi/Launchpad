import AppKit
import SwiftUI

/// A real `NSTextField` (field editor based) so the system input method works:
/// Chinese/Japanese composition, candidate window, emoji picker, ⌘A/⌘C/⌘V.
/// SwiftUI's own text input cannot be used here because the overlay handles key
/// events itself, which would bypass the input method.
struct IMETextField: NSViewRepresentable {
    enum Role { case search, folderName, plain }

    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat
    var alignment: NSTextAlignment = .left
    var isFocused: Bool
    var role: Role = .plain
    var onCommit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onChange: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.textColor = .white
        field.font = .systemFont(ofSize: fontSize)
        field.alignment = alignment
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.45),
                         .font: NSFont.systemFont(ofSize: fontSize)]
        )
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        if role == .search { FieldFocus.searchField = field }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            // Never fight the input method while it is composing.
            let editor = nsView.currentEditor() as? NSTextView
            if editor?.hasMarkedText() != true {
                nsView.stringValue = text
                editor?.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            }
        }
        nsView.font = .systemFont(ofSize: fontSize)
        nsView.alignment = alignment
        nsView.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.45),
                         .font: NSFont.systemFont(ofSize: fontSize)]
        )
        // The insertion point is drawn by the field editor.
        if let editor = nsView.currentEditor() as? NSTextView {
            editor.insertionPointColor = .white
        }

        let window = nsView.window
        if isFocused {
            if window?.firstResponder !== nsView.currentEditor() {
                DispatchQueue.main.async {
                    guard nsView.window != nil else { return }
                    nsView.window?.makeFirstResponder(nsView)
                }
            }
        } else if let editor = nsView.currentEditor(), window?.firstResponder === editor {
            window?.makeFirstResponder(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: IMETextField

        init(_ parent: IMETextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // While the input method is composing (拼音未选词), the field holds
            // marked text like "weixin". Filtering on that would show nothing,
            // so wait for the commit — that fires another change notification.
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() {
                return
            }
            // Writing through the binding is what keeps the model in sync; this
            // fires for input method commits as well as plain typing.
            parent.text = field.stringValue
            parent.onChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onCommit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.insertTab(_:)):
                return false
            default:
                return false
            }
        }
    }
}

/// Keeps a weak reference to the live search field so the overlay can focus it.
@MainActor
enum FieldFocus {
    static weak var searchField: NSTextField?

    static func focusSearch() {
        guard let field = searchField, let window = field.window else { return }
        window.makeFirstResponder(field)
    }

    static func isSearchEditing() -> Bool {
        guard let field = searchField, let window = field.window else { return false }
        return window.firstResponder === field.currentEditor()
    }

    /// True while an input method is composing (candidate window open).
    static func isComposing(in window: NSWindow?) -> Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.hasMarkedText()
    }
}

import SwiftUI
import AppKit

/// The window's one search field, hosted as a plain toolbar item.
///
/// `.searchable(placement: .toolbar)` put the field wherever the toolbar had
/// room: on the Library tab it sat at the trailing edge, but on a reader tab
/// — where every library tool is gone — it slid left and docked next to the
/// tab strip. A regular toolbar item stays where it's declared, and lets the
/// field change what it searches with the active tab (library filter on
/// Library, find-in-PDF in a reader).
///
/// Live text comes from the delegate; the field's *action* only fires on
/// Return (`sendsWholeSearchString`), which the reader uses as "next match".
struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String
    /// Bumped by ⌘F. A change moves keyboard focus into the field.
    var focusToken: Int
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.sendsWholeSearchString = true      // action on Return only
        field.sendsSearchStringImmediately = false
        field.placeholderString = prompt
        field.stringValue = text
        // Toolbar items size to their content; without this the field
        // collapses to its (tiny) intrinsic width.
        field.widthAnchor.constraint(equalToConstant: 230).isActive = true
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != prompt { field.placeholderString = prompt }
        guard context.coordinator.lastFocusToken != focusToken else { return }
        context.coordinator.lastFocusToken = focusToken
        // Async: the focus request arrives mid-update, when the field may not
        // be in the window yet.
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ToolbarSearchField
        var lastFocusToken: Int

        init(_ parent: ToolbarSearchField) {
            self.parent = parent
            self.lastFocusToken = parent.focusToken
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        /// Escape empties the field. NSSearchField clears its own text but
        /// doesn't tell the delegate, so the binding would keep the stale
        /// query (and the reader would keep its highlights).
        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            textView.string = ""
            parent.text = ""
            control.window?.makeFirstResponder(nil)
            return true
        }

        @objc func submit(_ sender: NSSearchField) {
            parent.text = sender.stringValue
            parent.onSubmit()
        }
    }
}

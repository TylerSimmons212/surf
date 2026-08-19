import AppKit
import SwiftUI

/// The palette's input, as an `NSTextField` rather than SwiftUI's.
///
/// The colour has to be certain. SwiftUI's field takes its text colour from
/// the environment, and that doesn't survive the field editor: once focused —
/// which this field always is — what you type is drawn by an `NSTextView` that
/// never receives the style, so typed text came out dimmer than the
/// placeholder no matter which combination of `foregroundStyle`, `prompt:` and
/// ordering was used.
///
/// Here the colours are set on the control itself, so there is nothing left to
/// negotiate: `labelColor` for what you type, `placeholderTextColor` for the
/// hint. Both follow light and dark automatically.
struct SurfTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont
    /// Selects the existing text on appear, so typing replaces the URL you're
    /// standing on — the same as every other address bar.
    var selectsAllOnFocus = true
    /// Bumped to bring focus back to a field that is already on screen.
    ///
    /// The field takes focus when it gains a window, which covers the first
    /// appearance and nothing after it. ⌘L on a screen whose field never went
    /// away needs to say so somehow, and a token is the version of that which
    /// survives a re-render — a Bool would have to be set and unset, and the
    /// unset is a second render that can arrive first.
    var focusToken: Int = 0

    var onSubmit: () -> Void = {}
    /// -1 for up, +1 for down: the suggestion list's keyboard.
    var onMove: (Int) -> Void = { _ in }
    var onCancel: () -> Void = {}
    /// Tab. Returns true when it was handled — otherwise the key falls through
    /// to AppKit and moves focus to the next view, which is what Tab normally
    /// does and exactly wrong inside a completing prompt.
    var onTab: () -> Bool = { false }

    func makeNSView(context: Context) -> NSTextField {
        let field = FirstResponderTextField(string: text)
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderAttributedString = Self.placeholderString(placeholder, font: font)
        field.selectsAllOnFocus = selectsAllOnFocus
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            // After the current update: making a view first responder from
            // inside SwiftUI's own render is how you get the caret in the right
            // place and the selection in the wrong one.
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                if selectsAllOnFocus { field.currentEditor()?.selectAll(nil) }
            }
        }
        // Only when it actually differs: assigning during editing would move
        // the caret to the end on every keystroke.
        if field.stringValue != text {
            field.stringValue = text
        }
        if field.font != font {
            field.font = font
        }
        field.placeholderAttributedString = Self.placeholderString(placeholder, font: font)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Dimmer and lighter than the typed text: the hint is a label, not content.
    private static func placeholderString(_ text: String, font: NSFont) -> NSAttributedString {
        let lighter = NSFont.systemFont(ofSize: font.pointSize, weight: .regular)
        return NSAttributedString(
            string: text,
            attributes: [.font: lighter, .foregroundColor: NSColor.placeholderTextColor]
        )
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SurfTextField
        var lastFocusToken = 0

        init(_ parent: SurfTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        /// Enter, arrows and escape have to be intercepted here: they're
        /// editing commands, and the field editor consumes them before any
        /// SwiftUI key handler would see them.
        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
            case #selector(NSResponder.insertTab(_:)):
                // Only swallowed when something was completed; otherwise Tab
                // keeps its normal meaning and moves focus on.
                return parent.onTab()
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            default:
                return false
            }
            return true
        }
    }
}

/// Takes focus as soon as it has a window. The palette exists to be typed into,
/// so it should never need a click first.
private final class FirstResponderTextField: NSTextField {
    var selectsAllOnFocus = true
    private var hasTakenFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !hasTakenFocus else { return }
        hasTakenFocus = true
        // Next tick: the view is in the hierarchy but the window may not have
        // finished making itself key, and first responder wouldn't stick.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window.makeFirstResponder(self)
            if let editor = self.currentEditor() {
                editor.selectedRange = selectsAllOnFocus
                    ? NSRange(location: 0, length: stringValue.count)
                    : NSRange(location: stringValue.count, length: 0)
            }
        }
    }
}

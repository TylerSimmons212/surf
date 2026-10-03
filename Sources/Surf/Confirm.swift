import AppKit

/// A destructive confirmation, shaped the same way every time.
///
/// Two of these exist now — deleting an island and signing one out — and the
/// shape matters more than it looks. The destructive button is added first so
/// it sits where the default would, and then the key equivalents are swapped so
/// **Return cancels** and the dangerous button has to be aimed at with the
/// pointer. That detail is the whole reason this is a function rather than two
/// hand-rolled alerts: it is exactly the line a second copy omits, and omitting
/// it turns "press Return to get rid of this dialog" into "erase every login in
/// this island".
///
/// `runModal()` is app-modal and blocks, so callers reached from a menu item
/// must get off the menu's tracking loop first — a `Task { @MainActor in … }`
/// inside the item's action is enough. An alert put up while a menu session is
/// still unwinding is a window fighting a tracking loop for events.
@MainActor
enum Confirm {

    /// True when the user chose to go ahead.
    ///
    /// - Parameters:
    ///   - question: the title, naming the specific thing at stake.
    ///   - consequence: what will be lost, and whether it can be undone.
    ///   - action: the destructive button's own verb, never "OK".
    static func destructive(
        _ question: String, _ consequence: String, action: String
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = consequence
        alert.alertStyle = .warning
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        // So Return cancels and the destructive button has to be aimed at.
        alert.buttons.last?.keyEquivalent = "\r"
        alert.buttons.first?.keyEquivalent = ""
        return alert.runModal() == .alertFirstButtonReturn
    }
}

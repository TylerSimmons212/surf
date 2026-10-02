import AppKit
import SwiftUI

/// The AppKit menu plumbing SwiftUI does not hand out.
///
/// A short list of choices where you pick one is a menu, and macOS has a control
/// for that with keyboard navigation, submenus and edge flipping already in it.
/// Reaching for it from SwiftUI costs three small things every time: a real
/// `NSView` to position against, a closure where AppKit wants a target and a
/// selector, and — for anything the sidebar spawns — a hold so the panel cannot
/// collapse out from under the menu while it tracks.
///
/// All three lived inside `DownloadMenu.swift` while it was the only such menu.
/// They are here now because the island menu needs them too, and because the
/// hold has to be taken and released in exactly one way. Two hand-written copies
/// of that pair of calls is one copy too many of something that fails silently.

// MARK: - Items

/// An `NSMenuItem` that runs a closure.
///
/// AppKit wants a target and a selector; every call site wants a closure. The
/// item is its own target, which keeps the two ends of each menu entry on one
/// line instead of scattered across a switch on `sender.tag`.
///
/// Being its own target is also the only arrangement that cannot quietly break.
/// `NSMenuItem.target` is weak, so a separate target object has to be kept alive
/// by hanging it off `representedObject` — and forgetting that gives a menu
/// whose every row does nothing, with no crash and no warning to say why.
final class ActionMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not from a nib") }

    @objc private func fire() { run() }
}

// MARK: - Building

extension NSMenu {

    /// A row that runs a closure.
    @discardableResult
    func addAction(_ title: String, _ run: @escaping () -> Void) -> ActionMenuItem {
        let item = ActionMenuItem(title, run)
        addItem(item)
        return item
    }

    /// A row that opens another menu on hover.
    ///
    /// The child is built by the closure rather than returned to the caller, so
    /// a submenu cannot be left unattached — which draws as a row that looks
    /// like it should expand and doesn't.
    @discardableResult
    func addSubmenu(_ title: String, _ build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        build(submenu)
        item.submenu = submenu
        addItem(item)
        return item
    }

    /// A line the menu states rather than offers.
    ///
    /// No action, which does two jobs at once: `autoenablesItems` dims anything
    /// it cannot find a target for, and keyboard navigation skips it. So a note
    /// needs no `isEnabled = false` and cannot be arrowed onto and pressed.
    ///
    /// Worth having because some of what a menu knows is an answer rather than a
    /// command. "No cookies in this island" is the whole reason somebody opened
    /// it, and a menu that can only offer actions has to either leave that
    /// unsaid or disable the row that would have said it.
    func addNote(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        addItem(item)
    }
}

// MARK: - Showing

extension NSMenu {

    /// Tracks under `anchor`, with the sidebar held open for the whole of it.
    ///
    /// `popUp` runs its own event loop and does not return until the menu
    /// closes, which is what makes the pair of calls around it correct rather
    /// than hopeful: there is no instant in which the menu is up and the hold is
    /// not, and no dismissal path that can skip the release the way a popover's
    /// can.
    ///
    /// The hold is needed even though an `NSMenu` lives in its own window and
    /// would survive the sidebar collapsing. The anchor is *in* the sidebar, so a
    /// panel that slides away underneath a tracking menu takes with it the thing
    /// the menu is positioned against.
    ///
    /// False when there is nowhere to hang the menu, so a caller with a
    /// reasonable fallback can take it instead of showing nothing.
    ///
    /// `@MainActor` because `NSMenu` itself is not: AppKit's own annotations
    /// leave this extension nonisolated, and both the anchor and the hold are
    /// main-actor state.
    @discardableResult
    @MainActor
    func popUp(below anchor: MenuAnchor, holding hold: SidebarHold, reason: String) -> Bool {
        guard let view = anchor.view, view.window != nil else { return false }

        hold.set(reason, true)
        defer { hold.set(reason, false) }

        popUp(
            positioning: nil,
            // The view is unflipped, so zero is its bottom edge. A few points
            // below that leaves the gap a menu normally has from its button.
            at: NSPoint(x: 0, y: -5),
            in: view
        )
        return true
    }
}

// MARK: - Anchoring

/// A reference to the `NSView` a menu is positioned in.
@MainActor
final class MenuAnchor {
    weak var view: NSView?
}

/// Puts a real view behind a SwiftUI button, because `NSMenu` is positioned in
/// one and SwiftUI does not hand its own out.
struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }

    /// Never takes a click. It sits over the same rectangle as the button, and
    /// an ordinary `NSView` hit-tests to itself, which would swallow every press
    /// the button exists for.
    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

import AppKit
import WebKit

/// The page's web view, subclassed for one reason.
///
/// `willOpenMenu(_:with:)` is the only hook AppKit offers into WebKit's context
/// menu on macOS, and it is an override rather than a delegate callback — so
/// having Surf's own items in the page menu costs exactly one subclass.
final class SurfWebView: WKWebView {
    /// Weak, and deliberately: the tab owns the view.
    weak var tab: Tab?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        tab?.willOpenContextMenu(menu, with: event)
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        tab?.contextMenuDidClose()
    }
}

/// An `NSMenuItem` that runs a closure.
///
/// AppKit wants a target and a selector; every call site here wants a closure.
/// The item is its own target, which keeps the two ends of each menu entry on
/// one line instead of scattered across a switch on `sender.tag`.
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

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

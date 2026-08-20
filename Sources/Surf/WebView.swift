import SwiftUI
import WebKit

/// Hosts the engine's long-lived `WKWebView`. This intentionally does no
/// configuration of its own — the engine owns the web view's lifetime, and this
/// is only the bridge that puts it on screen.
///
/// One container serves every tab, and it is deliberately *not* rebuilt when the
/// selection changes. Giving the hosting view an `.id` per tab was the obvious
/// way to write this, and it meant every switch destroyed the container and tore
/// a live web view out of the window to put it back a moment later — which is
/// the classic way to make WebKit drop its layers and flash white.
struct WebView: NSViewRepresentable {
    let webView: WKWebView

    /// Width of the leading strip where clicks must *not* reach the page,
    /// because chrome is floating over it. Zero whenever nothing overlaps.
    ///
    /// SwiftUI draws the floating sidebar above the page, but AppKit decides
    /// who gets the click, and it asks real views before anything SwiftUI has
    /// merely drawn. A `WKWebView` is a real view; a button painted over it is
    /// not, so the page wins every click in the overlap. The tab list escapes
    /// this only because `ScrollView` happens to be AppKit-backed too — which
    /// is why the list worked while the controls above and below it didn't.
    var chromeInset: CGFloat = 0

    /// Makes the page refuse input entirely, rather than just in the chrome
    /// strip. Set while a tab is being dragged, so the split drop zones can
    /// receive it.
    ///
    /// A `WKWebView` registers itself as a dragging destination — pages take
    /// dropped links and text — and AppKit offers the drag to the deepest
    /// registered view under the pointer. A SwiftUI drop target merely *drawn*
    /// over the page therefore never sees it: same reason a button drawn over
    /// the page doesn't get clicks, which is what `chromeInset` already exists
    /// to solve. Standing down for the length of the drag hands the whole area
    /// to the zones above; the page is not a drop target the user is aiming at
    /// while they're carrying a tab.
    var isInert: Bool = false

    func makeNSView(context: Context) -> WebViewContainer {
        let container = WebViewContainer()
        container.present(webView)
        return container
    }

    func updateNSView(_ container: WebViewContainer, context: Context) {
        container.present(webView)
        container.chromeInset = chromeInset
        container.isInert = isInert
    }
}

/// Wraps the web views so the page can be told to ignore clicks in the strip the
/// chrome occupies, and so switching tabs costs a visibility flip rather than a
/// hierarchy mutation.
final class WebViewContainer: NSView {
    var chromeInset: CGFloat = 0

    /// See `WebView.isInert`. Stands the page down for the length of a tab drag.
    var isInert = false

    /// Recently shown web views, most recent last, all still mounted.
    ///
    /// Keeping the outgoing page mounted is the whole point: flipping between
    /// two tabs is the common case, and a view that never leaves the window
    /// never has to rebuild its layers to come back. Bounded because "mounted"
    /// isn't free either — past this many, the coldest one is detached and pays
    /// the full cost if it's ever shown again.
    private var mounted: [WKWebView] = []
    private static let mountLimit = 3

    /// Shows `webView`, mounting it if this is the first time.
    func present(_ webView: WKWebView) {
        // The pop-out panel borrows the same web view, and it can only live in
        // one hierarchy. Claiming it back here would tear it out of the panel
        // mid-flight; it returns on its own when the pop-out is restored.
        if let current = webView.superview, !(current is WebViewContainer) { return }

        if webView.superview !== self {
            webView.removeFromSuperview()
            webView.frame = bounds
            addSubview(webView)
        }

        // Drop anything that has left on its own — a closed tab detaches its
        // own view in `teardown`, and a popped-out one is adopted by the panel.
        // Without this the container would go on owning a torn-down web view.
        mounted.removeAll { $0.superview !== self }

        // Move to the most-recent end, then hide everything else. Hiding rather
        // than removing is what makes the return trip free.
        mounted.removeAll { $0 === webView }
        mounted.append(webView)

        for view in mounted where view !== webView {
            view.isHidden = true
        }
        webView.isHidden = false

        evictColdest(keeping: webView)
    }

    /// Detaches the least recently shown pages once the set outgrows its limit.
    private func evictColdest(keeping current: WKWebView) {
        while mounted.count > Self.mountLimit {
            let coldest = mounted.removeFirst()
            guard coldest !== current else {
                // Can't happen while the limit is above zero — the current view
                // was just appended — but re-appending is the safe answer if it
                // ever does, rather than unmounting what we're showing.
                mounted.append(coldest)
                return
            }
            coldest.isHidden = false  // so it isn't left hidden if remounted
            coldest.removeFromSuperview()
        }
    }

    /// Explicit rather than autoresizing: the container is laid out at zero size
    /// before SwiftUI gives it a real one, and a mask scaling from zero stays
    /// at zero.
    override func layout() {
        super.layout()
        subviews.forEach { $0.frame = bounds }
    }

    /// Declines the click outright rather than forwarding it. Returning nil
    /// makes AppKit carry on looking, and what it finds next is the SwiftUI
    /// content that was drawn there — which is what the user aimed at.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isInert else { return nil }
        guard chromeInset > 0 else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        guard local.x > chromeInset else { return nil }
        return super.hitTest(point)
    }
}

import SwiftUI
import WebKit

/// Hosts the engine's long-lived `WKWebView`. This intentionally does no
/// configuration of its own — the engine owns the web view's lifetime, and this
/// is only the bridge that puts it on screen.
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

    func makeNSView(context: Context) -> WebViewContainer {
        let container = WebViewContainer()
        container.embed(webView)
        return container
    }

    func updateNSView(_ container: WebViewContainer, context: Context) {
        container.embed(webView)
        container.chromeInset = chromeInset
    }
}

/// Wraps the web view so the page can be told to ignore clicks in the strip the
/// chrome occupies.
final class WebViewContainer: NSView {
    var chromeInset: CGFloat = 0

    func embed(_ webView: WKWebView) {
        guard webView.superview !== self else { return }
        // The pop-out panel borrows the same web view, and it can only live in
        // one hierarchy. Claiming it back here would tear it out of the panel
        // mid-flight; it returns on its own when the pop-out is restored.
        if let current = webView.superview, !(current is WebViewContainer) { return }
        webView.removeFromSuperview()
        webView.frame = bounds
        addSubview(webView)
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
        guard chromeInset > 0 else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        guard local.x > chromeInset else { return nil }
        return super.hitTest(point)
    }
}

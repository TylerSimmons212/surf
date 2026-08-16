import SwiftUI
import WebKit

/// Hosts the engine's long-lived `WKWebView`. This intentionally does no
/// configuration of its own — the engine owns the web view's lifetime, and this
/// is only the bridge that puts it on screen.
struct WebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

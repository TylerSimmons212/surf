import Foundation
import GlassCore
import Observation
import WebKit

/// Owns the single `WKWebView` and mirrors its state into observable properties.
///
/// The web view is created once and lives for the app's lifetime — recreating it
/// per navigation would throw away the back/forward list and the process pool.
@Observable
@MainActor
final class BrowserEngine: NSObject {

    /// Home = the centered search field; browsing = chrome + page.
    enum Mode { case home, browsing }

    private(set) var mode: Mode = .home

    /// What the address field displays. Kept separate from the page's real URL
    /// so typing doesn't fight with navigation updating the same string.
    var addressText: String = ""

    private(set) var pageTitle: String = ""
    private(set) var isLoading: Bool = false
    private(set) var progress: Double = 0
    private(set) var canGoBack: Bool = false
    private(set) var canGoForward: Bool = false
    private(set) var lastError: String?

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Lets sites serve their desktop layout and pass basic UA sniffing.
        configuration.applicationNameForUserAgent = "Version/17.0 Safari/605.1.15 Glass/0.1"

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        super.init()

        webView.navigationDelegate = self
        observeWebViewState()
    }

    /// KVO is the only way to track these — `WKNavigationDelegate` has no
    /// callbacks for progress or the back/forward list changing.
    private func observeWebViewState() {
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.progress = webView.estimatedProgress }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.isLoading = webView.isLoading }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoForward = webView.canGoForward }
            },
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                // Note: the title is *not* available at `didFinish` — it lands
                // shortly after, which is why this is observed rather than read.
                MainActor.assumeIsolated { self?.pageTitle = webView.title ?? "" }
            },
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    // Server redirects and in-page navigation change the URL
                    // without us asking, so the field follows the web view.
                    if let url = webView.url { self?.addressText = url.absoluteString }
                }
            },
        ]
    }

    // MARK: - Actions

    func submit(_ input: String) {
        guard let url = URLResolver.resolve(input) else { return }
        lastError = nil
        mode = .browsing
        webView.load(URLRequest(url: url))
    }

    func reload() {
        lastError = nil
        webView.reload()
    }

    func stop() { webView.stopLoading() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    /// Returns to the search screen without tearing down the web view, so
    /// going back into a page keeps history intact.
    func goHome() {
        mode = .home
        addressText = ""
        lastError = nil
    }
}

// MARK: - WKNavigationDelegate

extension BrowserEngine: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastError = nil
        if ProcessInfo.processInfo.environment["GLASS_URL"] != nil {
            fputs("[glass] loaded \(webView.url?.absoluteString ?? "?") — \"\(webView.title ?? "")\"\n", stderr)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        report(error)
    }

    private func report(_ error: Error) {
        let nsError = error as NSError
        // Cancellation isn't a failure — it's what every interrupted load emits.
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else {
            return
        }
        lastError = error.localizedDescription
        if ProcessInfo.processInfo.environment["GLASS_URL"] != nil {
            fputs("[glass] failed — \(error.localizedDescription)\n", stderr)
        }
    }
}

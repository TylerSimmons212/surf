import Foundation
import GlassCore
import Observation
import WebKit

/// A single tab: one `WKWebView` plus the observable mirror of its state.
///
/// Each tab owns its web view for its whole lifetime. Recreating the view on
/// navigation would discard the back/forward list, and sharing one view between
/// tabs would mean re-loading a page every time the user switches.
@Observable
@MainActor
final class Tab: NSObject, Identifiable {

    /// Home = the centered search field; browsing = chrome + page. This is
    /// per-tab, so a new tab opens on the search screen while others keep pages.
    enum Mode { case home, browsing }

    nonisolated let id = UUID()

    private(set) var mode: Mode = .home

    /// What the address field shows. Held separately from the page's real URL so
    /// mid-edit typing isn't overwritten by an unrelated navigation.
    var addressText: String = ""

    private(set) var pageTitle: String = ""
    private(set) var isLoading: Bool = false
    private(set) var progress: Double = 0
    private(set) var canGoBack: Bool = false
    private(set) var canGoForward: Bool = false
    private(set) var lastError: String?

    @ObservationIgnored let webView: WKWebView
    /// Weak: the session owns its tabs, so a strong link back would retain-cycle.
    @ObservationIgnored weak var session: BrowserSession?

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// `configuration` is non-nil only when WebKit hands us one for a popup or
    /// `target="_blank"` link — those must use the configuration WebKit supplies.
    init(configuration: WKWebViewConfiguration? = nil) {
        let config = configuration ?? WKWebViewConfiguration()
        if configuration == nil {
            // Shared by default, so cookies and logins carry across tabs.
            config.websiteDataStore = .default()
            config.applicationNameForUserAgent = "Version/17.0 Safari/605.1.15 Glass/0.1"
            // Left at the default (false): scripted `window.open` without a
            // user gesture is blocked, while real link clicks still open tabs.
            // This is the popup blocker.
            config.preferences.javaScriptCanOpenWindowsAutomatically = false
        }

        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        observeWebViewState()
    }

    /// The label shown on the tab chip, degrading gracefully before a title lands.
    var displayTitle: String {
        if !pageTitle.isEmpty { return pageTitle }
        if mode == .home { return "New Tab" }
        return webView.url?.host ?? "Loading…"
    }

    // MARK: - Restore

    /// Set on a restored tab and consumed the first time it's shown. Restoring
    /// every tab at launch would fire N page loads at once; this defers each
    /// one until the tab is actually looked at.
    @ObservationIgnored private var pendingRestore: PersistedTab?

    var isAwaitingRestore: Bool { pendingRestore != nil }

    /// Populates the visible state from disk without loading anything yet, so
    /// the sidebar shows real titles immediately on launch.
    func prepareRestore(from persisted: PersistedTab) {
        pendingRestore = persisted
        pageTitle = persisted.title
        addressText = persisted.url ?? ""
        if persisted.isRestorable { mode = .browsing }
    }

    /// Called when a restored tab is first displayed.
    func activateRestoreIfNeeded() {
        guard let persisted = pendingRestore else { return }
        pendingRestore = nil

        let fallbackURL = persisted.url.flatMap(URL.init(string:))

        if let state = persisted.interactionState {
            // Restores back/forward history and scroll position, not just the URL.
            webView.interactionState = state
        }

        // WebKit silently ignores an interaction state it doesn't recognise
        // (different version, corrupt blob). Without this net, the tab would
        // sit permanently blank.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard webView.url == nil, let fallbackURL else { return }
            debugLog("interaction state rejected, falling back to \(fallbackURL)")
            webView.load(URLRequest(url: fallbackURL))
        }

        if persisted.interactionState == nil, let fallbackURL {
            webView.load(URLRequest(url: fallbackURL))
        }
    }

    func snapshot() -> PersistedTab {
        // A tab restored but never opened still has an empty web view; hand
        // back what we loaded so its history survives another quit.
        if let pendingRestore { return pendingRestore }
        return PersistedTab(
            url: webView.url?.absoluteString ?? (mode == .browsing ? addressText : nil),
            title: pageTitle,
            interactionState: webView.interactionState as? Data
        )
    }

    /// KVO is the only route to these — `WKNavigationDelegate` has no callbacks
    /// for progress or for the back/forward list changing, and the page title
    /// isn't populated yet when `didFinish` fires.
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
                MainActor.assumeIsolated {
                    self?.pageTitle = webView.title ?? ""
                    self?.session?.scheduleSave()
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = webView.url else { return }
                    self.addressText = url.absoluteString
                    // A popup tab starts in .home but is loaded by WebKit
                    // directly, so the mode has to follow the URL.
                    if self.mode == .home { self.mode = .browsing }
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

    /// Returns to the search screen without tearing down the web view, so the
    /// page and its history are still there if the user navigates again.
    func goHome() {
        mode = .home
        addressText = ""
        lastError = nil
    }
}

// MARK: - WKNavigationDelegate

extension Tab: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastError = nil
        session?.scheduleSave()
        debugLog("loaded \(webView.url?.absoluteString ?? "?")")
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
        debugLog("failed — \(error.localizedDescription)")
    }
}

// MARK: - WKUIDelegate

extension Tab: WKUIDelegate {

    /// Fired for `target="_blank"` links and `window.open`. Returning a new web
    /// view opens a tab; returning nil silently swallows the click, which is
    /// what a browser without this method does.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let session else { return nil }
        // Must be built with WebKit's configuration, not a fresh one, or the
        // new view won't be linked to the opener.
        let tab = session.addTab(configuration: configuration)
        // No explicit load here — WebKit drives the returned view itself.
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        session?.close(self)
    }
}

/// stderr, so it survives output redirection unbuffered. Gated on the dev
/// `GLASS_URL` env var.
private func debugLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["GLASS_URL"] != nil else { return }
    fputs("[glass] \(message)\n", stderr)
}

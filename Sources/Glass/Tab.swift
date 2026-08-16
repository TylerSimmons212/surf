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
    private(set) var favicon: NSImage?

    /// Nil until the page reports media. Survives pausing, so a paused tab
    /// still shows in the player rather than vanishing mid-track.
    private(set) var media: MediaState?

    /// The colour at the top of the page, used to tint the title strip so the
    /// window chrome belongs to the site rather than sitting apart from it.
    ///
    /// `themeColor` is the site's declared `<meta name="theme-color">` and is
    /// the deliberate choice when present; `underPageBackgroundColor` is
    /// WebKit's read of the actual page background and covers everyone else.
    /// Priority matters. The sampled colour is what the user actually sees
    /// under the strip, so it wins: sites like YouTube render a fixed masthead
    /// over a differently-coloured document, and `underPageBackgroundColor`
    /// reports the document — the wrong answer. The declared theme colour and
    /// the page background are fallbacks for when sampling can't run.
    var topColor: NSColor? {
        guard mode == .browsing else { return nil }
        return sampledTopColor ?? themeColor ?? underPageColor
    }

    private var themeColor: NSColor?
    private var underPageColor: NSColor?
    private var sampledTopColor: NSColor?
    @ObservationIgnored private var sampleTask: Task<Void, Never>?

    /// Tracks the host the current favicon belongs to, so navigating within a
    /// site doesn't refetch and navigating away clears a now-wrong icon.
    @ObservationIgnored private var faviconHost: String?

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
            // UA TEST
            // Left at the default (false): scripted `window.open` without a
            // user gesture is blocked, while real link clicks still open tabs.
            // This is the popup blocker.
            config.preferences.javaScriptCanOpenWindowsAutomatically = false
            // Lets pages use the Fullscreen API — the fullscreen button on
            // video players does nothing without it. Off by default in
            // WKWebView; Safari has it on.
            config.preferences.isElementFullscreenEnabled = true
        }

        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        installMediaBridge()
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

    /// Never navigated anywhere: safe to discard without losing anything.
    var isBlank: Bool {
        mode == .home && webView.url == nil && pendingRestore == nil
    }

    /// Set once the user (or code) navigates deliberately. A pending restore
    /// must never overwrite that — restoring a tab you've already typed into
    /// would silently throw the new page away.
    @ObservationIgnored private var hasNavigatedExplicitly = false

    /// Populates the visible state from disk without loading anything yet, so
    /// the sidebar shows real titles immediately on launch.
    func prepareRestore(from persisted: PersistedTab) {
        pendingRestore = persisted
        pageTitle = persisted.title
        addressText = persisted.url ?? ""
        if persisted.isRestorable { mode = .browsing }
        // Disk-cached icons mean a restored tab looks complete before it loads.
        if let host = persisted.url.flatMap(URL.init(string:))?.host {
            faviconHost = host
            favicon = FaviconStore.shared.cachedIcon(forHost: host)
        }
    }

    /// Called when a restored tab is first displayed.
    func activateRestoreIfNeeded() {
        guard let persisted = pendingRestore else { return }
        pendingRestore = nil
        guard !hasNavigatedExplicitly else { return }

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
            guard !hasNavigatedExplicitly, webView.url == nil, let fallbackURL else { return }
            debugLog("interaction state rejected, falling back to \(fallbackURL)")
            webView.load(URLRequest(url: fallbackURL))
        }

        if persisted.interactionState == nil, let fallbackURL {
            webView.load(URLRequest(url: fallbackURL))
        }
    }

    // MARK: - Media

    private func installMediaBridge() {
        let controller = webView.configuration.userContentController
        // Popup tabs inherit WebKit's configuration, which may already carry
        // this handler; adding a duplicate name throws.
        controller.removeScriptMessageHandler(forName: MediaBridge.handlerName)
        controller.add(WeakScriptMessageProxy(target: self), name: MediaBridge.handlerName)
        controller.addUserScript(
            WKUserScript(
                source: MediaBridge.script,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .page
            )
        )
    }

    /// Prevents or restores page scrolling while the lens panel is showing.
    func setPageScrollLocked(_ locked: Bool) {
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(
                locked ? MediaBridge.lockScrollScript : MediaBridge.unlockScrollScript,
                arguments: [:], in: nil, contentWorld: .page
            )
        }
    }

    /// The playing video's viewport rectangle, in CSS pixels (== points).
    func measureVideoFrame() async -> CGRect? {
        guard let json = try? await webView.callAsyncJavaScript(
            MediaBridge.measureScript, arguments: [:], in: nil, contentWorld: .page
        ) as? String,
            let v = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Double],
            v.count == 4
        else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    func toggleMediaPlayback() {
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(
                MediaBridge.toggleScript, arguments: [:], in: nil, contentWorld: .page
            )
        }
    }

    /// Releases everything the tab is holding: media, loads, observers, and the
    /// script handler.
    ///
    /// Relying on deallocation isn't enough — a web view whose audio is playing
    /// keeps its content process alive, so a closed tab can keep making noise
    /// long after it's gone from the sidebar.
    func teardown() {
        sampleTask?.cancel()
        observations.forEach { $0.invalidate() }
        observations.removeAll()

        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: MediaBridge.handlerName)

        media = nil

        Task { @MainActor in
            // Pause first for an immediate stop, then navigate away to tear the
            // media elements down for good.
            await webView.pauseAllMediaPlayback()
            await webView.closeAllMediaPresentations()
            webView.load(URLRequest(url: URL(string: "about:blank")!))
        }
    }

    // MARK: - Top colour sampling

    /// Reads the colour actually painted at the top of the viewport.
    ///
    /// Walks up from the topmost element at a few points along the strip until
    /// it finds an opaque background. That handles fixed headers, which is
    /// exactly the case the WebKit-provided colours get wrong.
    private static let topColorScript = """
    return (function () {
      function opaqueColor(el) {
        if (!el) return null;
        const match = getComputedStyle(el).backgroundColor.match(/^rgba?\\(([^)]+)\\)$/);
        if (!match) return null;
        const parts = match[1].split(',').map(Number);
        const alpha = parts.length > 3 ? parts[3] : 1;
        // Near-transparent backgrounds don't determine what's on screen.
        return alpha >= 0.9 ? [parts[0], parts[1], parts[2]] : null;
      }
      // Several x positions: a centred logo or search box can sit on its own
      // background that isn't representative of the whole bar.
      const xs = [Math.floor(innerWidth / 2), 12, Math.max(12, innerWidth - 12)];
      for (const x of xs) {
        let el = document.elementFromPoint(x, 3);
        while (el) {
          const color = opaqueColor(el);
          if (color) return JSON.stringify(color);
          el = el.parentElement;
        }
      }
      const fallback = opaqueColor(document.body) || opaqueColor(document.documentElement);
      return fallback ? JSON.stringify(fallback) : null;
    })();
    """

    /// SPAs repaint well after `didFinish`, so sampling is retried on a short
    /// ladder rather than once.
    private func scheduleTopColorSampling() {
        sampleTask?.cancel()
        sampleTask = Task { @MainActor in
            for delay in [0, 400, 1200] {
                if delay > 0 {
                    try? await Task.sleep(for: .milliseconds(delay))
                }
                guard !Task.isCancelled else { return }
                await sampleTopColor()
            }
        }
    }

    private func sampleTopColor() async {
        guard let json = try? await webView.callAsyncJavaScript(
            Self.topColorScript, arguments: [:], in: nil, contentWorld: .defaultClient
        ) as? String,
            let rgb = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Double],
            rgb.count >= 3
        else { return }

        sampledTopColor = NSColor(
            srgbRed: rgb[0] / 255,
            green: rgb[1] / 255,
            blue: rgb[2] / 255,
            alpha: 1
        )
    }

    // MARK: - Favicon

    /// Reads the page's declared icons and fetches the best one. Cheap when the
    /// host is already cached, which is the common case while browsing a site.
    private func refreshFavicon() async {
        guard let pageURL = webView.url, let host = pageURL.host else { return }

        if let cached = FaviconStore.shared.cachedIcon(forHost: host) {
            favicon = cached
            faviconHost = host
            return
        }
        guard FaviconStore.shared.shouldFetch(forHost: host) else { return }

        // `link.href` is already absolute — the DOM resolves it against the
        // document, so relative paths and <base> tags are handled for free.
        let script = """
        return JSON.stringify(
          Array.from(document.querySelectorAll('link[rel~="icon" i]'))
            .map((l) => ({ href: l.href || '', sizes: l.getAttribute('sizes') || '' }))
        );
        """

        var candidates: [FaviconCandidate] = []
        if let json = try? await webView.callAsyncJavaScript(
            script, arguments: [:], in: nil, contentWorld: .defaultClient
        ) as? String,
           let raw = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]] {
            candidates = raw.map {
                FaviconCandidate(href: $0["href"] ?? "", sizes: $0["sizes"] ?? "")
            }
        }

        var origin = ""
        if let scheme = pageURL.scheme { origin = "\(scheme)://\(host)" }
        guard let href = FaviconPicker.best(from: candidates, origin: origin) else { return }

        let image = await FaviconStore.shared.fetchIcon(from: href, host: host)
        // The tab may have navigated elsewhere during the download.
        guard webView.url?.host == host else { return }
        favicon = image
        faviconHost = host
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
            webView.observe(\.themeColor, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.themeColor = webView.themeColor }
            },
            webView.observe(\.underPageBackgroundColor, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.underPageColor = webView.underPageBackgroundColor }
            },
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    self?.pageTitle = webView.title ?? ""
                    self?.session?.scheduleSave()
                    // Titles arrive after didFinish, so backfill the entry.
                    if let url = webView.url, let title = webView.title {
                        HistoryStore.shared.updateTitle(title, for: url)
                    }
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = webView.url else { return }
                    self.addressText = url.absoluteString
                    // Covers SPA route changes, which never fire didFinish.
                    // Clear first so a stale colour doesn't linger on the new page.
                    self.sampledTopColor = nil
                    self.scheduleTopColorSampling()
                    // The old page's media is gone the moment we navigate.
                    self.media = nil
                    // A popup tab starts in .home but is loaded by WebKit
                    // directly, so the mode has to follow the URL.
                    if self.mode == .home { self.mode = .browsing }
                    // Swap the icon as soon as the host changes, so a stale
                    // favicon never sits next to a different site's title.
                    if url.host != self.faviconHost {
                        self.faviconHost = url.host
                        self.favicon = url.host.flatMap {
                            FaviconStore.shared.cachedIcon(forHost: $0)
                        }
                    }
                }
            },
        ]
    }

    // MARK: - Actions

    func submit(_ input: String) {
        guard let url = URLResolver.resolve(input) else { return }
        hasNavigatedExplicitly = true
        pendingRestore = nil
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
        Task { await refreshFavicon() }
        scheduleTopColorSampling()
        if let url = webView.url {
            HistoryStore.shared.record(url: url, title: webView.title ?? "")
        }
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

    /// A navigation that turns out to be a download — an `<a download>` link,
    /// or any response WebKit won't render inline.
    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        DownloadManager.shared.adopt(download, from: self)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        DownloadManager.shared.adopt(download, from: self)
    }

    /// Tells WebKit to convert a response into a download when it can't be
    /// displayed — `Content-Disposition: attachment`, or an unrenderable type.
    /// Without this the load just fails.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    private func report(_ error: Error) {
        let nsError = error as NSError
        // Cancellation isn't a failure — it's what every interrupted load emits.
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else {
            return
        }
        // 102 is "frame load interrupted by policy change", which is exactly
        // what a navigation becoming a download looks like. The download is
        // running fine; showing an error page over it would be wrong.
        guard !(nsError.domain == "WebKitErrorDomain" && nsError.code == 102) else {
            return
        }
        lastError = error.localizedDescription
        debugLog("failed — \(error.localizedDescription)")
    }
}

// MARK: - WKScriptMessageHandler

extension Tab: WKScriptMessageHandler {
    nonisolated func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == MediaBridge.handlerName else { return }
        let body = message.body
        MainActor.assumeIsolated {
            guard let state = MediaBridge.decode(body) else { return }
            // Media that never started isn't worth showing in the player.
            if state.isPlaying || media != nil { media = state }
        }
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

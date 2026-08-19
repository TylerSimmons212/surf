import Foundation
import SurfCore
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

    /// The home screen's exit. Submitting from home starts the load at once,
    /// but the mode holds at `.home` while the water rises over the screen —
    /// the page is revealed by `completeDive()`, not by the load starting.
    private(set) var isDiving = false
    private(set) var diveStartedAt: Date?

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

    /// The frame the chosen media element lives in.
    ///
    /// Everything the player does — play, pause, seek, and above all measuring
    /// the video's rectangle for the pop-out lens — runs a script inside the
    /// page, and the element it needs only exists in the frame that owns it. On
    /// a page that hosts its player in an iframe, which is most pages that
    /// embed video at all, the main frame has no such element: every one of
    /// those scripts returned early, so Pop Out did nothing whatsoever and gave
    /// no reason for it.
    ///
    /// Deliberately allowed to go stale: a frame that has since navigated makes
    /// `callAsyncJavaScript` throw, which `runInMediaFrame` treats as a cue to
    /// fall back to the main frame rather than as an error.
    private var mediaFrame: WKFrameInfo?

    /// Which element in that frame, so a command can't drift onto a different
    /// one between the row being drawn and the button being pressed.
    private var mediaElementID: String?

    /// What every frame last told us it was holding.
    ///
    /// Keyed by the frame's own generated id rather than by `WKFrameInfo`,
    /// which is neither stable nor hashable. `seenAt` is what lets a frame that
    /// claimed to be playing and then vanished — an advert whose iframe was
    /// torn out mid-play — stop counting; see `liveCandidates`.
    private var mediaFrames:
        [String: (items: [MediaState], frame: WKFrameInfo, seenAt: Date)] = [:]

    /// What this page was seen to request, and which of it was blocked. Emptied
    /// at every commit: the panel answers a question about the page on screen,
    /// and a running total across a session is a number nobody can act on.
    private(set) var blockLog = BlockLog()

    /// Set on a tab WebKit asked for on a page's behalf, rather than one the
    /// user opened. Only these are closed again when nothing arrives in them.
    @ObservationIgnored var wasOpenedByPage = false

    /// Whether any document has ever committed here.
    @ObservationIgnored private var hasCommittedDocument = false

    @ObservationIgnored private var emptyPopupWatchdog: Task<Void, Never>?

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

    /// The web view, built the first time it's genuinely needed.
    ///
    /// A `WKWebView` costs a web content process from the moment it exists, so
    /// building one per tab up front meant restoring a session of fifty tabs
    /// spawned fifty processes before anything was on screen — for tabs whose
    /// pages hadn't loaded and, in most cases, never would that session.
    ///
    /// Touching this property *creates* the view. Anything that only wants to
    /// describe a tab — its address, its title, what to write to disk — must go
    /// through `currentURL` / `snapshot()` instead, or it will quietly wake
    /// every sleeping tab it looks at.
    @ObservationIgnored private var liveWebView: WKWebView?

    /// Whether the tab is currently holding a web view.
    var isLive: Bool { liveWebView != nil }

    var webView: WKWebView {
        if let liveWebView { return liveWebView }
        return buildWebView()
    }

    /// WebKit's own configuration, for a popup or `target="_blank"` link.
    ///
    /// Consumed on first use and dropped: it ties the new view to its opener,
    /// which is right for the view WebKit asked for and wrong for any
    /// replacement built later, after the tab has been asleep.
    @ObservationIgnored private var providedConfiguration: WKWebViewConfiguration?

    /// Weak: the session owns its tabs, so a strong link back would retain-cycle.
    @ObservationIgnored weak var session: BrowserSession?

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// One resident agent per content world. Every question Glass asks this
    /// tab's page goes through one of these, by method name.
    /// Optional for the same reason the view is: a sleeping tab holds neither,
    /// and an agent outliving the view it posts into would be talking to a
    /// released page.
    @ObservationIgnored private var liveIsolatedAgent: PageAgent?
    @ObservationIgnored private var livePageAgent: PageAgent?

    /// Waking accessors, matching `webView` above — asking a sleeping tab a
    /// question is what builds it. `buildWebView()` assigns both alongside the
    /// view, so reaching one of these after it is the same guarantee `webView`
    /// itself makes.
    private var isolatedAgent: PageAgent {
        if let liveIsolatedAgent { return liveIsolatedAgent }
        _ = webView
        return liveIsolatedAgent!
    }
    private var pageAgent: PageAgent {
        if let livePageAgent { return livePageAgent }
        _ = webView
        return livePageAgent!
    }

    /// The island's storage — cookies, local storage, IndexedDB — held for the
    /// tab's whole life.
    ///
    /// On the tab rather than on the configuration, and that is the difference
    /// between this working and appearing to work. `providedConfiguration` is
    /// consumed on first build, so a hibernated tab rebuilds from a *fresh*
    /// configuration — and a store read only off the configuration would revert
    /// to `.default()` there, silently folding the tab's cookies back into the
    /// user's main identity at some arbitrary moment an hour later.
    @ObservationIgnored let dataStore: WKWebsiteDataStore

    /// `configuration` is non-nil only when WebKit hands us one for a popup or
    /// `target="_blank"` link — those must use the configuration WebKit supplies.
    init(dataStore: WKWebsiteDataStore, configuration: WKWebViewConfiguration? = nil) {
        // WebKit's configuration for a popup already carries the opener's
        // store, by construction. Adopt that rather than the island's, so that
        // waking this tab later reproduces exactly what WebKit linked it to
        // rather than something merely equivalent.
        self.dataStore = configuration?.websiteDataStore ?? dataStore
        providedConfiguration = configuration

        super.init()

        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .surfAppearanceChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appearanceSettingsChanged() }
        }

        blockingObserver = NotificationCenter.default.addObserver(
            forName: .surfBlockingChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.blockingRulesChanged() }
        }
    }

    /// Builds the web view and everything that hangs off it.
    ///
    /// Assigns `liveWebView` before wiring anything up, because the helpers
    /// below reach for `webView` — and would otherwise re-enter this and build
    /// a second one.
    @discardableResult
    private func buildWebView() -> WKWebView {
        let config = providedConfiguration ?? WKWebViewConfiguration()
        if providedConfiguration == nil {
            // The island's store, re-read on every build rather than captured
            // once: this is the line hibernation would otherwise undo.
            //
            // Assigned *before* the web view is constructed, because the
            // configuration is copied at construction — assigning afterwards
            // has no effect at all, silently.
            config.websiteDataStore = dataStore
            // Left at the default (false): scripted `window.open` without a
            // user gesture is blocked, while real link clicks still open tabs.
            // This is the popup blocker.
            config.preferences.javaScriptCanOpenWindowsAutomatically = false
            // Lets pages use the Fullscreen API — the fullscreen button on
            // video players does nothing without it. Off by default in
            // WKWebView; Safari has it on.
            config.preferences.isElementFullscreenEnabled = true
        }
        providedConfiguration = nil

        let created = WKWebView(frame: .zero, configuration: config)
        created.allowsBackForwardNavigationGestures = true
        created.allowsMagnification = true
        created.navigationDelegate = self
        created.uiDelegate = self
        // Advertises this web view to Safari's Develop menu. That's the only
        // route to a JavaScript debugger — page scripts run in the WebContent
        // process, and the inspector protocol is private — so it stays on
        // permanently as the escape hatch our own dev tools hand off to.
        //
        // Set outside the `configuration == nil` block deliberately: popup and
        // `target="_blank"` tabs skip that branch, and they need this too.
        created.isInspectable = true

        // Rebuilt with the view, not with the tab: hibernation releases the web
        // view and builds another, and an agent still pointed at the released
        // one would post into nothing.
        liveIsolatedAgent = PageAgent(world: .isolated, webView: created)
        livePageAgent = PageAgent(world: .page, webView: created)

        liveWebView = created

        // Before anything can be loaded into it. A view that starts a page load
        // and gains its rules afterwards has already let the first wave of
        // requests through, which is the wave the ads are in.
        ContentBlocker.shared.apply(to: config)

        installAgents()
        reinstallUserScripts()
        observeWebViewState()

        // Zoom is per-tab and outlives a sleep, so a woken tab comes back at
        // the magnification it was left at.
        if !ZoomSteps.isStandard(zoomLevel) { created.pageZoom = zoomLevel }

        return created
    }

    @ObservationIgnored private var appearanceObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var blockingObserver: (any NSObjectProtocol)?

    /// The page's address as a string.
    ///
    /// Everything outside the tab should ask for this rather than reaching
    /// through to `webView.url`: a tab that hasn't been opened yet — restored
    /// from disk, or asleep — knows perfectly well where it points without
    /// having a web view to ask.
    var currentURL: String? {
        if let url = liveWebView?.url { return url.absoluteString }
        if let pending = pendingRestore?.url { return pending }
        guard mode == .browsing, !addressText.isEmpty else { return nil }
        return addressText
    }

    /// The label shown on the tab chip, degrading gracefully before a title lands.
    ///
    /// Careful not to reach for the web view: this is read for *every* row in
    /// the sidebar, so asking a sleeping tab for its title would wake the whole
    /// session the moment the list drew.
    var displayTitle: String {
        if !pageTitle.isEmpty { return pageTitle }
        if mode == .home { return "New Tab" }
        if let host = currentURL.flatMap(URL.init(string:))?.host { return host }
        return "Loading…"
    }

    // MARK: - Restore

    /// Set on a restored tab and consumed the first time it's shown. Restoring
    /// every tab at launch would fire N page loads at once; this defers each
    /// one until the tab is actually looked at.
    @ObservationIgnored private var pendingRestore: PersistedTab?

    var isAwaitingRestore: Bool { pendingRestore != nil }

    /// The group this tab is filed under, if any.
    ///
    /// Membership lives on the tab rather than in a list on the group, so there
    /// is one copy of it and no way for the two to disagree. What a group *is*,
    /// then, is the run of consecutive tabs naming it — see `TabGrouping`.
    var groupID: UUID?

    /// Set once the user (or code) navigates deliberately. A pending restore
    /// must never overwrite that — restoring a tab you've already typed into
    /// would silently throw the new page away.
    @ObservationIgnored private var hasNavigatedExplicitly = false

    /// Populates the visible state from disk without loading anything yet, so
    /// the sidebar shows real titles immediately on launch.
    func prepareRestore(from persisted: PersistedTab) {
        pendingRestore = persisted
        groupID = persisted.groupID
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

    // MARK: - The page agent

    /// Claims both worlds' channels and injects the agent into every page.
    private func installAgents() {
        let controller = webView.configuration.userContentController
        // Both agent channels, and the events each world reports on its own.
        isolatedAgent.register(on: controller)
        pageAgent.register(on: controller)

        isolatedAgent.onEvent = { [weak self] header, _, _ in
            guard header.domain == "theme", header.event == "mutated" else { return }
            self?.pageDidMutate()
        }
        pageAgent.onEvent = { [weak self] header, data, frame in
            guard let self, header.domain == "media", header.event == "report" else { return }
            guard let event = try? JSONDecoder().decode(
                PageProtocol.Event<MediaReport>.self, from: data
            ) else { return }
            // A whole frame's worth, not one element: which of them the player
            // should show is a judgement, and it belongs in `MediaRanking`.
            receiveMedia(event.payload, from: frame)
        }

        controller.removeScriptMessageHandler(forName: BlockBridge.handlerName)
        controller.add(WeakScriptMessageProxy(target: self), name: BlockBridge.handlerName)
    }

    // MARK: - User scripts

    /// The dev tools bridge, alive only while a panel is open for this tab.
    @ObservationIgnored private(set) var devToolsBridge: DevToolsBridge?

    /// The main document's real response.
    ///
    /// Kept whether or not dev tools is open, because otherwise opening the
    /// panel on a page that has already loaded shows no document row at all —
    /// the list would start at the first subresource, missing the one request
    /// that explains the rest.
    struct DocumentResponse: Sendable {
        var url: String
        var status: Int
        var headers: [String: String]
        var mime: String
    }
    @ObservationIgnored private(set) var lastDocumentResponse: DocumentResponse?

    func attachDevTools(_ bridge: DevToolsBridge) { devToolsBridge = bridge }
    func detachDevTools() { devToolsBridge = nil }

    /// The single owner of this tab's user scripts.
    ///
    /// `WKUserContentController` can add a script but cannot remove *one* —
    /// only `removeAllUserScripts()`. So anything that installs scripts
    /// piecemeal will eventually delete someone else's: attaching dev tools
    /// naively would wipe `MediaBridge.script`, and the media player and
    /// pop-out would die on the next navigation with no error anywhere. Every
    /// install goes through here instead, and rebuilds the whole set.
    func reinstallUserScripts() {
        guard let live = liveWebView else { return }
        let target = ThemePreferences.isEnabled ? AppearanceController.resolved : nil
        PageScripts.install(
            on: live.configuration.userContentController,
            themePreflight: target,
            blocking: ContentBlocker.isEnabled,
            devTools: devToolsBridge?.isAttached == true
        )
        live.underPageBackgroundColor = target.map {
            ThemeBridge.preflightGround(for: $0).nsColor
        }
    }


    /// The scheme, or the decision to synthesise one, has changed.
    private func appearanceSettingsChanged() {
        // Every tab in the session hears this. A sleeping one has no scripts to
        // reinstall and no page to restyle — and reaching for its web view here
        // would wake the entire session on a single flip of the scheme. It
        // picks up the new setting when it's next built.
        guard isLive else { return }
        reinstallUserScripts()
        if ThemePreferences.isEnabled {
            // Every tab hears this at once. Sweeping them all together is what
            // made flipping the scheme stall — the tab you're looking at had to
            // queue behind every one you weren't. The rest catch up as you
            // reach them.
            scheduleThemeSynthesisIfVisible()
        } else {
            revertTheme()
        }
    }

    /// Folds a batch of the page's requests into the tally.
    ///
    /// Judged against the *main frame's* host, not the frame the report came
    /// from. Third-party is a statement about the site the user believes they
    /// are on, and measuring it per frame would rule that an ad frame's own
    /// tracker is first-party to the ad.
    private func recordRequests(_ records: [RequestRecord]) {
        guard !records.isEmpty, let pageHost = liveWebView?.url?.host else { return }
        let classifier = ContentBlocker.shared.classifier

        // Folded into a copy and written back once. `blockLog` is observed by
        // the panel, and a busy page would otherwise redraw it per request.
        var log = blockLog
        var changed = false
        for record in records {
            guard let host = DomainName.host(ofURL: record.url) else { continue }
            let verdict = classifier.verdict(forHost: host, pageHost: pageHost)
            if log.record(record, verdict: verdict, host: host) { changed = true }
        }
        guard changed else { return }
        blockLog = log
        debugLog("blocked \(log.blockedCount) from \(log.blocked.count), \(log.allowed.count) contacted")
    }

    /// The rules changed, or blocking was switched on or off.
    ///
    /// Applied to the tab as it stands rather than on its next navigation: a
    /// setting that needs a reload to be believed reads as broken. The requests
    /// a page already made are already made — what changes is everything from
    /// here on, and a reload makes it total.
    private func blockingRulesChanged() {
        guard isLive else { return }
        ContentBlocker.shared.apply(to: webView.configuration)
        reinstallUserScripts()
    }

    /// The page has changed under us — content revealed on scroll, a lazily
    /// loaded section, a subtree re-rendered — and wants sweeping again.
    private func pageDidMutate() {
        guard ThemePreferences.isEnabled else { return }
        guard themeSweeps < Self.maxThemeSweeps else {
            if themeSweeps == Self.maxThemeSweeps {
                themeSweeps += 1  // so this is said once, not on every mutation
                debugLog("theme: sweep limit reached — leaving later content alone")
            }
            return
        }
        scheduleThemeSynthesisIfVisible()
    }

    /// Puts the page back exactly as its authors drew it.
    private func revertTheme() {
        themeTask?.cancel()
        isolatedAgent.send(.themeRevert)
    }

    /// Runs one of the media methods against the frame that owns the element.
    ///
    /// Falls back to the main frame when there's no remembered frame, or when
    /// the remembered one has gone away. `unreachable` is the whole reason the
    /// agent tells that apart from `noValue`: a frame that has navigated
    /// should stop being addressed, while an element that simply isn't there
    /// any more is an answer, and retrying it in the main frame would only ask
    /// the wrong document the same question.
    private func runInMediaFrame<Value: Decodable>(
        _ method: PageProtocol.Method,
        _ params: [String: Any] = [:],
        as type: Value.Type
    ) async -> Value? {
        guard let mediaElementID else { return nil }
        var params = params
        params["id"] = mediaElementID

        if let mediaFrame {
            do {
                return try await pageAgent.call(method, params, as: type, in: mediaFrame)
            } catch PageProtocol.Failure.unreachable {
                // Don't keep addressing a frame that's no longer answering.
                self.mediaFrame = nil
            } catch {
                return nil
            }
        }
        return await pageAgent.value(method, params, as: type)
    }

    /// Takes one frame's report and works out what the player should show.
    ///
    /// The old rule was that the newest `play` event won. That is right until a
    /// page has more than one video, and pages that run video run adverts: each
    /// one fires `play` after the thing you actually opened the page for, so
    /// the sidebar, the play button and Pop Out all ended up pointed at a
    /// looping 300×250 advert with no way to get them back. `MediaRanking`
    /// makes the choice on evidence instead; this only gathers it.
    private func receiveMedia(_ report: MediaReport, from frame: WKFrameInfo) {
        if report.items.isEmpty {
            mediaFrames.removeValue(forKey: report.frameID)
        } else {
            mediaFrames[report.frameID] = (report.items, frame, Date())
        }
        selectPrimaryMedia()
    }

    /// Frames drop out of contention when they claim to be playing and then go
    /// quiet.
    ///
    /// A playing frame reports once a second, so silence means it's gone —
    /// navigated away, or an advert iframe removed from the document mid-play.
    /// Without this it would hold the player for the life of the tab. A frame
    /// that reported *stopped* media is not on a timer and is meant to stay:
    /// pausing a video shouldn't make its row disappear.
    private var liveCandidates: [(state: MediaState, frameID: String)] {
        let cutoff = Date().addingTimeInterval(-4)
        return mediaFrames.flatMap { frameID, entry -> [(MediaState, String)] in
            let isStale = entry.seenAt < cutoff
            return entry.items.compactMap { item in
                if isStale, item.isPlaying { return nil }
                return (item, frameID)
            }
        }
    }

    private func selectPrimaryMedia() {
        let candidates = liveCandidates
        guard let index = MediaRanking.primaryIndex(among: candidates.map(\.state.signals))
        else {
            media = nil
            mediaFrame = nil
            mediaElementID = nil
            return
        }
        let winner = candidates[index]
        media = winner.state
        mediaElementID = winner.state.elementID
        mediaFrame = mediaFrames[winner.frameID]?.frame
        let s = winner.state.signals
        debugLog(
            "media: chose \(winner.state.elementID) of \(candidates.count) "
            + "\(Int(s.width))x\(Int(s.height)), metadata=\(s.hasMetadata), "
            + "muted=\(s.isMuted), loop=\(s.loops), frames=\(mediaFrames.count)"
        )
    }

    private func clearMediaFrames() {
        mediaFrames.removeAll()
        mediaFrame = nil
        mediaElementID = nil
    }

    /// Prevents or restores page scrolling while the lens panel is showing.
    ///
    /// Run in both frames when the media is embedded. The top document is what
    /// scrolls the lens off target, so it needs the overflow lock; but the
    /// element's own native controls live in the iframe, and switching those
    /// off has to happen where the element is. Both halves are idempotent, so
    /// the usual case of one frame simply runs the same thing twice.
    func setPageScrollLocked(_ locked: Bool) {
        let method: PageProtocol.Method = locked ? .mediaLockScroll : .mediaUnlockScroll
        Task { @MainActor in
            pageAgent.send(method, ["id": mediaElementID ?? ""])
            if mediaFrame != nil {
                _ = await runInMediaFrame(method, as: PageProtocol.Empty.self)
            }
        }
    }

    /// The playing video's rectangle in the *top* document's viewport, in CSS
    /// pixels (== points) — which is the coordinate space the lens crops in.
    ///
    /// The script resolves its own frame offset before answering, so a video
    /// inside an iframe reports where it sits on the page rather than where it
    /// sits inside its embed. It returns nil rather than guessing when that
    /// offset can't be established; a lens aimed at the wrong part of the page
    /// is worse than a pop-out that declines.
    func measureVideoFrame() async -> CGRect? {
        await runInMediaFrame(.mediaFrame, as: MediaFrame.self)?.rect
    }

    func seekMedia(to seconds: Double) {
        Task { @MainActor in
            _ = await runInMediaFrame(.mediaSeek, ["time": seconds], as: PageProtocol.Empty.self)
        }
    }

    func skipMedia(by seconds: Double) {
        Task { @MainActor in
            _ = await runInMediaFrame(.mediaSkip, ["delta": seconds], as: PageProtocol.Empty.self)
        }
    }

    func toggleMediaPlayback() {
        Task { @MainActor in
            _ = await runInMediaFrame(.mediaToggle, as: PageProtocol.Empty.self)
        }
    }

    /// Releases everything the tab is holding: media, loads, observers, and the
    /// script handler.
    ///
    /// Relying on deallocation isn't enough — a web view whose audio is playing
    /// keeps its content process alive, so a closed tab can keep making noise
    /// long after it's gone from the sidebar.
    func teardown() {
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
        appearanceObserver = nil
        releaseWebView()
    }

    /// Lets go of the web view without ending the tab.
    ///
    /// Everything here works from a local reference rather than through the
    /// `webView` property: that property *builds* a view when there isn't one,
    /// so the trailing async cleanup would otherwise resurrect the very thing
    /// it was called to dispose of.
    private func releaseWebView() {
        sampleTask?.cancel()
        themeTask?.cancel()
        observations.forEach { $0.invalidate() }
        observations.removeAll()

        // Before the view goes: the bridge holds handlers on this controller
        // and a panel that kept talking to a released view would sit there
        // showing a document that no longer exists.
        devToolsBridge?.detach()

        guard let live = liveWebView else { return }
        liveWebView = nil

        live.navigationDelegate = nil
        live.uiDelegate = nil
        live.stopLoading()

        // The window's container keeps recently shown pages mounted so
        // switching back to them is free. A view being released is not coming
        // back, so it leaves under its own steam rather than lingering there
        // until it happens to be evicted.
        live.isHidden = false
        live.removeFromSuperview()
        liveIsolatedAgent?.unregister(from: live.configuration.userContentController)
        livePageAgent?.unregister(from: live.configuration.userContentController)
        liveIsolatedAgent = nil
        livePageAgent = nil
        live.configuration.userContentController
            .removeScriptMessageHandler(forName: BlockBridge.handlerName)

        media = nil
        clearMediaFrames()
        blockLog = BlockLog()

        Task { @MainActor in
            // Pause first for an immediate stop, then navigate away to tear the
            // media elements down for good.
            await live.pauseAllMediaPlayback()
            await live.closeAllMediaPresentations()
            live.load(URLRequest(url: URL(string: "about:blank")!))
        }
    }

    // MARK: - Sleep

    /// Gives the web view back, keeping everything the sidebar draws.
    ///
    /// The tab keeps its title, icon, address, and history blob, so the row is
    /// indistinguishable from a live one — what it loses is the web content
    /// process. Waking goes through exactly the path a restored tab takes on
    /// first view, which is why that machinery is reused rather than repeated.
    func sleep() {
        // Never the tab on screen, and never one with nothing to come back to.
        guard isLive, !isVisible else { return }
        let persisted = snapshot(refreshingState: true)
        guard persisted.isRestorable else { return }

        releaseWebView()

        pendingRestore = persisted
        // A tab that was navigated to explicitly has this set, and it is what
        // stops a pending restore from overwriting deliberate navigation.
        // Going to sleep makes the restore *the* deliberate outcome, so the
        // flag has to be cleared or the tab would wake up blank.
        hasNavigatedExplicitly = false

        // State that belonged to the page that just went away. Left behind, it
        // would describe a document this tab no longer has: a spinner that
        // never stops, a back button for history it can't reach yet.
        isLoading = false
        progress = 0
        canGoBack = false
        canGoForward = false
        lastError = nil
        sampledTopColor = nil
        themeColor = nil
        underPageColor = nil
        establishedGround = nil
        themeSweeps = 0
        needsThemeSweep = false
        needsTopColorSample = false

        debugLog("slept \(persisted.url ?? "?")")
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

    // MARK: - Visibility

    /// Whether this is the tab currently on screen.
    ///
    /// Not observable: nothing renders from it, and publishing it would invite
    /// a re-render on every switch for a fact the views already know from the
    /// selection. `BrowserSession.adoptSelection` is its only writer.
    @ObservationIgnored private(set) var isVisible = false

    /// When the tab was last on screen, for deciding what to reclaim.
    ///
    /// Nil means never shown — which makes it the first thing worth sleeping,
    /// since it holds a web view that has displayed nothing.
    @ObservationIgnored private(set) var lastViewedAt: Date?

    /// Work deferred because the tab wasn't being looked at when it came up.
    @ObservationIgnored private var needsThemeSweep = false
    @ObservationIgnored private var needsTopColorSample = false

    func didBecomeVisible() {
        guard !isVisible else { return }
        isVisible = true
        lastViewedAt = Date()

        // A page that changed while backgrounded has been left alone until
        // now; catch it up before it's seen rather than after.
        resumeThemeObserver()
        if needsTopColorSample {
            needsTopColorSample = false
            scheduleTopColorSampling()
        }
        if needsThemeSweep {
            needsThemeSweep = false
            scheduleThemeSynthesis()
        }
    }

    func didResignVisible() {
        guard isVisible else { return }
        isVisible = false
        // Stamped on the way out, so the clock starts when you stop looking.
        lastViewedAt = Date()

        // Nothing off screen is worth restyling or measuring, and both are
        // expensive enough to be worth stopping mid-flight.
        sampleTask?.cancel()
        themeTask?.cancel()
        pauseThemeObserver()
    }

    /// Stops the page reporting its own mutations while nobody is watching.
    ///
    /// The observer is subtree-wide and attribute-level, so a page that
    /// animates class names — a carousel, a sticky header, an SPA router —
    /// posts to native every 250ms forever, and each post costs a full theme
    /// sweep. In a background tab that is pure waste.
    private func pauseThemeObserver() {
        guard isLive, ThemePreferences.isEnabled else { return }
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(
                ThemeBridge.pauseObserverScript, arguments: [:],
                in: nil, contentWorld: .defaultClient
            )
        }
    }

    private func resumeThemeObserver() {
        guard isLive, ThemePreferences.isEnabled else { return }
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(
                ThemeBridge.resumeObserverScript, arguments: [:],
                in: nil, contentWorld: .defaultClient
            )
        }
    }

    // MARK: - Top colour sampling (continued)

    /// SPAs repaint well after `didFinish`, so sampling is retried on a short
    /// ladder rather than once.
    private func scheduleTopColorSampling() {
        // Only the selected tab's colour is ever read — `topColor` tints the
        // title strip above the page you're looking at. Sampling a background
        // tab runs a DOM walk to produce a value nothing will ask for.
        guard isVisible else {
            needsTopColorSample = true
            return
        }
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
        guard let rgb = await isolatedAgent.value(.pageTopColor, as: [Double].self),
              rgb.count >= 3
        else { return }

        sampledTopColor = NSColor(
            srgbRed: rgb[0] / 255,
            green: rgb[1] / 255,
            blue: rgb[2] / 255,
            alpha: 1
        )
    }

    // MARK: - Theme synthesis

    @ObservationIgnored private var themeTask: Task<Void, Never>?

    /// The ground this page settled on, kept so later sweeps don't re-derive it
    /// from whatever they happen to find still untouched.
    ///
    /// Not cleared on a URL change, deliberately. A route change swaps the
    /// content without replacing the document, so the theme — and its ground —
    /// are still there; clearing here would let each sweep re-derive a slightly
    /// lighter ground than the last and walk the page away from where it
    /// started. A real navigation is covered already: the new document carries
    /// no theme, reports itself unthemed, and the ground is derived afresh.
    @ObservationIgnored private var establishedGround: CSSColor?

    /// How many times this page has been swept.
    ///
    /// A page that rewrites itself in response to being rewritten would
    /// otherwise sweep forever. The observer is disconnected while we write, so
    /// this should never be reached in practice — it is the backstop for the
    /// page that manages it anyway, and it fails by leaving late content
    /// untouched rather than by spinning.
    @ObservationIgnored private var themeSweeps = 0
    private static let maxThemeSweeps = 60

    /// Restyles a page that doesn't offer the scheme the user asked for.
    ///
    /// Debounced, and cancelled on every navigation: a page mid-load reports
    /// half a palette, and theming that would mean re-theming a moment later.
    /// A re-sweep prompted by the page changing under us, rather than by a
    /// navigation.
    ///
    /// These are the ones worth deferring while a tab is off screen. A sweep is
    /// two walks of up to 4000 elements, each calling `getComputedStyle` and
    /// `getBoundingClientRect` — a forced style and layout flush per element —
    /// and a page that animates class names re-arms it every few hundred
    /// milliseconds for as long as it's open. Paid for a tab nobody is looking
    /// at, that is the most expensive thing a background tab can do.
    ///
    /// The *first* sweep of a page is deliberately not deferred: it's one per
    /// navigation, and skipping it would leave the tab showing the preflight
    /// holding colour until you arrived, turning a switch into a wait.
    private func scheduleThemeSynthesisIfVisible() {
        guard isVisible else {
            needsThemeSweep = true
            return
        }
        scheduleThemeSynthesis()
    }

    private func scheduleThemeSynthesis() {
        themeTask?.cancel()
        guard ThemePreferences.isEnabled else { return }
        themeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await synthesizeTheme()
        }
    }

    private func synthesizeTheme() async {
        let target = AppearanceController.resolved

        guard let survey = await isolatedAgent.value(
            .themeCollect, as: ThemeBridge.Survey.self
        ) else { return }

        // Measured, not asked. A site that already paints in the scheme the
        // user wants needs nothing from us, and restyling it would swap its
        // designers' work for an approximation of it. Declared signals —
        // a meta tag, a media query — say what a site claims; this says what it
        // did, and cross-origin stylesheets can't hide it.
        debugLog("""
            theme: target=\(target.rawValue) ground=\(survey.ground) \
            themed=\(survey.themed) colours=\(survey.colors.count)
            """)

        guard survey.ready else {
            debugLog("theme: document still parsing — waiting")
            return
        }

        let observations = ThemeBridge.observations(from: survey)

        // What the decision gets made on.
        //
        // `survey.ground` is the declared background of body or html, and is
        // very often transparent — plenty of sites never set one and simply
        // show the browser's canvas. Read literally, `rgba(0, 0, 0, 0)` parses
        // as black and satisfies "already dark", which would leave every such
        // site in light mode forever. But treating transparent as *light* is
        // just as wrong: a page caught mid-load hasn't painted its background
        // yet, and GitHub — which has a perfectly good dark mode — was being
        // restyled on the strength of a background that simply hadn't arrived.
        //
        // Neither reading of "undeclared" is safe, so the declared value is
        // abandoned and the largest thing the page actually paints is used
        // instead. That is what the eye takes for the background, and a page
        // with nothing painted yet has none — which is the signal to wait
        // rather than to guess.
        let decisionGround = SchemeDecision.decisionGround(
            declared: survey.ground, observations: observations
        )

        guard let decisionGround else {
            debugLog("theme: nothing painted yet — waiting")
            return
        }

        if !survey.themed,
           SchemeDecision.alreadySatisfies(target, ground: decisionGround) {
            let lightness = OKLCH(decisionGround.rgb).l
            debugLog("theme: site already \(target.rawValue) (L=\(rounded(lightness))) — left alone")
            isolatedAgent.send(.themeDismissPreflight)
            return
        }

        var plan = ThemePlan.build(
            from: observations,
            target: target,
            establishedGround: survey.themed ? establishedGround : nil
        )

        // Gradients are values rather than single colours, so they take their
        // own path — stops move together, or the light comes from the wrong
        // side afterwards.
        for reading in survey.colors where reading.property == "gradient" {
            let transformed = CSSGradient.transformValue(reading.value, to: target)
            guard transformed != reading.value else { continue }
            plan.replacements["gradient|" + reading.value] = transformed
        }

        // Artwork is not recoloured, with one exception narrow enough to be
        // safe: a mark carrying no colour at all, which would otherwise vanish.
        // A black wordmark becomes a white one — what its designers drew for
        // their own dark mode — and there is no hue to lose by flipping it.
        var inverts: [String: String] = [:]
        var hueInverts: [String: String] = [:]
        for reading in survey.images {
            guard let data = Data(base64Encoded: reading.pixels),
                  let verdict = ImageAnalysis.verdict(rgba: [UInt8](data))
            else { continue }

            // What it will be sitting on once the theme lands, not what it sits
            // on now: the surface behind it is about to move too.
            let surface: SRGB = {
                if let themed = plan.replacements["background|" + reading.backdrop]
                    .flatMap(CSSColor.init(css:)) {
                    return themed.rgb
                }
                if let backdrop = CSSColor(css: reading.backdrop), backdrop.alpha > 0.5 {
                    return backdrop.rgb
                }
                return plan.pageBackground.rgb
            }()

            if ImageAnalysis.shouldInvert(verdict, on: surface) {
                inverts[reading.key] = "1"
            } else if ImageAnalysis.shouldInvertPreservingHue(verdict, on: surface) {
                hueInverts[reading.key] = "1"
            }
        }

        if !inverts.isEmpty || !hueInverts.isEmpty {
            debugLog("""
                theme: inverting \(inverts.count) colourless and \
                \(hueInverts.count) coloured mark(s)
                """)
        }

        guard !plan.isEmpty || !inverts.isEmpty || !hueInverts.isEmpty else {
            debugLog("theme: nothing to change — left alone")
            isolatedAgent.send(.themeDismissPreflight)
            return
        }

        isolatedAgent.send(.themeApply, [
            "plan": plan.replacements,
            "inverts": inverts,
            "hueInverts": hueInverts,
            "ground": plan.pageBackground.css,
            "scheme": target.rawValue,
        ])

        debugLog("""
            theme: applied \(plan.replacements.count) substitutions, \
            ground \(plan.pageBackground.css)
            """)

        establishedGround = plan.pageBackground
        themeSweeps += 1

        // Public API, and the fix for the white band that rubber-band scrolling
        // would otherwise reveal under a darkened page.
        webView.underPageBackgroundColor = plan.pageBackground.rgb.nsColor
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

        let candidates = await isolatedAgent.value(
            .pageFavicons, as: [FaviconCandidate].self
        ) ?? []

        var origin = ""
        if let scheme = pageURL.scheme { origin = "\(scheme)://\(host)" }
        guard let href = FaviconPicker.best(from: candidates, origin: origin) else { return }

        let image = await FaviconStore.shared.fetchIcon(from: href, host: host)
        // The tab may have navigated elsewhere during the download.
        guard webView.url?.host == host else { return }
        favicon = image
        faviconHost = host
    }

    /// WebKit's back/forward + scroll blob, kept between saves.
    ///
    /// Reading `interactionState` is a full synchronous serialization of the
    /// tab's history, and the session is saved for reasons that have nothing to
    /// do with history — a title landing, most often. Every such save was
    /// re-serializing *every* tab, so a page that animates its own title
    /// ("(3) Inbox", a video's countdown) had the whole window paying for it
    /// once a second. The blob only changes when the tab navigates or scrolls,
    /// so it is re-read then, and on the way out.
    @ObservationIgnored private var cachedInteractionState: Data?
    @ObservationIgnored private var interactionStateIsStale = true

    /// Marks the blob as worth re-reading. Cheap, and called from the KVO
    /// observers that already fire on navigation.
    private func invalidateInteractionState() {
        interactionStateIsStale = true
    }

    /// `refreshingState` forces a re-read regardless — used when quitting,
    /// where an exact scroll position is worth the cost that a routine
    /// debounced save is not.
    func snapshot(refreshingState: Bool = false) -> PersistedTab {
        // A tab restored but never opened — or one that has been put back to
        // sleep — has no web view to ask. Hand back what we were holding, so
        // its history survives another quit.
        // Stamped onto whatever this returns rather than into each branch:
        // a sleeping tab hands back the blob it was restored from, and a tab
        // refiled while asleep would otherwise be written out still wearing
        // the group it had at launch.
        func filed(_ tab: PersistedTab) -> PersistedTab {
            var tab = tab
            tab.groupID = groupID
            return tab
        }

        if let pendingRestore { return filed(pendingRestore) }

        guard let live = liveWebView else {
            return filed(PersistedTab(
                url: currentURL,
                title: pageTitle,
                interactionState: cachedInteractionState
            ))
        }

        if refreshingState || interactionStateIsStale {
            cachedInteractionState = live.interactionState as? Data
            interactionStateIsStale = false
        }

        return filed(PersistedTab(
            url: live.url?.absoluteString ?? (mode == .browsing ? addressText : nil),
            title: pageTitle,
            interactionState: cachedInteractionState
        ))
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
                    // The history blob is only worth re-reading once the tab
                    // has actually gone somewhere.
                    self.invalidateInteractionState()
                    // Covers SPA route changes, which never fire didFinish.
                    // Clear first so a stale colour doesn't linger on the new page.
                    self.sampledTopColor = nil
                    self.scheduleTopColorSampling()
                    // A route change replaces the content without a load, so
                    // the new markup needs sweeping too — when it's on screen.
                    // A single-page app left in a background tab can route on a
                    // timer, and each route would otherwise buy a full sweep.
                    self.scheduleThemeSynthesisIfVisible()
                    // The old page's media is gone the moment we navigate.
                    self.media = nil
                    self.clearMediaFrames()
                    // A popup tab starts in .home but is loaded by WebKit
                    // directly, so the mode has to follow the URL. Not during
                    // a dive, though: there the load starting is precisely the
                    // moment the home screen must stay up.
                    if self.mode == .home && !self.isDiving { self.mode = .browsing }
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
        if mode == .home {
            // The screen stays on the home view while the page loads behind
            // it: the water rises to cover everything, and the flip to
            // `.browsing` is the reveal at the end, not this line.
            isDiving = true
            diveStartedAt = Date()
        } else {
            mode = .browsing
        }
        webView.load(URLRequest(url: url))
    }

    /// The reveal: the page is ready and the water has risen, so show it.
    func completeDive() {
        guard isDiving else { return }
        isDiving = false
        diveStartedAt = nil
        mode = .browsing
    }

    func reload() {
        lastError = nil
        webView.reload()
    }

    /// Ignores the cache, for when a page is wrong rather than merely old.
    func reloadIgnoringCache() {
        lastError = nil
        webView.reloadFromOrigin()
    }

    func stop() { webView.stopLoading() }

    // MARK: - Zoom

    /// Per-tab, deliberately: zoom belongs to the page you're reading, not to
    /// the browser. Not persisted — a restored session shouldn't surprise you
    /// with yesterday's magnification.
    ///
    /// Stored here rather than read back from `webView.pageZoom`, which is not
    /// observable: a computed property over it never publishes a change, so
    /// everything that depends on the zoom — the reset menu item's enabled
    /// state, the sidebar's indicator — silently keeps whatever it saw first.
    private(set) var zoomLevel: Double = ZoomSteps.standard {
        // Only if there's a view to zoom — a sleeping tab records the level and
        // applies it when it's rebuilt.
        didSet { liveWebView?.pageZoom = zoomLevel }
    }

    var isZoomed: Bool { !ZoomSteps.isStandard(zoomLevel) }
    var zoomLabel: String { ZoomSteps.label(for: zoomLevel) }

    func zoomIn() { zoomLevel = ZoomSteps.zoomingIn(from: zoomLevel) }
    func zoomOut() { zoomLevel = ZoomSteps.zoomingOut(from: zoomLevel) }
    func resetZoom() { zoomLevel = ZoomSteps.standard }

    // MARK: - Find

    /// Highlights and scrolls to the next match, using WebKit's own find rather
    /// than anything injected: it handles text spanning elements, shadow DOM,
    /// and wrapping, none of which a script would get right.
    @discardableResult
    func findInPage(_ query: String, forward: Bool = true) async -> Bool {
        guard !query.isEmpty else { return false }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = false
        configuration.wraps = true
        let result = try? await webView.find(query, configuration: configuration)
        return result?.matchFound ?? false
    }

    /// How many times the query appears in the page's *rendered* text.
    ///
    /// `innerText` rather than the DOM: it already excludes hidden elements and
    /// flattens across element boundaries, so a phrase split by markup still
    /// counts once. WebKit's find API reports only whether it landed on
    /// something, so the tally has to come from somewhere.
    func countMatches(of query: String) async -> Int {
        guard !query.isEmpty else { return 0 }
        return await pageAgent.value(.findCount, ["query": query], as: Int.self) ?? 0
    }

    /// Drops the highlight when the find bar closes, so a stale selection isn't
    /// left sitting on the page.
    func clearFindSelection() {
        pageAgent.send(.findClearSelection)
    }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    /// Returns to the search screen without tearing down the web view, so the
    /// page and its history are still there if the user navigates again.
    func goHome() {
        // A dive abandoned mid-rise would otherwise complete later, on a page
        // the user has already walked away from.
        isDiving = false
        diveStartedAt = nil
        mode = .home
        addressText = ""
        lastError = nil
    }
}

// MARK: - WKNavigationDelegate

extension Tab: WKNavigationDelegate {

    /// A new document is live.
    ///
    /// This, not the `\.url` KVO, is the authoritative signal for both the
    /// callers below: the URL also changes on SPA route changes, where the
    /// document survives, none of the agent's node ids have gone stale, and the
    /// requests already counted are still this page's.
    ///
    /// Main frame only, so a third-party iframe committing mid-page doesn't
    /// wipe the tally of what put it there.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        DevToolsController.shared.documentDidCommit(for: self)
        // Something arrived, so this is a window with a page in it.
        hasCommittedDocument = true
        emptyPopupWatchdog?.cancel()
        if !blockLog.isEmpty { blockLog = BlockLog() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastError = nil
        invalidateInteractionState()
        session?.scheduleSave()
        // A new document gets its own sweep budget.
        themeSweeps = 0
        Task { await refreshFavicon() }
        scheduleTopColorSampling()
        scheduleThemeSynthesis()
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
        // A window the page opened whose first load never arrived. Closed here
        // rather than on the watchdog's schedule, because we already know.
        if wasOpenedByPage, !hasCommittedDocument, webView.url == nil {
            emptyPopupWatchdog?.cancel()
            debugLog("closed a window whose only load failed")
            session?.close(self)
        }
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
        // The document's real status and headers, which the page itself cannot
        // read for a cross-origin redirect and which no JS-based inspector can
        // therefore report. Taken natively so the top row of the network list
        // is the one thing in it that is never a guess.
        if navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse,
           let url = http.url?.absoluteString {
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers["\(key)"] = "\(value)"
            }
            let response = DocumentResponse(
                url: url, status: http.statusCode,
                headers: headers, mime: http.mimeType ?? ""
            )
            lastDocumentResponse = response
            DevToolsController.shared.session(for: self)?.recordDocument(response)
        }
        return navigationResponse.canShowMIMEType ? .allow : .download
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
        let name = message.name
        let body = message.body
        MainActor.assumeIsolated {
            switch name {
            case BlockBridge.handlerName:
                recordRequests(BlockBridge.decode(body))

            case DevToolsAgent.eventHandlerName, ConsoleAgent.eventHandlerName,
                 NetworkAgent.eventHandlerName:
                // Forwarded rather than handled by the bridge directly, so a tab
                // still registers exactly one script message handler and the
                // retain-cycle reasoning above holds for every bridge we add.
                devToolsBridge?.receive(name: name, body: body)

            default:
                break
            }
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

        // Refused before the tab exists rather than closed after it appears.
        // A window that opens and vanishes is still something that happened to
        // the reader, and the point is that nothing happens at all.
        if let url = navigationAction.request.url, isAdWindow(url) {
            debugLog("refused a window to \(url.host ?? url.absoluteString)")
            return nil
        }

        // Must be built with WebKit's configuration, not a fresh one, or the
        // new view won't be linked to the opener.
        let tab = session.addTab(configuration: configuration)
        tab.wasOpenedByPage = true
        tab.watchForAnEmptyWindow()
        // No explicit load here — WebKit drives the returned view itself.
        return tab.webView
    }

    /// Whether a window the page asked to open is one the reader wanted.
    ///
    /// The popup blocker Surf already had only covers windows opened *without*
    /// a click — `javaScriptCanOpenWindowsAutomatically` is off, so a script
    /// that opens one unprompted gets nowhere. What it can't cover is the
    /// pop-under, which is opened *by* the click: the gesture is real, WebKit is
    /// right to allow it, and the destination is the only thing that gives it
    /// away. So that is what gets asked about.
    ///
    /// No heuristic, and deliberately so: this either points at a domain the
    /// lists name or it doesn't, and a window refused on a guess is a link the
    /// reader clicked and never got.
    private func isAdWindow(_ url: URL) -> Bool {
        guard ContentBlocker.isEnabled, let host = url.host else { return false }

        let pageHost = liveWebView?.url?.host ?? host
        guard !ContentBlocker.shared.isPaused(on: pageHost) else { return false }

        let classifier = ContentBlocker.shared.classifier
        guard classifier.refusesWindow(to: host, from: pageHost) else { return false }
        let verdict = classifier.verdict(forHost: host, pageHost: pageHost)

        // Recorded like any other refusal, so the shield explains a window that
        // didn't open rather than leaving the reader wondering if the click
        // registered.
        var log = blockLog
        if log.record(
            RequestRecord(url: url.absoluteString, kind: .popup, didLoad: false),
            verdict: verdict,
            host: host
        ) {
            blockLog = log
        }
        return true
    }

    /// Closes a window that opened with nothing in it.
    ///
    /// The destination check above catches a pop-under aimed at a domain the
    /// lists name. What it can't catch is one aimed somewhere unlisted whose
    /// *contents* are then blocked — WebKit hands over the window and fails the
    /// load afterwards, leaving a blank tab with no address and no title. That
    /// tab is an artefact of blocking rather than anything the reader asked
    /// for, so it goes.
    ///
    /// Only ever a tab the page opened, and only while nothing has committed in
    /// it: a tab the user opened stays open however empty it is, because they
    /// opened it.
    func watchForAnEmptyWindow() {
        emptyPopupWatchdog?.cancel()
        emptyPopupWatchdog = Task { @MainActor [weak self] in
            // Long enough for a slow redirect chain to arrive, short enough that
            // a blank tab isn't left sitting there.
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            guard wasOpenedByPage, !hasCommittedDocument, liveWebView?.url == nil else { return }
            debugLog("closed a window that never loaded anything")
            session?.close(self)
        }
    }

    func webViewDidClose(_ webView: WKWebView) {
        session?.close(self)
    }
}

/// Two decimal places, for log lines where more would be noise.
private func rounded(_ value: Double) -> String {
    String((value * 100).rounded() / 100)
}

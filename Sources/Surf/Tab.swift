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
    /// The page's colour scheme, emulated per tab — the dev-tools "what does
    /// this look like in dark mode" switch, not the browser's own theme.
    ///
    /// WebKit exposes no colour-scheme API; what it reads is the web view's
    /// `effectiveAppearance`, mapped straight onto `prefers-color-scheme`
    /// and restyled live. Overriding the view's `appearance` therefore flips
    /// the page and only the page: the panel, the chrome and every other tab
    /// keep following the app. Deliberately not persisted — an emulation is
    /// a question being asked, not a setting.
    var emulatedAppearance: AppearanceMode = .system {
        didSet { webView.appearance = emulatedAppearance.nsAppearance }
    }

    /// The page laid out at a chosen CSS-pixel size — nil fills the window.
    /// Like the appearance emulation: per tab, never persisted, and applied
    /// by the container's layout rather than stored anywhere the page sees.
    var emulatedViewport: CGSize?

    /// The element-pick capture veil, present only while picking.
    @ObservationIgnored var captureOverlay: CaptureOverlayView?


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

    /// The tab whose page opened this one, so Back has somewhere to go on a
    /// tab with no history of its own: it closes this tab and returns there.
    /// Weakly by id, not by reference — the opener may be closed first, and
    /// this must not keep a torn-down tab alive.
    @ObservationIgnored var openerTabID: UUID?

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
    // Not `private`: Screenshots.swift is the same type in another file,
    // and a full-page capture asks the page its height through this.
    var isolatedAgent: PageAgent {
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
        ) { [weak self] note in
            let flipped = note.userInfo?[ContentBlocker.enabledChangedKey] as? Bool ?? false
            MainActor.assumeIsolated { self?.blockingRulesChanged(settingFlipped: flipped) }
        }

        // Narration and a playing video are two voices in one room. The page
        // is paused, not muted: pausing is what its own play button undoes.
        narrator.onWillBeginAudio = { [weak self] in
            guard let self, media?.isPlaying == true else { return }
            toggleMediaPlayback()
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

        let created = SurfWebView(frame: .zero, configuration: config)
        // Lazy, so `self` is fully formed by the time this runs.
        created.tab = self
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
        // Hibernation rebuilds the web view; the emulation must survive that
        // or waking a tab silently un-darks it.
        created.appearance = emulatedAppearance.nsAppearance

        // Rebuilt with the view, not with the tab: hibernation releases the web
        // view and builds another, and an agent still pointed at the released
        // one would post into nothing.
        liveIsolatedAgent = PageAgent(world: .isolated, webView: created)
        livePageAgent = PageAgent(world: .page, webView: created)

        liveWebView = created

        // Before anything can be loaded into it. A view that starts a page load
        // and gains its rules afterwards has already let the first wave of
        // requests through, which is the wave the ads are in.
        blockingHost = nil
        ContentBlocker.shared.apply(to: config, host: nil)
        isBlocking = ContentBlocker.shared.isActive(for: nil)

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
        if let aiTitle, !aiTitle.isEmpty { return aiTitle }
        if !pageTitle.isEmpty { return pageTitle }
        if mode == .home { return "New Tab" }
        if let host = currentURL.flatMap(URL.init(string:))?.host { return host }
        return "Loading…"
    }

    // MARK: - AI naming

    /// A model-written name for the current page, when the feature is on and
    /// one arrived. Never persisted: the session file keeps the page's real
    /// title, and a restored tab re-earns its AI name (from the session cache,
    /// usually) the next time its page loads.
    private(set) var aiTitle: String?

    @ObservationIgnored private var aiNamingTask: Task<Void, Never>?

    /// Kicks off naming for the page that just finished loading.
    ///
    /// Waits a beat first: titles routinely land *after* `didFinish`, and the
    /// name should be made from the title the user actually sees. The result
    /// is applied only if the tab is still on the same page — a name for the
    /// last page must never land on this one.
    private func scheduleAINaming() {
        aiNamingTask?.cancel()
        guard AIPreferences.isEnabled(.tabRenaming) else { return }
        aiNamingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            guard let url = self.webView.url?.absoluteString else { return }
            let title = self.pageTitle
            guard let name = await AITabNamer.shared.name(forURL: url, pageTitle: title) else {
                return
            }
            guard !Task.isCancelled, self.webView.url?.absoluteString == url else { return }
            self.aiTitle = name
        }
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

    /// The sticker this tab belongs to, if any.
    ///
    /// Set once, when a sticker opens its page, and never cleared: a sticker's
    /// tab is its tab for as long as it lives. The sidebar leaves these out of
    /// its list — the sticker is already on screen, and a row for it as well
    /// would be one tab claiming two places in the same sidebar.
    var stickerID: UUID?

    /// Set once the user (or code) navigates deliberately. A pending restore
    /// must never overwrite that — restoring a tab you've already typed into
    /// would silently throw the new page away.
    @ObservationIgnored private var hasNavigatedExplicitly = false

    /// Populates the visible state from disk without loading anything yet, so
    /// the sidebar shows real titles immediately on launch.
    func prepareRestore(from persisted: PersistedTab) {
        pendingRestore = persisted
        groupID = persisted.groupID
        stickerID = persisted.stickerID
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
    // MARK: - Context menu

    /// What the page last reported was under the pointer at a right-click, and
    /// when it said so. Cleared when the menu closes, so a payload can only
    /// ever describe the click the open menu belongs to — losing the race
    /// costs items, never accuracy.
    @ObservationIgnored private(set) var contextHit: ContextHit?
    @ObservationIgnored private var contextHitAt: Date?

    private func handleContextEvent(_ event: String, _ data: Data) {
        guard event == "hit",
              let decoded = try? JSONDecoder().decode(
                  PageProtocol.Event<ContextHit>.self, from: data
              )
        else { return }
        contextHit = decoded.payload
        contextHitAt = Date()
        debugLog("context: hit \(decoded.payload.summary)")
    }

    /// WebKit is about to show its page menu; Surf's items go on the front of
    /// it.
    ///
    /// WebKit's own items are kept rather than replaced. Look Up, Services,
    /// spelling and the editing verbs are all things Surf would otherwise have
    /// to reimplement worse, and a page menu that lost them to gain "Enter
    /// Focus" would be a bad trade.
    func willOpenContextMenu(_ menu: NSMenu, with event: NSEvent) {
        let age = contextHitAt.map { Date().timeIntervalSince($0) * 1000 }
        debugLog(
            "context: menu — "
                + (age.map { String(format: "hit %.0fms old", $0) } ?? "no hit in hand")
        )

        // No hit means the push lost its race with the menu. The stock menu is
        // still correct, just smaller — which is the whole reason this degrades
        // by dropping items rather than by guessing at them.
        guard let hit = contextHit else { return }
        // In a text field WebKit's menu is already the right one, and Surf has
        // nothing to add to typing.
        guard !hit.editable else { return }

        var items: [NSMenuItem] = []

        if let link = hit.linkURL, let url = URL(string: link) {
            items.append(ActionMenuItem("Open Link in New Tab") { [weak self] in
                self?.openInNewTab(url, select: false)
            })
            items.append(ActionMenuItem("Open Link in Split") { [weak self] in
                guard let self, let session, let opened = openInNewTab(url, select: false)
                else { return }
                session.openSplit(with: opened, on: .trailing)
            })
            items.append(ActionMenuItem("Open Link in Mini Window") { [weak self] in
                guard let session = self?.session else { return }
                MiniWindowController.shared.open(url, from: session)
            })
            items.append(ActionMenuItem("Copy Link") { Tab.copyToPasteboard(link) })
        }

        if let image = hit.imageURL {
            if let url = URL(string: image) {
                items.append(ActionMenuItem("Open Image in New Tab") { [weak self] in
                    self?.openInNewTab(url, select: false)
                })
            }
            // The address, not the pixels — WebKit's own "Copy Image" already
            // covers the pixels, and the two are different things to want.
            items.append(ActionMenuItem("Copy Image Address") { Tab.copyToPasteboard(image) })
        }

        // Gated on the media report rather than on what was clicked: pop-out
        // stages the element that report found, and offering it for a video
        // the report hasn't seen would be an item that does nothing.
        if hit.mediaIsVideo, media?.hasVideo == true {
            items.append(ActionMenuItem("Pop Out Video") { [weak self] in
                guard let self else { return }
                PopOutController.shared.toggle(self)
            })
        }

        if !items.isEmpty { items.append(.separator()) }

        items.append(ActionMenuItem(isFocusActive ? "Leave Focus" : "Enter Focus") {
            [weak self] in self?.toggleFocus()
        })
        items.append(ActionMenuItem("Screenshot Area…") { [weak self] in
            self?.beginAreaCapture()
        })

        if let host = currentURL.flatMap(URL.init(string:))?.host,
           !ContentBlocker.shared.isUserBlocked(domain: host) {
            items.append(ActionMenuItem("Block Content From \(host)") {
                ContentBlocker.shared.block(domain: host)
            })
        }

        for (offset, item) in items.enumerated() { menu.insertItem(item, at: offset) }
        menu.insertItem(.separator(), at: items.count)
    }

    /// A new tab in this tab's own island, on `url`.
    @discardableResult
    private func openInNewTab(_ url: URL, select: Bool) -> Tab? {
        guard let session else { return nil }
        let opened = session.addTab(select: select)
        opened.submit(url.absoluteString)
        return opened
    }

    private static func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    func contextMenuDidClose() {
        contextHit = nil
        contextHitAt = nil
    }

    private func installAgents() {
        let controller = webView.configuration.userContentController
        // Both agent channels, and the events each world reports on its own.
        isolatedAgent.register(on: controller)
        pageAgent.register(on: controller)

        isolatedAgent.onEvent = { [weak self] header, data, _ in
            guard let self else { return }
            switch header.domain {
            case "theme":
                if header.event == "mutated" { pageDidMutate() }
            case "capture":
                handleCaptureEvent(header.event, data)
            case "context":
                handleContextEvent(header.event, data)
            default:
                break
            }
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
            blocking: isBlocking,
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
    ///
    /// When it was a switch — the setting, or this site's pause — and the
    /// page's own state actually changed, the reload is done here, but only
    /// for a tab someone is looking at. The shield's count was gathered under
    /// the old rules and is emptied first; the reload is what fills it again —
    /// or leaves it empty, which is the point. A background tab keeps its page
    /// and picks the rules up on its next load; a sleeping one has no page to
    /// reload, and waking it for this would cost a web content process each.
    private func blockingRulesChanged(settingFlipped: Bool) {
        guard isLive else { return }
        let changed = applyBlockingRules(for: blockingHost)
        guard settingFlipped, changed else { return }
        blockLog = BlockLog()
        if isVisible || MiniWindowController.shared.tab === self { reload() }
    }

    /// Whether this tab's view currently holds the rule lists. The pause is
    /// per site and the tab moves between sites, so this is re-decided on
    /// every main-frame navigation and the answer is kept to know when it
    /// moved.
    @ObservationIgnored private var isBlocking = true

    /// The host the lists were last decided for: the navigation's
    /// destination, from the moment it is allowed. Not `webView.url`, which
    /// still names the old page while the new one is provisional — and a
    /// rule update landing in that gap would otherwise re-decide for the
    /// page being left, stripping the lists from the one arriving.
    @ObservationIgnored private var blockingHost: String?

    /// Gives the view the lists a page on `host` should have, and the scripts
    /// that go with them. Returns whether that was a change.
    @discardableResult
    private func applyBlockingRules(for host: String?) -> Bool {
        let blocker = ContentBlocker.shared
        let active = blocker.isActive(for: host)
        blocker.apply(to: webView.configuration, host: host)
        let changed = active != isBlocking
        isBlocking = active
        reinstallUserScripts()
        return changed
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
    /// - Parameter keepingInteraction: theater mode locks scroll but leaves
    ///   the promoted player alive under the pointer; the pop-out lens wants
    ///   the page inert entirely.
    func setPageScrollLocked(_ locked: Bool, keepingInteraction: Bool = false) {
        let method: PageProtocol.Method = locked ? .mediaLockScroll : .mediaUnlockScroll
        Task { @MainActor in
            pageAgent.send(method, [
                "id": mediaElementID ?? "",
                "keepInteraction": keepingInteraction,
            ])
            if mediaFrame != nil {
                _ = await runInMediaFrame(
                    method, ["keepInteraction": keepingInteraction],
                    as: PageProtocol.Empty.self
                )
            }
        }
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
        if let blockingObserver {
            NotificationCenter.default.removeObserver(blockingObserver)
        }
        blockingObserver = nil
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
        resetFocus()

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

    /// Which sweep is the newest, now that the heavy half runs off the main
    /// actor. A detached task can't be cancelled mid-thought, so a slow sweep
    /// can finish after the one that superseded it — the stamp is taken before
    /// the survey is requested and checked before anything is applied, and a
    /// stale result is dropped rather than allowed to overwrite a newer one.
    @ObservationIgnored private var themeGeneration = 0

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

        themeGeneration += 1
        let generation = themeGeneration

        // The raw envelope, not the decoded survey: decoding it is part of the
        // heavy half, and belongs off the main actor with the rest.
        guard let envelope = await isolatedAgent.rawReply(.themeCollect) else { return }

        let established = establishedGround
        let outcome = await Task.detached(priority: .userInitiated) {
            ThemeBridge.synthesize(
                envelope: envelope, target: target, establishedGround: established
            )
        }.value

        // A newer sweep has been started, or the tab stopped being looked at,
        // while this one was thinking. Its answer describes a page that has
        // moved on; applying it would overwrite the newer sweep's work.
        guard generation == themeGeneration, !Task.isCancelled else {
            debugLog("theme: sweep superseded — dropped")
            return
        }

        switch outcome {
        case .unavailable:
            return
        case .parsing:
            debugLog("theme: document still parsing — waiting")
        case .unpainted:
            debugLog("theme: nothing painted yet — waiting")
        case .satisfied:
            isolatedAgent.send(.themeDismissPreflight)
        case .unchanged:
            debugLog("theme: nothing to change — left alone")
            isolatedAgent.send(.themeDismissPreflight)
        case let .apply(replacements, inverts, hueInverts, ground):
            isolatedAgent.send(.themeApply, [
                "plan": replacements,
                "inverts": inverts,
                "hueInverts": hueInverts,
                "ground": ground.css,
                "scheme": target.rawValue,
            ])

            debugLog("""
                theme: applied \(replacements.count) substitutions, \
                ground \(ground.css)
                """)

            establishedGround = ground
            themeSweeps += 1

            // Public API, and the fix for the white band that rubber-band
            // scrolling would otherwise reveal under a darkened page.
            webView.underPageBackgroundColor = ground.rgb.nsColor
        }
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
            tab.stickerID = stickerID
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
                    // Covers SPA route changes, which never fire didCommit:
                    // the content is new even though the document isn't, so
                    // the old verdict is stale and the new page gets read.
                    // The reader itself is left alone — a route change under
                    // an open reader is handled by didCommit when it's a real
                    // navigation, and a fragment scroll shouldn't close it.
                    self.focusDetection = nil
                    self.focusPrevalidated = nil
                    self.scheduleFocusDetection()
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

    /// - Parameter diving: whether to play the home screen's dive. Asked for by
    ///   the caller rather than inferred from `mode == .home`, because a great
    ///   many things start life on a home tab without anyone having looked at
    ///   one: a tab made by ⌘T is born `.home` and loaded a keystroke later, and
    ///   so is the first tab when a URL arrives in the launch environment.
    ///   Inferring it animated the sea for both.
    func submit(_ input: String, diving: Bool = false) {
        guard let url = URLResolver.resolve(input) else { return }
        hasNavigatedExplicitly = true
        pendingRestore = nil
        lastError = nil
        if diving && mode == .home {
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
    /// Whether Back has anywhere to go: page history, or — on a tab a page
    /// opened — back out of the tab entirely, to the page it was opened from.
    ///
    /// Without the second half, a link that opens in a new tab is a one-way
    /// door: the new tab starts with empty history, so Back is dead and the
    /// only way home is finding the old tab in the list by hand.
    var canGoBackOrClose: Bool { canGoBack || wasOpenedByPage }

    func goBack() {
        if canGoBack {
            webView.goBack()
        } else if wasOpenedByPage {
            // At the start of a page-opened tab's history, Back un-opens the
            // tab: close it and return to the page that spawned it, which is
            // where the reader was before the click.
            session?.closeReturningToOpener(self)
        }
    }

    func goForward() { webView.goForward() }

    // MARK: - Focus

    /// Where Focus is on this tab's current page.
    ///
    /// `failed` carries its message because the overlay is already up when
    /// extraction disappoints, and "back to the page" needs a reason beside it.
    enum FocusPhase: Equatable {
        case inactive
        case extracting
        case active
        case failed(String)
    }

    private(set) var focusPhase: FocusPhase = .inactive
    private(set) var focusArticle: FocusArticle?

    /// Parsed from the page's JSON-LD when it holds a real recipe. Non-nil
    /// makes the recipe lens the default face of Focus for this page.
    private(set) var focusRecipe: FocusRecipe?

    /// Theater mode: the page's own video promoted over everything it drew.
    /// True makes the overlay a transparent transport instead of a reader.
    private(set) var focusVideoStage = false

    // MARK: - Site lenses

    /// The site lens this tab is in, if any.
    ///
    /// Held apart from `focusPhase` because it is the one lens that navigates
    /// on purpose. Searching is a load and so is playing, so a lens torn down
    /// by its own navigation would not survive its first keystroke — which is
    /// why `resetFocus` takes an instruction to leave it standing.
    private(set) var focusSite: SiteFocusSite?

    /// The YouTube lens's state, alive only while that lens is up.
    private(set) var youtubeLens: YouTubeLens?

    /// The site lens on offer here, if this address has one.
    ///
    /// Asked before the classifier: on a site Surf knows, its own lens beats
    /// whatever prose the page happens to carry — a YouTube watch page reads
    /// as an article often enough to lose the argument otherwise.
    var focusOfferSite: SiteFocusSite? {
        guard mode == .browsing, focusPhase == .inactive else { return nil }
        return SiteFocusSite.matching(liveWebView?.url)
    }

    func enterSiteFocus() {
        guard mode == .browsing, focusPhase == .inactive,
              let site = SiteFocusSite.matching(webView.url)
        else { return }
        narrator.stop()
        // A detection already in flight would land after the lens is up and
        // spend the extractor's content walk on a verdict nothing will read.
        focusDetectionTask?.cancel()
        focusDetection = nil
        focusPrevalidated = nil
        focusSite = site
        let lens = YouTubeLens(tab: self)
        youtubeLens = lens
        focusPhase = .active
        // Whatever is already on screen is the lens's first screen: opening
        // it on a video should land on that video, not on a blank field.
        lens.documentDidLoad()
        debugLog("focus: \(site.displayName) lens")
    }

    func exitSiteFocus() {
        guard focusSite != nil else { return }
        // By hand rather than by navigation, so the page is still there and
        // still wearing the stage — it has to be handed back as it was.
        youtubeLens?.tearDown()
        youtubeLens = nil
        focusSite = nil
        focusPhase = .inactive
    }

    /// The address the site lens is standing on.
    var currentSiteLensURL: URL? { liveWebView?.url }

    /// A navigation the lens made itself. Distinct from `submit` because it
    /// carries no address-bar intent and must not disturb the dive.
    func loadInSiteLens(_ url: URL) {
        hasNavigatedExplicitly = true
        lastError = nil
        webView.load(URLRequest(url: url))
    }

    /// Installs the YouTube domain and reads the page. Installation is
    /// idempotent and costs nothing after the first call on a document, so
    /// every read can carry it and no caller has to remember to.
    func youtubeRead() async -> YouTubePageReply? {
        _ = try? await webView.callAsyncJavaScript(
            YouTubeBridge.installScript, arguments: [:],
            in: nil, contentWorld: PageProtocol.World.page.contentWorld
        )
        return await pageAgent.value(.youtubePage, as: YouTubePageReply.self)
    }

    /// Raises the stage. False when the player isn't there to raise it on.
    func youtubeStage() async -> Bool {
        await pageAgent.value(.youtubeStage, as: Bool.self) ?? false
    }

    func youtubeUnstage() {
        pageAgent.send(.youtubeUnstage)
    }

    func youtubeSetRate(_ rate: Double) {
        pageAgent.send(.youtubeRate, ["rate": rate])
    }

    func youtubeSetCaptions(_ language: String) {
        pageAgent.send(.youtubeCaptions, ["language": language])
    }

    /// The element the stage was applied to, pinned at entry. The ranking
    /// keeps running — a hover-preview or an advert can win it mid-show —
    /// but the transport must describe and command the video on the stage,
    /// not whatever the ranking currently likes.
    @ObservationIgnored private var stagedElementID: String?
    @ObservationIgnored private var stagedFrame: WKFrameInfo?

    /// The staged element's live state, wherever the ranking stands. Nil
    /// once the element is genuinely gone — an SPA route, a torn-out embed,
    /// an anti-adblock script swapping the player out from under the stage.
    ///
    /// Gone is judged by the same heartbeat as the now-playing strip: a
    /// frame reports once a second while playing, so a *playing* entry that
    /// went silent is a ghost — its frame died and will never say so. The
    /// stale state would otherwise describe the swapped-out element forever.
    var stagedMedia: MediaState? {
        guard let stagedElementID else { return nil }
        let cutoff = Date().addingTimeInterval(-4)
        for (_, entry) in mediaFrames {
            if let item = entry.items.first(where: { $0.elementID == stagedElementID }) {
                if item.isPlaying, entry.seenAt < cutoff { return nil }
                return item
            }
        }
        return nil
    }

    @ObservationIgnored private var stageWatchdog: Task<Void, Never>?

    /// The shared half of raising a stage: pin the ranking's current pick,
    /// promote it, lock the page. Used by the theater and the pop-out.
    /// - Parameter keepingInteraction: the theater leaves the player alive
    ///   under the pointer; the pop-out wants the page inert — its own
    ///   chrome is the only control surface.
    fileprivate func beginVideoStage(keepingInteraction: Bool) {
        stagedElementID = mediaElementID
        stagedFrame = mediaFrame
        Task { @MainActor in
            await runOnStagedElement(.mediaStage)
            setPageScrollLocked(true, keepingInteraction: keepingInteraction)
        }
    }

    /// The shared half of lowering one: restore the page, forget the pin.
    /// Harmless when the element is already gone — the unstage method cleans
    /// the stage attributes and sheet regardless, and the main-frame
    /// fallback sweeps a dead iframe's leftovers in the top document.
    fileprivate func endVideoStage() {
        stageWatchdog?.cancel()
        stageWatchdog = nil
        Task { @MainActor in
            await runOnStagedElement(.mediaUnstage)
            setPageScrollLocked(false)
        }
        stagedElementID = nil
        stagedFrame = nil
    }

    /// Lowers the theater when the show is over and nobody said so: the
    /// staged element gone for a few consecutive beats means the page
    /// replaced it, and a stage with nothing on it must not hold the tab.
    private func startStageWatchdog() {
        stageWatchdog?.cancel()
        stageWatchdog = Task { @MainActor in
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, focusVideoStage else { return }
                misses = stagedMedia == nil ? misses + 1 : 0
                if misses >= 3 {
                    debugLog("focus: staged video gone — leaving the theater")
                    exitVideoStage()
                    return
                }
                if misses == 0 {
                    // Re-assert, don't just watch: a player that re-parents
                    // its video (YouTube does, on layout changes) walks it
                    // out from under the tagged ancestor chain. Staging is
                    // idempotent, and re-running it tags the chain the
                    // element lives under *now*.
                    await runOnStagedElement(.mediaStage)
                }
            }
        }
    }

    /// Like `runInMediaFrame`, but addressed to the pinned stage element.
    private func runOnStagedElement(
        _ method: PageProtocol.Method, _ params: [String: Any] = [:]
    ) async {
        guard let stagedElementID else {
            _ = await runInMediaFrame(method, params, as: PageProtocol.Empty.self)
            return
        }
        var params = params
        params["id"] = stagedElementID
        if let stagedFrame {
            do {
                _ = try await pageAgent.call(
                    method, params, as: PageProtocol.Empty.self, in: stagedFrame
                )
                return
            } catch {
                // Fall through to the main frame — same reasoning as the
                // ranking's runner: a gone frame should stop being addressed.
            }
        }
        _ = await pageAgent.value(method, params, as: PageProtocol.Empty.self)
    }

    func stagedToggle() {
        Task { @MainActor in await runOnStagedElement(.mediaToggle) }
    }

    func stagedSeek(to seconds: Double) {
        Task { @MainActor in await runOnStagedElement(.mediaSeek, ["time": seconds]) }
    }

    func stagedSkip(by seconds: Double) {
        Task { @MainActor in await runOnStagedElement(.mediaSkip, ["delta": seconds]) }
    }
    /// The user's lens choice on a recipe page — a recipe page still has
    /// prose, and the toggle lets them read it as an article.
    var focusPrefersArticle = false

    /// This tab's reading voice. On the tab rather than in the lens view, so
    /// switching tabs doesn't stop a reading in progress. Cheap until used —
    /// the synthesiser inside is built on first play.
    @ObservationIgnored let narrator = Narrator()

    /// What the classifier thinks this page is, when it thinks anything.
    /// Advice, not a gate: the menu item works on any page and lets
    /// extraction be the judge.
    private(set) var focusDetection: FocusDetection?

    /// The extraction that proved the pill's promise, kept so honouring it
    /// is instant. The classifier only counts — an index page wearing
    /// `og:type article` over link-heavy teasers counts beautifully and
    /// extracts to nothing — so a reader verdict isn't advertised until the
    /// real extraction has produced a real article.
    @ObservationIgnored private var focusPrevalidated:
        (article: FocusArticle, recipe: FocusRecipe?)?

    @ObservationIgnored private var focusDetectionTask: Task<Void, Never>?

    var isFocusActive: Bool { focusPhase != .inactive }

    /// Whether the quiet affordance should show. Only lenses that exist:
    /// the classifier also reports videos, but advertising a lens that
    /// can't render yet would be a button that lies.
    var canOfferFocus: Bool {
        guard focusPhase == .inactive else { return false }
        // A site Surf has a lens for is offered on sight — no classification
        // to wait for, because the address is already the evidence.
        if focusOfferSite != nil { return true }
        if let detection = focusDetection,
           detection.confidence >= FocusClassification.offerThreshold {
            switch detection.kind {
            case .article, .recipe:
                return true
            case .video:
                // The stage promotes an element the media bridge can
                // address, and the bridge tracks elements from their first
                // play — so the offer waits for one.
                return media?.hasVideo == true
            }
        }
        // No confident classification, but a started video is its own
        // evidence. The detector counts <video> in the main frame only; an
        // embed-host page keeps its video in an iframe the detector can't
        // see — and the media bridge, which runs in every frame, can.
        return offersVideoStage
    }

    /// Whether entering Focus here means the video stage: a started video on
    /// a page the classifier didn't confidently claim for prose, or one it
    /// called a video page outright.
    private var offersVideoStage: Bool {
        guard media?.hasVideo == true else { return false }
        guard let detection = focusDetection,
              detection.confidence >= FocusClassification.offerThreshold
        else { return true }
        return detection.kind == .video
    }

    /// What the pill's icon promises — which lens entering would actually
    /// raise, media evidence included.
    var focusOfferKind: FocusKind? {
        guard canOfferFocus else { return nil }
        return offersVideoStage ? .video : focusDetection?.kind
    }

    func toggleFocus() {
        focusPhase == .inactive ? enterFocus() : exitFocus()
    }

    /// Raises the theater directly — reachable from the reader, because a
    /// page with real prose *and* a playing video classifies as an article
    /// and would otherwise keep the stage unreachable. The iframe case
    /// especially: the embed's video is invisible to the detector, so prose
    /// wins the classification every time.
    func enterVideoStage() {
        guard media?.hasVideo == true else { return }
        narrator.stop()
        focusVideoStage = true
        focusPhase = .active
        beginVideoStage(keepingInteraction: true)
        startStageWatchdog()
        debugLog("focus: video staged from the reader")
    }

    /// Lowers the theater. Back to the reader when the stage was raised from
    /// one; back to the page when the stage was the whole show.
    func exitVideoStage() {
        guard focusVideoStage else { return }
        endVideoStage()
        focusVideoStage = false
        if focusArticle == nil {
            focusPhase = .inactive
        }
    }

    // The pop-out's half of the same machinery: it stages too now — the
    // staged video fills the web view's viewport, so a panel showing the
    // web view shows exactly the video, with no cropping to chase.

    /// Pins and stages for the pop-out. False when there is nothing to show.
    func stageVideoForPopOut() -> Bool {
        guard media?.hasVideo == true else { return false }
        beginVideoStage(keepingInteraction: false)
        return true
    }

    func unstageVideoAfterPopOut() {
        endVideoStage()
    }

    /// Re-tags the staged element's *current* ancestor chain — the pop-out's
    /// tracking loop calls this on its beat, for players that re-parent.
    func reassertStagedVideo() async {
        guard stagedElementID != nil else { return }
        await runOnStagedElement(.mediaStage)
    }

    /// Extracts the page and raises the reader.
    ///
    /// The extractor is installed here — not as a user script — so only pages
    /// the user actually focuses pay for the content walk. Installation is
    /// idempotent (the script guards on the agent's state), which makes
    /// re-entering Focus on the same document a no-op install plus a fresh
    /// extraction.
    func enterFocus() {
        guard mode == .browsing, focusPhase == .inactive else { return }

        // A site with a lens of its own gets it. Ahead of extraction, not
        // after it: a YouTube watch page carries enough prose to extract, and
        // the reader is the wrong answer on every one of them.
        if focusOfferSite != nil {
            enterSiteFocus()
            return
        }

        // A video page gets the stage, not the reader: no extraction — the
        // page's own element is the content, promoted in place.
        if offersVideoStage || focusDetection?.kind == .video {
            guard media?.hasVideo == true else {
                focusPhase = .failed("Start the video, then enter Focus.")
                return
            }
            focusVideoStage = true
            focusPhase = .active
            // Pinned now, while the ranking still points at the video the
            // user actually started — not later, when a preview may have
            // taken the ranking from it.
            beginVideoStage(keepingInteraction: true)
            startStageWatchdog()
            debugLog("focus: video staged")
            return
        }

        focusPhase = .extracting
        Task { @MainActor in
            let article: FocusArticle?
            let cached = focusPrevalidated
            if let cached {
                // The pill's promise was verified by a real extraction
                // moments ago; honouring it re-uses that work, which is why
                // the reader opens instantly from the pill.
                article = cached.article
            } else {
                article = await extractFocusArticle()
            }
            // The user may have left Focus, or the page, while that ran.
            guard focusPhase == .extracting else { return }
            guard let article else {
                focusPhase = .failed("This page couldn't be read.")
                return
            }
            // A recipe stands on its structured data, not on prose volume —
            // plenty of real recipe pages are thin on paragraphs and rich in
            // JSON-LD, and `parse` already refuses the hollow ones.
            let recipe = cached != nil
                ? cached?.recipe
                : FocusRecipe.parse(fromJSONLD: article.jsonLD)
            // A title over sixty words of boilerplate is a failure wearing a
            // heading — better to say so than to render it with confidence.
            guard article.isSubstantial || recipe != nil else {
                focusPhase = .failed("There isn't an article to focus on here.")
                debugLog("focus: declined — \(article.wordCount) words extracted")
                return
            }
            focusArticle = article
            focusRecipe = recipe
            focusPrefersArticle = false
            focusPhase = .active
            if let recipe {
                debugLog("""
                    focus: recipe — \(recipe.ingredients.count) ingredients, \
                    \(recipe.steps.count) steps — \"\(recipe.title)\"
                    """)
            }
            // Listen is one tap away now; pay the voice's model load while
            // the user is still reading the first paragraph.
            narrator.warmUp()
            debugLog("""
                focus: extracted \(article.blocks.count) blocks, \
                \(article.wordCount) words from \(article.rootPath) — \
                \"\(article.title)\"
                """)
        }
    }

    /// - Parameter blockIndex: the block at the top of the reader, so leaving
    ///   Focus lands the page on the passage being read rather than wherever
    ///   its scroll position happened to be.
    func exitFocus(revealingBlock blockIndex: Int? = nil) {
        guard focusPhase != .inactive else { return }
        // A site lens has a page underneath it that is still live and still
        // staged; handing it back is its own business.
        if focusSite != nil {
            exitSiteFocus()
            return
        }
        narrator.stop()
        if focusVideoStage {
            // Back exactly as the page drew it.
            endVideoStage()
        }
        focusVideoStage = false
        focusPhase = .inactive
        focusArticle = nil
        focusRecipe = nil
        focusPrefersArticle = false
        if let blockIndex {
            isolatedAgent.send(.focusReveal, ["index": blockIndex])
        }
    }

    /// Asks the page what it looks like, on the same short ladder as top-colour
    /// sampling: articles hydrate late, and the first reading routinely lands
    /// before the prose does. Each rung re-classifies, so the verdict improves
    /// rather than freezes.
    ///
    /// A reader verdict is verified before it's advertised: the extraction
    /// runs now, and a page whose article turns out to be nothing keeps its
    /// pill hidden — a button whose click says "there's nothing here" should
    /// not have been a button. The verified result is kept, so the pill
    /// opens the reader instantly.
    private func scheduleFocusDetection() {
        focusDetectionTask?.cancel()
        // A site lens is already the answer for this page, whether or not it
        // is open yet: the pill offers it from the address alone, and
        // `enterFocus` routes to it before extraction is considered. So
        // nothing on a site Surf has a lens for ever reads the classifier's
        // verdict — and on a watch page it would spend the extractor's
        // content walk, the most expensive thing Focus runs anywhere, to
        // produce it.
        guard focusSite == nil,
              SiteFocusSite.matching(liveWebView?.url) == nil
        else { return }
        focusDetectionTask = Task { @MainActor in
            for delay in [700, 2400] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                guard let signals = await isolatedAgent.value(
                    .focusSignals, as: FocusSignals.self
                ) else { continue }
                let verdict = FocusClassification.classify(signals)
                if verdict != focusDetection, let verdict {
                    debugLog("""
                        focus: \(verdict.kind.rawValue) \(verdict.confidence) — \
                        \(signals.wordCount) words in \(signals.paragraphCount) paragraphs
                        """)
                }

                guard let verdict, verdict.kind != .video,
                      verdict.confidence >= FocusClassification.offerThreshold,
                      focusPhase == .inactive
                else {
                    focusDetection = verdict
                    continue
                }
                // Already proved on an earlier rung; don't extract twice.
                if focusPrevalidated != nil {
                    focusDetection = verdict
                    continue
                }
                guard let article = await extractFocusArticle(), !Task.isCancelled
                else { continue }
                let recipe = FocusRecipe.parse(fromJSONLD: article.jsonLD)
                if article.isSubstantial || recipe != nil {
                    focusPrevalidated = (article, recipe)
                    focusDetection = verdict
                } else {
                    focusDetection = nil
                    debugLog("""
                        focus: \(verdict.kind.rawValue) verdict withheld — \
                        extraction found \(article.wordCount) words
                        """)
                }
            }
        }
    }

    /// Installs the extractor (idempotent) and runs it — the one extraction
    /// path, shared by pre-validation and by entering Focus by hand.
    private func extractFocusArticle() async -> FocusArticle? {
        _ = try? await webView.callAsyncJavaScript(
            FocusBridge.extractorScript, arguments: [:],
            in: nil, contentWorld: .defaultClient
        )
        return await isolatedAgent.value(.focusExtract, as: FocusArticle.self)
    }

    /// The page under the reader is gone or changing; nothing about the old
    /// one may survive onto the new.
    /// - Parameter keepingSiteLens: a site lens navigating on its own behalf.
    ///   Everything belonging to the *old document* still goes — the pin, the
    ///   detection, the extraction — but the lens itself stays up, because
    ///   the load it is surviving is one it asked for.
    private func resetFocus(keepingSiteLens: Bool = false) {
        narrator.stop()
        focusDetectionTask?.cancel()
        focusDetection = nil
        focusPrevalidated = nil
        // Not exitFocus(): there is no page position worth revealing, and the
        // agent may already be unreachable.
        focusArticle = nil
        focusRecipe = nil
        focusPrefersArticle = false
        // A staged element died with its document; there is nothing to
        // unstage, and the pin must not survive onto the next page.
        stageWatchdog?.cancel()
        stageWatchdog = nil
        focusVideoStage = false
        stagedElementID = nil
        stagedFrame = nil
        guard !keepingSiteLens else { return }
        // No unstage here either, and for the same reason: this path is a
        // document that has already gone. Leaving by hand is `exitSiteFocus`.
        youtubeLens = nil
        focusSite = nil
        focusPhase = .inactive
    }

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
        // An armed capture pick dies with its document — the agent's
        // listeners just did, and a veil with nobody reporting hovers into
        // it would sit there dimming the new page forever.
        cancelAreaCapture()
        // A new document: whatever the model named the old one is wrong now.
        aiNamingTask?.cancel()
        aiTitle = nil
        // Something arrived, so this is a window with a page in it.
        hasCommittedDocument = true
        emptyPopupWatchdog?.cancel()
        if !blockLog.isEmpty { blockLog = BlockLog() }
        // A new document: the reader would otherwise sit over a page it no
        // longer describes. A site lens is the exception — the load is one it
        // asked for — but only while the address still belongs to its site, so
        // a link out of YouTube closes the lens rather than framing the web.
        let lensSurvives = focusSite?.claims(webView.url) == true
        if lensSurvives { youtubeLens?.documentWillChange() }
        resetFocus(keepingSiteLens: lensSurvives)
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
        scheduleAINaming()
        scheduleFocusDetection()
        // The lens reads the page it just asked for. After `scheduleFocus-
        // Detection` deliberately: the two never both run, because a tab in a
        // site lens is not `.inactive` and the detector's work is discarded.
        youtubeLens?.documentDidLoad()
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

    /// The one place a tab learns where it is going before any of the
    /// page's requests go out: the lists for the destination are settled here,
    /// so a tab leaving a paused site is blocked from its first subresource
    /// and one arriving at a paused site isn't. `didStartProvisionalNavigation`
    /// is too late — the main resource is already in flight by then.
    ///
    /// The download answer is what WebKit gives when no delegate answers at
    /// all, kept so adding this changes nothing else.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.targetFrame?.isMainFrame == true,
           let host = navigationAction.request.url?.host {
            blockingHost = host
            if ContentBlocker.shared.isActive(for: host) != isBlocking {
                applyBlockingRules(for: host)
            }
        }
        return (navigationAction.shouldPerformDownload ? .download : .allow, preferences)
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
        tab.openerTabID = id
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

import SurfCore
import SwiftUI

struct ContentView: View {
    let session: BrowserSession

    @AppStorage(PreferenceKeys.sidebarPinned) private var isPinned = false

    /// Whether the pointer currently has the floating sidebar revealed. The
    /// traffic lights need no state of their own: they sit just above the
    /// panel's top-left corner and show exactly when it does.
    @State private var isHoverRevealed = false
    @State private var pointer = ChromePointer()
    @State private var revealTask: Task<Void, Never>?
    /// The sidebar's one unprompted appearance, so a window that opens with no
    /// chrome at all still shows you where everything — the window controls
    /// included — now lives.
    @State private var isIntroducingSidebar = false
    @State private var palette: PalettePhase = .closed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Captured when the palette opens, because the session's flag may have
    /// changed again by the time it's submitted.
    @State private var paletteCreatesTab = false
    @State private var sidebarHold = SidebarHold()
    @State private var isFindBarOpen = false
    @State private var findBarFocusToken = 0
    @State private var tabKeyMonitor: Any?
    /// The in-flight tab drag. Owned here rather than in the sidebar because a
    /// drag that starts on a row can end on the page: both the rows and the
    /// split drop zones have to be looking at the same one.
    @State private var dragContext = TabDragContext()
    /// What the window's own buttons actually measure, reported by
    /// `TrafficLights` as AppKit lays them out. The sidebar holds this much of
    /// its top row open for them.
    @State private var lightsSpan: CGFloat = Sidebar.lightsWidth

    /// The pointer report, with the sidebar's hold folded in.
    ///
    /// The hold keeps the sidebar up while something it opened is still on
    /// screen — a popover lives in its own window, so reaching into it counts
    /// as leaving the sidebar.
    private var pointerNow: ChromePointer {
        var pointer = self.pointer
        pointer.sidebarHeld = sidebarHold.isHeld
        return pointer
    }

    private var isSidebarRevealed: Bool { isHoverRevealed || isIntroducingSidebar }

    /// The lights show whenever the sidebar does — pinned counts, since a
    /// pinned sidebar is permanently on screen.
    private var areLightsRevealed: Bool { isPinned || isSidebarRevealed }

    /// Clear of the sidebar's top bar, so a find bar can never sit under one.
    private var overlayTopInset: CGFloat {
        Sidebar.floatingTopPadding
            + Sidebar.topBarTopPadding(isFloating: true)
            + Sidebar.topRowHeight
            + 10
    }

    /// Where the lights' row begins, from the window's leading edge.
    ///
    /// The buttons sit *in* the sidebar's top row now rather than above the
    /// panel, which means they line up on the panel's own gutter — and the
    /// panel's leading edge moves depending on whether it is pinned. AppKit
    /// positions them in window coordinates and knows nothing about either, so
    /// the sum is made here.
    private var lightsLeadingInset: CGFloat {
        (isPinned ? 0 : Sidebar.floatingLeadingPadding) + Sidebar.horizontalPadding
    }

    /// The centre of the lights' row, from the window's top: whatever sits
    /// above the top bar, plus half the row itself.
    private var lightsRowCenter: CGFloat {
        let isFloating = !isPinned
        let above = (isFloating ? Sidebar.floatingTopPadding : 0)
            + Sidebar.topBarTopPadding(isFloating: isFloating)
        return above + Sidebar.topRowHeight / 2
    }

    var body: some View {
        ZStack {
            // One glass surface behind everything, so a pinned sidebar and the
            // page read as the same material.
            WindowGround(material: .underWindowBackground)

            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if isPinned {
                        sidebar(isFloating: false)
                        Divider()
                    }
                    tabContent
                }

                if !isPinned {
                    HoverZone { pointer.inEdge = $0 }
                        .frame(width: ChromeReveal.edgeZoneWidth)
                        .frame(maxHeight: .infinity, alignment: .leading)

                    if isSidebarRevealed {
                        floatingSidebar
                    }
                }
            }

            // Not a rendered view: this reaches out to the window and fades the
            // real AppKit buttons, which draw above everything here — perched
            // just above the floating panel, or on the row a pinned one holds
            // clear at its top.
            TrafficLights(
                isRevealed: areLightsRevealed,
                leadingInset: lightsLeadingInset,
                rowCenterFromTop: lightsRowCenter,
                onMeasure: { lightsSpan = $0 }
            )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)

            if isFindBarOpen {
                FindBar(tab: session.selectedTab, isPresented: $isFindBarOpen)
                    // Identity includes the focus token so a repeat ⌘F rebuilds
                    // the bar focused, rather than opening a second one.
                    .id(findBarFocusToken)
                    .padding(.top, overlayTopInset)
                    .padding(.trailing, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(18)
            }

            // Above the page and the sidebar, below the palette: it's a
            // property of the window, not of anything inside it.
            LoadingBorder(tab: session.selectedTab)
                .zIndex(15)

            if palette == .open {
                // Its own layer, fading on its own clock: quicker than the card
                // on the way out, and never scaled with it.
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { closePalette(.dismiss) }
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.18)),
                        removal: .opacity.animation(.easeIn(duration: 0.12))
                    ))
                    .zIndex(19)
            }

            if palette != .closed {
                // The traffic lights render above SwiftUI content, so if the
                // palette opens while they're revealed they stay visible and
                // clickable over its backdrop.
                URLPalette(
                    session: session,
                    tab: session.selectedTab,
                    createsTab: paletteCreatesTab,
                    onClose: closePalette
                )
                    .modifier(PaletteExit(leaving: palette.leaving))
                    .allowsHitTesting(palette == .open)
                    .transition(paletteTransition)
                    .zIndex(20)
            }
        }
        // Hidden titlebar with full-size content, so the page runs to every
        // window edge — nothing is reserved above it any more.
        .ignoresSafeArea()
        // The title lives on a leaf view so that only it observes
        // `displayTitle` — a page animating its title ("(3) Inbox…") would
        // otherwise re-evaluate this entire chrome body every tick.
        .background { WindowTitle(tab: session.selectedTab) }
        .onChange(of: pointerNow) { _, pointer in
            scheduleReveal(ChromeReveal.shouldReveal(pointer))
        }
        // Pinning mid-hover would otherwise leave a stale floating copy behind.
        .onChange(of: isPinned) { _, _ in
            revealTask?.cancel()
            isHoverRevealed = false
        }
        // ⌘L routes through the session so the menu command reaches whichever
        // window is frontmost.
        .onChange(of: session.findToken) { _, _ in
            withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                isFindBarOpen = true
            }
            findBarFocusToken += 1
        }
        .onChange(of: session.findStepToken) { _, _ in
            // ⌘G with no bar open is still a find request.
            guard isFindBarOpen else {
                session.requestFind()
                return
            }
            NotificationCenter.default.post(
                name: .surfFindStep,
                object: session.findStepsForward
            )
        }
        // A find is about one page; carrying the bar to another tab would
        // search something you never asked it to.
        // Presented from the window rather than from the strip that opens it:
        // a floating sidebar hides when the pointer leaves, and a sheet anchored
        // to it would go with it — taking the emoji viewer and colour panel's
        // reason for being open with it.
        .islandEditor(session: session)
        .onChange(of: session.selectedTabID) { _, _ in
            isFindBarOpen = false
        }
        .onChange(of: session.focusAddressToken) { _, _ in
            paletteCreatesTab = session.addressFocusCreatesTab
            // Home has the real field on the page, and it is watching this same
            // token — so asking for the address bar there means focusing it,
            // not floating a second one over the top. Everywhere else the
            // palette is the only way to type over a page without displacing
            // it, which is the whole reason it floats.
            guard session.selectedTab.mode != .home else { return }
            openAddressBar()
        }
        .onAppear(perform: introduceSidebar)
        .onAppear(perform: applyLaunchEnvironment)
        .onAppear(perform: installTabCycleMonitor)
        .onDisappear {
            if let tabKeyMonitor { NSEvent.removeMonitor(tabKeyMonitor) }
            tabKeyMonitor = nil
        }
    }

    private func sidebar(isFloating: Bool) -> some View {
        Sidebar(
            session: session,
            isPinned: $isPinned,
            isFloating: isFloating,
            hold: sidebarHold,
            dragContext: dragContext,
            lightsSpan: lightsSpan
        )
    }

    /// The window is nothing but the page now — no toolbar above it.
    private var tabContent: some View {
        SplitContent(
            session: session,
            drag: dragContext,
            // The floating panel plus its leading inset — the exact strip of
            // page the chrome is sitting on top of.
            chromeInset: (!isPinned && isSidebarRevealed)
                ? Sidebar.width + Sidebar.floatingLeadingPadding
                : 0
        )
        // Deliberately *no* `.id(tab.id)` here. Tying identity to the tab is
        // the obvious way to make a switch mount the right page, and it made
        // every switch destroy the whole subtree — rebuilding the container and
        // pulling a live web view out of the window on its way past. The
        // container tracks the current tab itself, and keeps the last few pages
        // mounted so going back to one is a visibility flip.
    }

    private var floatingSidebar: some View {
        sidebar(isFloating: true)
            // The sidebar is chrome floating over the page — the case Liquid
            // Surf exists for. Not `interactive`: that's for controls, and a
            // whole panel reacting to the pointer reads as wobbly rather than
            // responsive.
            .glassEffect(.regular, in: sidebarShape)
            // Surf alone is thin enough that a busy page reads straight
            // through the tab titles. The material sits *behind* the glass —
            // applied after it, so it renders underneath — giving the panel
            // back its body while the glass keeps the edge and the highlights.
            // Reach for .thickMaterial here if a page still shows through.
            .background { sidebarShape.fill(.regularMaterial) }
            .shadow(color: .black.opacity(0.28), radius: 20, x: 6, y: 4)
            .padding(.top, Sidebar.floatingTopPadding)
            .padding(.bottom, 10)
            .padding(.leading, Sidebar.floatingLeadingPadding)
            .transition(.move(edge: .leading).combined(with: .opacity))
            .onHover { pointer.inSidebar = $0 }
            .zIndex(1)
    }

    /// ⌃⇥ and ⌃⇧⇥ cycle tabs, as they do in every browser.
    ///
    /// A local monitor rather than a menu item: Tab is a focus key, so AppKit
    /// routes it through the responder chain before menus ever see it, and a
    /// menu entry for it would sit in the menu bar reading like nonsense.
    private func installTabCycleMonitor() {
        guard tabKeyMonitor == nil else { return }
        tabKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags

            if flags.contains(.control), event.keyCode == 48 {  // ⇥
                MainActor.assumeIsolated {
                    flags.contains(.shift)
                        ? session.selectPreviousTab()
                        : session.selectNextTab()
                }
                return nil
            }

            // ⌘= as well as ⌘+. The menu can only advertise one, and every
            // browser takes both — the plus is the shifted equals key, so on a
            // US layout they're the same physical press either way.
            if flags.contains(.command), !flags.contains(.control),
               event.keyCode == 24 {  // =
                MainActor.assumeIsolated { session.selectedTab.zoomIn() }
                return nil
            }

            // Escape backs out of whatever the selected tab has armed —
            // wherever the key lands. The page script already cancels a
            // screenshot pick when the web view has focus; this covers the
            // sidebar, the lights, and every other view that would otherwise
            // keep the key for itself. Consumed only when it did something,
            // so the palette, the find bar, and pages keep their Escape.
            if event.keyCode == 53,  // ⎋
               flags.intersection(.deviceIndependentFlagsMask).isEmpty,
               Self.escapeMayDismissTabState(in: event.window) {
                let handled = MainActor.assumeIsolated {
                    session.selectedTab.dismissTransientState()
                }
                return handled ? nil : event
            }

            return event
        }
    }

    /// Whether an Escape in this window is ours to spend. A text field is
    /// closing a palette or a find bar with it; a mini window is closing
    /// itself; neither should find the reader gone as well.
    private static func escapeMayDismissTabState(in window: NSWindow?) -> Bool {
        guard let window, !(window is MiniWindowPanel) else { return false }
        return !(window.firstResponder is NSTextView)
    }

    private var sidebarShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    /// How the palette arrives, and how it leaves when it leaves by removal.
    ///
    /// The same way in from everywhere — ⌘L, the sidebar's address pill, a new
    /// tab. Growing out of the pill was tried and dropped: the bar travelling
    /// across the window from the sidebar drew the eye to the trip rather than
    /// to the field, and the drop-in gets to typing sooner.
    ///
    /// No exit uses the removal half. Each one animates the palette out in
    /// place (`PaletteExit`) and removes it afterwards, unanimated, because
    /// which exit it is — lift or dismiss — is only known at the moment of
    /// leaving, and a removal transition is fixed before then.
    private var paletteTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .modifier(
                active: PaletteDrop(isDropping: true),
                identity: PaletteDrop(isDropping: false)
            ),
            removal: .identity
        )
    }

    private func openAddressBar() {
        let animation: Animation = reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.28)
        // Asked for again while it was on its way out, it comes back from
        // wherever it had got to rather than starting over.
        guard palette != .open else { return }
        withAnimation(animation) { palette = .open }
    }

    /// Exits run faster than the entrance, which is the convention that makes
    /// an interface feel responsive: arriving can take a beat to show where
    /// something came from, leaving shouldn't keep you waiting.
    private func closePalette(_ reason: PaletteClose) {
        guard palette == .open else { return }
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.15)) { palette = .closed }
            return
        }
        // A submit lifts toward twelve o'clock, where the loading border is
        // about to start: the border's grace period is shorter than the lift,
        // so the one hands over to the other.
        withAnimation(.easeIn(duration: reason == .submit ? 0.18 : 0.16)) {
            palette = .leaving(reason)
        } completion: {
            if palette == .leaving(reason) { palette = .closed }
        }
    }

    /// Commits a resolved target after its delay, cancelling whatever was
    /// pending — so a pointer sweeping up the edge to the corner settles on the
    /// lights rather than flashing the sidebar on the way past.
    private func scheduleReveal(_ reveal: Bool) {
        guard reveal != isHoverRevealed else {
            revealTask?.cancel()
            return
        }
        revealTask?.cancel()
        revealTask = Task { @MainActor in
            try? await Task.sleep(for: ChromeReveal.delay(revealing: reveal))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                isHoverRevealed = reveal
            }
        }
    }

    /// Shows the sidebar once when the window opens, then lets it go.
    ///
    /// Without this the window arrives with no visible chrome at all — and the
    /// sidebar is where everything lives now, the window controls included, so
    /// its one unprompted turn is what suggests the edge is worth reaching for.
    private func introduceSidebar() {
        guard !isPinned else { return }
        isIntroducingSidebar = true
        Task { @MainActor in
            try? await Task.sleep(for: ChromeReveal.launchRevealDuration)
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                isIntroducingSidebar = false
            }
        }
    }

    /// Dev affordance: `SURF_URL=example.com swift run` opens straight to a
    /// page. Comma-separate to open several tabs at once.
    private func applyLaunchEnvironment() {
        guard let start = ProcessInfo.processInfo.environment["SURF_URL"], !start.isEmpty
        else { return }
        let targets = start.split(separator: ",").map(String.init)
        // The tab the first URL loads into. Not `tabs.first`: with a restored
        // session that's whatever survived from last time, and both the
        // selection below and the affordances after it were acting on a page
        // nobody asked for.
        let primary = session.selectedTab
        for (offset, target) in targets.enumerated() {
            let tab = offset == 0 ? primary : session.addTab()
            tab.submit(target)
        }
        session.select(primary)
        openDevToolsIfAsked(on: primary)
        enterFocusIfAsked(on: primary)
        downloadMediaIfAsked(on: primary)
    }

    /// Dev affordance: `SURF_FOCUS=1` alongside `SURF_URL` enters Focus on
    /// that page once it has loaded — the extractor is otherwise only
    /// reachable by hand, and it is the largest thing Focus runs in a page.
    /// `SURF_FOCUS=2` also starts narration (`SURF_SILENT=1` mutes it), which
    /// is how the whole speech pipeline gets exercised from the command line.
    private func enterFocusIfAsked(on tab: Tab) {
        let want = ProcessInfo.processInfo.environment["SURF_FOCUS"]
        guard want == "1" || want == "2" else { return }
        Task { @MainActor in
            // After the load settles, not on a stopwatch: extracting a page
            // that is still streaming in reads only the part that arrived.
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(500))
                if tab.mode == .browsing, !tab.isLoading { break }
            }
            try? await Task.sleep(for: .seconds(1))
            tab.enterFocus()
            guard want == "2" else { return }
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                if case .active = tab.focusPhase { break }
            }
            guard let article = tab.focusArticle else { return }
            tab.narrator.toggle(reading: article)
        }
    }

    /// Dev affordance: `SURF_DOWNLOAD=1` alongside `SURF_URL` saves whatever is
    /// playing on that page, once it is playing. `SURF_DOWNLOAD=2` also presses
    /// retry once if it fails, which is the only way to reach the resume path
    /// without a human clicking — resuming only exists within a session, so a
    /// fresh launch has nothing to come back to. `SURF_DOWNLOAD_PICK=<height>`
    /// or `=audio` takes a row from the quality menu instead of letting the
    /// engine decide.
    ///
    /// Downloads were the one feature with no way in from the command line, which
    /// made the whole stream engine — manifest, plan, segments, mux, check —
    /// provable only by a human clicking a button and describing what happened.
    /// That is not a reasonable way to verify several hundred parallel requests
    /// and a muxer.
    ///
    /// It goes through `downloadMedia(from:)`, the same method the button calls,
    /// so what it exercises is the real routing rather than a path of its own.
    private func downloadMediaIfAsked(on tab: Tab) {
        let want = ProcessInfo.processInfo.environment["SURF_DOWNLOAD"]
        guard want == "1" || want == "2" else { return }
        Task { @MainActor in
            // Waits for a media report rather than for the load, because the
            // routing reads `tab.media` and a page that has loaded has not
            // necessarily started playing.
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(500))
                if tab.media != nil { break }
            }
            guard let media = tab.media else {
                debugLog("download: nothing playing to save")
                return
            }
            // What the menu would show. Logged before downloading because the
            // menu itself only opens on a click, and nothing else exercises the
            // list it is built from.
            let offered = await DownloadManager.shared.options(for: tab)
            let rows = DownloadOptions.video(from: offered.options)
            for row in rows.prefix(8) {
                debugLog("menu: \(row.title) — \(row.detail(duration: offered.duration))")
            }
            if let sound = DownloadOptions.audio(from: offered.options) {
                debugLog("menu: \(sound.title) — \(sound.detail(duration: offered.duration))")
            }

            debugLog("download: saving \(media.kind) \(media.sourceURL)")
            // `SURF_DOWNLOAD_PICK=720` takes that row, and `=audio` the sound.
            // The menu is the one part of this feature that needs a click, so
            // without this the choice reached the engine only in unit tests and
            // the plumbing between them was unproven — which is how a chosen
            // quality came to be honoured on YouTube and silently ignored
            // everywhere else.
            let asked = ProcessInfo.processInfo.environment["SURF_DOWNLOAD_PICK"]
            var chosen: DownloadOption?
            if let asked {
                chosen = asked == "audio"
                    ? DownloadOptions.audio(from: offered.options)
                    : rows.first { $0.height == Int(asked) }
                if let chosen {
                    debugLog("download: chose \(chosen.title) (\(chosen.id))")
                } else {
                    // Said rather than passed over, so a run cannot look like it
                    // proved a choice when it fell back to the default pick.
                    debugLog("download: no row for \(asked); taking the engine's pick")
                }
            }
            DownloadManager.shared.downloadMedia(from: tab, choosing: chosen)
            guard want == "2" else { return }

            // The row is created synchronously by the start, so it is already
            // there to watch.
            guard let item = DownloadManager.shared.activeItem(for: tab) else {
                debugLog("download: nothing to retry")
                return
            }
            for _ in 0..<240 {
                try? await Task.sleep(for: .milliseconds(500))
                if !item.isActive { break }
            }
            guard case .failed(let message) = item.state else {
                debugLog("download: finished without needing a retry")
                return
            }
            debugLog("download: failed — \(message)")
            // A pause before retrying, both because a person would take one and
            // because a test needs a window in which to change what the server
            // will do. Without it the retry races the failure it is reacting to.
            try? await Task.sleep(for: .seconds(10))
            debugLog("download: retrying")
            DownloadManager.shared.retry(item, in: tab)
        }
    }

    /// Dev affordance: `SURF_DEVTOOLS=console` alongside `SURF_URL` opens the
    /// panel on the first tab at launch, on the named pane. `1` means Console.
    ///
    /// The injected half of dev tools only exists while a panel is attached,
    /// so without this there is no way to exercise it except by hand — and the
    /// scripts it installs are the largest thing Surf puts into a page.
    private func openDevToolsIfAsked(on tab: Tab) {
        guard let want = ProcessInfo.processInfo.environment["SURF_DEVTOOLS"],
              !want.isEmpty
        else { return }
        let pane = DevToolsSession.Pane(rawValue: want) ?? .console
        Task { @MainActor in
            // After the first document commits: attaching to `about:blank` and
            // then navigating is a different path from attaching to a page.
            try? await Task.sleep(for: .seconds(2))
            DevToolsController.shared.open(tab, pane: pane)
        }
    }
}

// MARK: - Split

/// The page area: one tab filling it, or two side by side.
///
/// Its own view so that the split state — read on every drag frame by the drop
/// zones — doesn't make the whole window chrome an observer of it.
private struct SplitContent: View {
    let session: BrowserSession
    let drag: TabDragContext
    let chromeInset: CGFloat

    var body: some View {
        ZStack {
            if let split = session.split,
               let leading = session.tab(split.leading),
               let trailing = session.tab(split.trailing) {
                HStack(spacing: 0) {
                    pane(leading, side: .leading)
                    Divider()
                    pane(trailing, side: .trailing)
                }
            } else {
                pane(session.selectedTab, side: nil)
            }

            // Only while a tab is actually being carried. A permanent overlay
            // would be a second view sitting on the page for the sake of
            // something that happens for two seconds at a time — and, being
            // above it, would have to be reasoned about on every click.
            if drag.isDraggingLoneTab {
                SplitDropZones(session: session, drag: drag)
                    .transition(.opacity)
                    .zIndex(5)
            }
        }
        .animation(.snappy(duration: 0.28, extraBounce: 0), value: session.split)
        .animation(.easeOut(duration: 0.15), value: drag.isDraggingLoneTab)
    }

    /// One half — or the whole window when `side` is nil.
    private func pane(_ tab: Tab, side: SplitPanes.Side?) -> some View {
        let isFocused = tab.id == session.selectedTabID

        return TabContent(
            tab: tab,
            session: session,
            // Only the leading pane sits under the floating sidebar.
            chromeInset: side == .trailing ? 0 : chromeInset,
            // The page stands down for the length of a drag so the zones above
            // it can receive the drop — but only while there are zones to
            // receive it. Dragging the pair as a unit has no meaning over the
            // page, so the page keeps working.
            isInert: drag.isDraggingLoneTab,
            onOpenAddressBar: { session.requestAddressFocus() }
        )
        .overlay {
            // Which half the typing goes to has to be visible, or the address
            // bar and ⌘F act on a page the user isn't looking at. Drawn as an
            // inset hairline rather than a border on the pane, so it doesn't
            // take a pixel away from the page.
            if side != nil {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        Color.accentColor.opacity(isFocused ? 0.55 : 0),
                        lineWidth: 2
                    )
                    .padding(1)
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.18), value: isFocused)
            }
        }
        // Clicking the unfocused half focuses it. A plain tap gesture would
        // swallow the click the page should have had, so this reads the press
        // without consuming it.
        .modifier(FocusPaneOnClick(enabled: side != nil && !isFocused) {
            session.select(tab)
        })
    }
}

/// Makes an unfocused pane focusable by clicking anywhere in it.
///
/// `simultaneousGesture` rather than `onTapGesture`: the click that moves focus
/// should also do whatever it was aimed at on the page — following a link in
/// the other pane is one action to the user, not "focus, then click again".
private struct FocusPaneOnClick: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.simultaneousGesture(
                DragGesture(minimumDistance: 0).onEnded { _ in action() }
            )
        } else {
            content
        }
    }
}

/// The two halves of the page area, live only while a tab is being dragged.
///
/// Splitting on drop is the only gesture here, so the zones exist only during
/// a drag and the page is inert underneath them for exactly that long.
private struct SplitDropZones: View {
    let session: BrowserSession
    let drag: TabDragContext

    @State private var hovered: SplitPanes.Side?

    var body: some View {
        HStack(spacing: 0) {
            zone(.leading)
            zone(.trailing)
        }
    }

    private func zone(_ side: SplitPanes.Side) -> some View {
        let isHovered = hovered == side
        let isNoop = !canDrop(on: side)

        return ZStack {
            Color.clear
            if isHovered, !isNoop {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
                    }
                    .overlay { label(side) }
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onDrop(of: [.text], delegate: SplitDropDelegate(
            side: side,
            session: session,
            drag: drag,
            hovered: $hovered
        ))
        .animation(.easeOut(duration: 0.14), value: isHovered)
    }

    private func label(_ side: SplitPanes.Side) -> some View {
        VStack(spacing: 8) {
            Image(systemName: side == .leading
                ? "rectangle.lefthalf.inset.filled"
                : "rectangle.righthalf.inset.filled")
                .font(.system(size: 26, weight: .light))
            Text(session.isSplit ? "Replace This Pane" : "Split Here")
                .font(.callout.weight(.medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            Capsule().fill(Color.black.opacity(0.45))
        }
    }

    /// Whether dropping here would change anything — dropping a tab onto the
    /// half already showing it is a no-op, and the zone shouldn't light up
    /// promising otherwise.
    private func canDrop(on side: SplitPanes.Side) -> Bool {
        guard let dragged = drag.draggedID else { return false }
        if let split = session.split { return split.tab(on: side) != dragged }
        // Not split yet: the dragged tab would land beside the current page,
        // and it can't be the current page.
        return dragged != session.selectedTabID
    }
}

private struct SplitDropDelegate: DropDelegate {
    let side: SplitPanes.Side
    let session: BrowserSession
    let drag: TabDragContext
    @Binding var hovered: SplitPanes.Side?

    func dropEntered(info: DropInfo) { hovered = side }

    func dropExited(info: DropInfo) {
        if hovered == side { hovered = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            hovered = nil
            drag.end()
        }
        guard let id = drag.draggedID,
              let tab = session.tabs.first(where: { $0.id == id })
        else { return false }
        withAnimation(.snappy(duration: 0.3, extraBounce: 0)) {
            session.openSplit(with: tab, on: side)
        }
        return true
    }
}

/// One tab's content: the home search screen, or the bare page.
private struct TabContent: View {
    let tab: Tab
    let session: BrowserSession
    let chromeInset: CGFloat
    /// Stands the page down while a tab is being dragged over it.
    var isInert: Bool = false
    let onOpenAddressBar: () -> Void

    var body: some View {
        Group {
            switch tab.mode {
            case .home:
                EmptyTabView(session: session, tab: tab)
                    // Above the page during the crossfade, so the reveal is the
                    // sea thinning over the loaded page rather than the page
                    // popping in beside it.
                    .zIndex(1)
                    .transition(.opacity)
            case .browsing:
                ZStack {
                    if PopOutController.shared.isPoppedOut(tab) {
                        // The web view itself now lives in the pop-out panel; it
                        // can only be in one hierarchy at a time.
                        PoppedOutPlaceholder(tab: tab)
                    } else {
                        WebView(
                            webView: tab.webView,
                            chromeInset: chromeInset,
                            isInert: isInert,
                            viewportOverride: tab.emulatedViewport
                        )
                    }
                    if let error = tab.lastError {
                        ErrorOverlay(message: error) { tab.reload() }
                    }

                    // The reader, over the live page. The web view stays
                    // mounted underneath so leaving Focus is a fade, not a
                    // reload — same reasoning as the dev tools highlight.
                    if tab.focusPhase != .inactive {
                        FocusOverlay(tab: tab)
                            .transition(.opacity)
                            .zIndex(2)
                    } else if tab.canOfferFocus {
                        // Bottom-trailing: out of the find bar's corner and
                        // clear of every site's own top chrome.
                        FocusPill(tab: tab)
                            .padding(.bottom, 16)
                            .padding(.trailing, 16)
                            .frame(
                                maxWidth: .infinity, maxHeight: .infinity,
                                alignment: .bottomTrailing
                            )
                            .transition(.opacity)
                            .zIndex(2)
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: tab.focusPhase)
                .animation(.easeInOut(duration: 0.22), value: tab.canOfferFocus)
            }
        }
        // What makes the dive's reveal a crossfade: the mode flip swaps the
        // views, and this is the timing both sides swap under. Slow enough to
        // read as the sea thinning, quick enough not to feel like a curtain.
        .animation(.easeInOut(duration: 0.6), value: tab.mode)
        // A restored tab loads the first time it's actually shown, not at launch.
        //
        // Keyed on the tab rather than on appearance: this view is no longer
        // rebuilt per tab, so `onAppear` would fire once for whichever tab was
        // selected at launch and leave every other restored tab blank forever.
        .onChange(of: tab.id, initial: true) { _, _ in
            tab.activateRestoreIfNeeded()
        }
    }
}

/// Stands in for a tab whose web view has been moved into the pop-out panel.
private struct PoppedOutPlaceholder: View {
    let tab: Tab

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("Playing in a pop-out window")
                .font(.title3.weight(.medium))
            Text(tab.displayTitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("Bring Back") { PopOutController.shared.restore() }
                .buttonStyle(.glassProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

/// Shown when a navigation fails outright, so the user isn't left staring at a
/// blank white web view with no explanation.
private struct ErrorOverlay: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Couldn't load that page")
                .font(.title3.weight(.medium))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Try Again", action: retry)
                .buttonStyle(.glassProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

/// The window title as a zero-size leaf view.
///
/// `.navigationTitle` reads `displayTitle`, and wherever that read happens is
/// what SwiftUI re-evaluates when the title mutates. On the chrome body that
/// was the whole window; here it's an invisible point.
private struct WindowTitle: View {
    let tab: Tab

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .navigationTitle(tab.displayTitle)
    }
}

// MARK: - Palette motion

/// Where the address palette is in its life.
enum PalettePhase: Equatable {
    case closed
    case open
    /// Animating out in place, ahead of being removed.
    case leaving(PaletteClose)

    var leaving: PaletteClose? {
        if case .leaving(let reason) = self { return reason }
        return nil
    }
}

/// The palette's way in from a command: dropped from just above, out of focus,
/// settling as it lands — the way Spotlight arrives.
private struct PaletteDrop: ViewModifier {
    let isDropping: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isDropping ? 0 : 1)
            .scaleEffect(isDropping ? 0.96 : 1, anchor: .top)
            .offset(y: isDropping ? -10 : 0)
            .blur(radius: isDropping ? 6 : 0)
    }
}

/// The palette's ways out that aren't a removal: lifting away on submit, or
/// settling back and fading on a dismissal.
private struct PaletteExit: ViewModifier {
    let leaving: PaletteClose?

    func body(content: Content) -> some View {
        content
            .opacity(leaving == nil ? 1 : 0)
            .scaleEffect(scale, anchor: .top)
            .offset(y: leaving == .submit ? -16 : 0)
    }

    private var scale: CGFloat {
        switch leaving {
        case nil: 1
        case .submit: 0.97
        case .dismiss: 0.98
        }
    }
}

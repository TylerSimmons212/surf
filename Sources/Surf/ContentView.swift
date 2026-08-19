import SurfCore
import SwiftUI

struct ContentView: View {
    let session: BrowserSession

    @AppStorage(PreferenceKeys.sidebarPinned) private var isPinned = false

    /// The one piece of chrome currently revealed. Exactly one, ever — the
    /// traffic lights and the sidebar both live in the top-left, so showing
    /// both would stack them.
    @State private var revealed: ChromeTarget = .none
    @State private var pointer = ChromePointer()
    @State private var revealTask: Task<Void, Never>?
    /// The lights' one unprompted appearance, so a window that opens with no
    /// chrome at all still shows you where its controls are.
    @State private var isIntroducingLights = false
    @State private var isAddressBarOpen = false
    /// Captured when the palette opens, because the session's flag may have
    /// changed again by the time it's submitted.
    @State private var paletteCreatesTab = false
    @State private var sidebarHold = SidebarHold()
    @State private var isFindBarOpen = false
    @State private var findBarFocusToken = 0
    @State private var tabKeyMonitor: Any?

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

    private var isSidebarRevealed: Bool { revealed == .sidebar }

    /// The lights follow the pointer, except for their one turn at launch.
    private var areLightsRevealed: Bool { revealed == .trafficLights || isIntroducingLights }

    /// Clear of the lights' row, so a find bar can never sit under a reveal.
    private var overlayTopInset: CGFloat { ChromeReveal.lightsRowHeight + 10 }

    var body: some View {
        ZStack {
            // One glass surface behind everything, so a pinned sidebar and the
            // page read as the same material.
            VisualEffectBackground(material: .underWindowBackground)

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

            // The lights' zone sits outside the pinned/floating split because
            // the buttons are the window's, not the page's — they overlay the
            // same corner either way.
            HoverZone { pointer.inCorner = $0 }
                .frame(width: ChromeReveal.cornerZone.width, height: ChromeReveal.cornerZone.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .zIndex(16)

            // Not a rendered view: this reaches out to the window and fades the
            // real AppKit buttons, which draw above everything here.
            TrafficLights(isRevealed: areLightsRevealed)
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

            if isAddressBarOpen {
                // The traffic lights render above SwiftUI content, so if the
                // palette opens while they're revealed they stay visible and
                // clickable over its backdrop.
                URLPalette(
                    session: session,
                    tab: session.selectedTab,
                    createsTab: paletteCreatesTab,
                    isPresented: $isAddressBarOpen
                )
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    .zIndex(20)
            }
        }
        // Hidden titlebar with full-size content, so the page runs to every
        // window edge — nothing is reserved above it any more.
        .ignoresSafeArea()
        .navigationTitle(session.selectedTab.displayTitle)
        .onChange(of: pointerNow) { _, pointer in
            scheduleReveal(ChromeReveal.resolve(pointer, current: revealed))
        }
        // Pinning mid-hover would otherwise leave a stale floating copy behind.
        .onChange(of: isPinned) { _, _ in
            revealTask?.cancel()
            revealed = .none
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
        .onAppear(perform: introduceTrafficLights)
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
            lightsRevealed: areLightsRevealed,
            hold: sidebarHold
        )
    }

    /// The window is nothing but the page now — no toolbar above it.
    private var tabContent: some View {
        TabContent(
            tab: session.selectedTab,
            session: session,
            // The floating panel plus its leading inset — the exact strip of
            // page the chrome is sitting on top of.
            chromeInset: (!isPinned && isSidebarRevealed) ? Sidebar.width + 8 : 0,
            onOpenAddressBar: { session.requestAddressFocus() }
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
            .padding(.leading, 8)
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

            return event
        }
    }

    private var sidebarShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    private func openAddressBar() {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
            isAddressBarOpen = true
        }
    }

    /// Commits a resolved target after its delay, cancelling whatever was
    /// pending — so a pointer sweeping up the edge to the corner settles on the
    /// lights rather than flashing the sidebar on the way past.
    private func scheduleReveal(_ target: ChromeTarget) {
        guard target != revealed else {
            revealTask?.cancel()
            return
        }
        revealTask?.cancel()
        revealTask = Task { @MainActor in
            try? await Task.sleep(for: ChromeReveal.delay(revealing: target))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                revealed = target
            }
        }
    }

    /// Shows the lights once when the window opens, then lets them go.
    ///
    /// Without this the window arrives with no visible controls at all, and
    /// nothing to suggest that the corner is worth reaching for.
    private func introduceTrafficLights() {
        isIntroducingLights = true
        Task { @MainActor in
            try? await Task.sleep(for: ChromeReveal.launchRevealDuration)
            isIntroducingLights = false
        }
    }

    /// Dev affordance: `SURF_URL=example.com swift run` opens straight to a
    /// page. Comma-separate to open several tabs at once.
    private func applyLaunchEnvironment() {
        guard let start = ProcessInfo.processInfo.environment["SURF_URL"], !start.isEmpty
        else { return }
        let targets = start.split(separator: ",").map(String.init)
        for (offset, target) in targets.enumerated() {
            let tab = offset == 0 ? session.selectedTab : session.addTab()
            tab.submit(target)
        }
        if let first = session.tabs.first { session.select(first) }
    }
}

/// One tab's content: the home search screen, or the bare page.
private struct TabContent: View {
    let tab: Tab
    let session: BrowserSession
    let chromeInset: CGFloat
    let onOpenAddressBar: () -> Void

    var body: some View {
        Group {
            switch tab.mode {
            case .home:
                EmptyTabView(session: session, tab: tab)
            case .browsing:
                ZStack {
                    if PopOutController.shared.isPoppedOut(tab) {
                        // The web view itself now lives in the pop-out panel; it
                        // can only be in one hierarchy at a time.
                        PoppedOutPlaceholder(tab: tab)
                    } else {
                        WebView(webView: tab.webView, chromeInset: chromeInset)
                    }
                    if let error = tab.lastError {
                        ErrorOverlay(message: error) { tab.reload() }
                    }
                }
            }
        }
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

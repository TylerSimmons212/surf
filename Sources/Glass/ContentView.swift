import SwiftUI

struct ContentView: View {
    let session: BrowserSession

    @AppStorage(PreferenceKeys.sidebarPinned) private var isPinned = false

    @State private var isRevealed = false
    @State private var pointerInHotZone = false
    @State private var pointerInSidebar = false
    @State private var revealTask: Task<Void, Never>?
    @State private var isAddressBarOpen = false
    /// Captured when the palette opens, because the session's flag may have
    /// changed again by the time it's submitted.
    @State private var paletteCreatesTab = false
    @State private var sidebarHold = SidebarHold()
    @State private var isFindBarOpen = false
    @State private var findBarFocusToken = 0
    @State private var tabKeyMonitor: Any?

    /// Width of the invisible strip along the window's left edge that triggers
    /// the reveal.
    ///
    /// Generous on purpose: `HoverZone` doesn't intercept clicks, so the only
    /// cost of a wider strip is opening when the pointer merely passes near the
    /// edge. The open delay absorbs most of that — a pointer travelling through
    /// leaves before the timer fires.
    private let hotZoneWidth: CGFloat = 28

    /// The hold keeps the sidebar up while something it opened is still on
    /// screen — a popover lives in its own window, so reaching into it counts
    /// as leaving the sidebar.
    private var wantsReveal: Bool {
        pointerInHotZone || pointerInSidebar || sidebarHold.isHeld
    }

    /// Just tall enough for the traffic lights — this is macOS's own titlebar
    /// height, so the buttons sit centred with no slack around them.
    private let titleBarHeight: CGFloat = 28

    var body: some View {
        ZStack {
            // One glass surface behind everything, so the title strip and a
            // pinned sidebar read as the same material.
            VisualEffectBackground(material: .underWindowBackground)

            VStack(spacing: 0) {
                // Tinted from the page so the strip reads as part of the site.
                // Falls back to clear, letting the window glass through.
                (session.selectedTab.topColor.map(Color.init(nsColor:)) ?? Color.clear)
                    .frame(height: titleBarHeight)
                    .animation(.easeOut(duration: 0.25), value: session.selectedTab.topColor)

                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        if isPinned {
                            sidebar(isFloating: false)
                            Divider()
                        }
                        tabContent
                    }

                    if !isPinned {
                        HoverZone { pointerInHotZone = $0 }
                            .frame(width: hotZoneWidth)
                            .frame(maxHeight: .infinity, alignment: .leading)

                        if isRevealed {
                            floatingSidebar
                        }
                    }

                }
            }

            if isFindBarOpen {
                FindBar(tab: session.selectedTab, isPresented: $isFindBarOpen)
                    // Identity includes the focus token so a repeat ⌘F rebuilds
                    // the bar focused, rather than opening a second one.
                    .id(findBarFocusToken)
                    .padding(.top, titleBarHeight + 10)
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
                // Outside the VStack so the dimmed backdrop covers the title
                // strip too. The traffic lights render above SwiftUI content, so
                // they stay visible and clickable.
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
        // Hidden titlebar with full-size content, so the glass runs to the
        // window edges; the title strip above reserves the traffic-light row.
        .ignoresSafeArea()
        .navigationTitle(session.selectedTab.displayTitle)
        .onChange(of: wantsReveal) { _, wants in
            scheduleReveal(wants)
        }
        // Pinning mid-hover would otherwise leave a stale floating copy behind.
        .onChange(of: isPinned) { _, _ in
            revealTask?.cancel()
            isRevealed = false
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
                name: .glassFindStep,
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
            openAddressBar()
        }
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
            chromeInset: (!isPinned && isRevealed) ? Sidebar.width + 8 : 0,
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
            // Glass exists for. Not `interactive`: that's for controls, and a
            // whole panel reacting to the pointer reads as wobbly rather than
            // responsive.
            .glassEffect(.regular, in: sidebarShape)
            // Glass alone is thin enough that a busy page reads straight
            // through the tab titles. The material sits *behind* the glass —
            // applied after it, so it renders underneath — giving the panel
            // back its body while the glass keeps the edge and the highlights.
            // Reach for .thickMaterial here if a page still shows through.
            .background { sidebarShape.fill(.regularMaterial) }
            .shadow(color: .black.opacity(0.28), radius: 20, x: 6, y: 4)
            .padding(.top, 4)
            .padding(.bottom, 10)
            .padding(.leading, 8)
            .transition(.move(edge: .leading).combined(with: .opacity))
            .onHover { pointerInSidebar = $0 }
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

    /// Asymmetric delays, tuned to how a pointer actually moves: opening is
    /// nearly immediate so the sidebar feels responsive, closing waits longer so
    /// crossing the gap from hot zone to sidebar doesn't dismiss it.
    private func scheduleReveal(_ shouldReveal: Bool) {
        revealTask?.cancel()
        revealTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(shouldReveal ? 90 : 320))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                isRevealed = shouldReveal
            }
        }
    }

    /// Dev affordance: `GLASS_URL=example.com swift run` opens straight to a
    /// page. Comma-separate to open several tabs at once.
    private func applyLaunchEnvironment() {
        guard let start = ProcessInfo.processInfo.environment["GLASS_URL"], !start.isEmpty
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
                EmptyTabView(onOpenAddressBar: onOpenAddressBar)
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

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
    /// The in-flight tab drag. Owned here rather than in the sidebar because a
    /// drag that starts on a row can end on the page: both the rows and the
    /// split drop zones have to be looking at the same one.
    @State private var dragContext = TabDragContext()

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
        // The title lives on a leaf view so that only it observes
        // `displayTitle` — a page animating its title ("(3) Inbox…") would
        // otherwise re-evaluate this entire chrome body every tick.
        .background { WindowTitle(tab: session.selectedTab) }
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
            hold: sidebarHold,
            dragContext: dragContext
        )
    }

    /// The window is nothing but the page now — no toolbar above it.
    private var tabContent: some View {
        SplitContent(
            session: session,
            drag: dragContext,
            // The floating panel plus its leading inset — the exact strip of
            // page the chrome is sitting on top of.
            chromeInset: (!isPinned && isSidebarRevealed) ? Sidebar.width + 8 : 0
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
        openDevToolsIfAsked()
    }

    /// Dev affordance: `SURF_DEVTOOLS=console` alongside `SURF_URL` opens the
    /// panel on the first tab at launch, on the named pane. `1` means Console.
    ///
    /// The injected half of dev tools only exists while a panel is attached,
    /// so without this there is no way to exercise it except by hand — and the
    /// scripts it installs are the largest thing Surf puts into a page.
    private func openDevToolsIfAsked() {
        guard let want = ProcessInfo.processInfo.environment["SURF_DEVTOOLS"],
              !want.isEmpty,
              let tab = session.tabs.first
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
                }
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

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
    /// changed again by the time it's dismissed.
    @State private var cancelDiscardsTab = false

    /// Width of the invisible strip along the window's left edge that triggers
    /// the reveal.
    ///
    /// Generous on purpose: `HoverZone` doesn't intercept clicks, so the only
    /// cost of a wider strip is opening when the pointer merely passes near the
    /// edge. The open delay absorbs most of that — a pointer travelling through
    /// leaves before the timer fires.
    private let hotZoneWidth: CGFloat = 28

    private var wantsReveal: Bool { pointerInHotZone || pointerInSidebar }

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

            if isAddressBarOpen {
                // Outside the VStack so the dimmed backdrop covers the title
                // strip too. The traffic lights render above SwiftUI content, so
                // they stay visible and clickable.
                URLPalette(
                    tab: session.selectedTab,
                    isPresented: $isAddressBarOpen,
                    onCancel: handleAddressBarCancelled
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
        .onChange(of: session.focusAddressToken) { _, _ in
            cancelDiscardsTab = session.addressFocusIsForNewTab
            openAddressBar()
        }
        .onAppear(perform: applyLaunchEnvironment)
    }

    private func sidebar(isFloating: Bool) -> some View {
        Sidebar(
            session: session,
            isPinned: $isPinned,
            isFloating: isFloating
        )
    }

    /// The window is nothing but the page now — no toolbar above it.
    private var tabContent: some View {
        TabContent(
            tab: session.selectedTab,
            session: session,
            onOpenAddressBar: { session.requestAddressFocus() }
        )
            // Identity tied to the tab, so switching rebuilds the subtree and
            // mounts the correct web view instead of reusing the previous one.
            .id(session.selectedTab.id)
    }

    private var floatingSidebar: some View {
        sidebar(isFloating: true)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.28), radius: 20, x: 6, y: 4)
            }
            .padding(.top, 4)
            .padding(.bottom, 10)
            .padding(.leading, 8)
            .transition(.move(edge: .leading).combined(with: .opacity))
            .onHover { pointerInSidebar = $0 }
            .zIndex(1)
    }

    /// Escaping out of a brand-new tab throws it away, so abandoning "new tab"
    /// leaves no trace. Tabs that already existed are always kept.
    private func handleAddressBarCancelled() {
        guard cancelDiscardsTab else { return }
        session.discardIfBlank(session.selectedTab)
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
    }
}

/// One tab's content: the home search screen, or the bare page.
private struct TabContent: View {
    let tab: Tab
    let session: BrowserSession
    let onOpenAddressBar: () -> Void

    var body: some View {
        Group {
            switch tab.mode {
            case .home:
                EmptyTabView(onOpenAddressBar: onOpenAddressBar)
            case .browsing:
                ZStack {
                    WebView(webView: tab.webView)
                    if let error = tab.lastError {
                        ErrorOverlay(message: error) { tab.reload() }
                    }
                }
            }
        }
        // A restored tab loads the first time it's actually shown, not at launch.
        .onAppear { tab.activateRestoreIfNeeded() }
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
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

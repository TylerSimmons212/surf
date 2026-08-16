import SwiftUI

struct ContentView: View {
    let session: BrowserSession

    /// Hidden for a single tab, so a fresh window keeps the clean look.
    private var showsTabBar: Bool { session.tabs.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            if showsTabBar {
                TabBar(session: session)
            }

            TabContent(
                tab: session.selectedTab,
                session: session,
                needsTitlebarInset: !showsTabBar
            )
            // Identity tied to the tab, so switching tabs rebuilds the subtree
            // and remounts the correct web view rather than reusing the old one.
            .id(session.selectedTab.id)
        }
        .ignoresSafeArea(edges: showsTabBar ? .all : [])
        .navigationTitle(session.selectedTab.displayTitle)
        // Dev affordance: `GLASS_URL=example.com swift run` opens straight to a
        // page, so navigation can be exercised without driving the UI by hand.
        // Comma-separate to open several tabs at once.
        .onAppear {
            guard let start = ProcessInfo.processInfo.environment["GLASS_URL"], !start.isEmpty
            else { return }
            let targets = start.split(separator: ",").map(String.init)
            for (offset, target) in targets.enumerated() {
                let tab = offset == 0 ? session.selectedTab : session.addTab()
                tab.submit(target)
            }
            // Land on the first tab, not the last one opened.
            if let first = session.tabs.first { session.select(first) }
        }
    }
}

/// One tab's content: either the home search screen or chrome plus the page.
private struct TabContent: View {
    let tab: Tab
    let session: BrowserSession
    let needsTitlebarInset: Bool

    var body: some View {
        switch tab.mode {
        case .home:
            SearchView(tab: tab, session: session)
        case .browsing:
            VStack(spacing: 0) {
                BrowserChrome(
                    tab: tab,
                    session: session,
                    needsTitlebarInset: needsTitlebarInset
                )
                ZStack {
                    WebView(webView: tab.webView)
                    if let error = tab.lastError {
                        ErrorOverlay(message: error) { tab.reload() }
                    }
                }
            }
        }
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

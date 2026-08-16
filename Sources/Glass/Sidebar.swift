import AppKit
import SwiftUI

/// The vertical tab list plus the navigation controls.
///
/// Everything that used to sit in a toolbar lives here, so the window itself is
/// nothing but page.
struct Sidebar: View {
    let session: BrowserSession
    @Binding var isPinned: Bool
    /// Floating mode draws its own material panel; pinned sits on the window's
    /// glass. Kept only for that styling difference — the traffic lights are
    /// handled by the title strip above, so both use the same insets.
    let isFloating: Bool
    @State private var hoveredTab: Tab.ID?
    @State private var isHoveringNewTab = false
    @State private var copiedTab: Tab.ID?

    static let width: CGFloat = 240

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            tabList
            if let playing = session.nowPlayingTab {
                MediaPlayerBar(tab: playing, session: session)
            }
        }
        .frame(width: Sidebar.width)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: session.nowPlayingTab?.id)
    }

    // MARK: - Navigation

    private var navigationBar: some View {
        let tab = session.selectedTab

        return HStack(spacing: 2) {
            IconButton(
                systemName: "chevron.left",
                isEnabled: tab.canGoBack,
                drawsIn: true,
                help: "Back (⌘[)"
            ) { tab.goBack() }

            IconButton(
                systemName: "chevron.right",
                isEnabled: tab.canGoForward,
                drawsIn: true,
                help: "Forward (⌘])"
            ) { tab.goForward() }

            // While loading, the arrow spins and a ring around it fills with
            // real progress; it only becomes a stop button under the pointer.
            // The control reports state at rest and offers the action on hover.
            ZStack {
                IconButton(
                    systemName: "arrow.clockwise",
                    hoverSymbol: tab.isLoading ? "xmark" : nil,
                    isEnabled: tab.mode == .browsing,
                    isSpinning: tab.isLoading,
                    help: tab.isLoading ? "Stop" : "Reload (⌘R)"
                ) {
                    tab.isLoading ? tab.stop() : tab.reload()
                }

                if tab.isLoading {
                    progressRing(tab.progress)
                }
            }
            .animation(.easeOut(duration: 0.2), value: tab.isLoading)

            Spacer()

            IconButton(
                systemName: "magnifyingglass",
                motion: .pulse,
                drawsIn: true,
                help: "Open Address Bar (⌘L)"
            ) { session.requestAddressFocus() }

            IconButton(
                systemName: isPinned ? "sidebar.left" : "pin",
                drawsIn: true,
                help: isPinned ? "Unpin Sidebar (⌘S)" : "Pin Sidebar (⌘S)"
            ) {
                isPinned.toggle()
            }
            .animation(.easeOut(duration: 0.2), value: isPinned)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// Load progress drawn around the reload button, so the control *is* the
    /// indicator and no separate bar is needed.
    private func progressRing(_ progress: Double) -> some View {
        Circle()
            // A floor keeps a visible arc at 0%, so the ring appears the moment
            // loading starts rather than materialising partway through.
            .trim(from: 0, to: max(0.04, progress))
            .stroke(
                Color.accentColor,
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
            )
            // Starts the arc at twelve o'clock instead of three.
            .rotationEffect(.degrees(-90))
            .frame(width: 21, height: 21)
            .animation(.easeOut(duration: 0.25), value: progress)
            .transition(.opacity.combined(with: .scale(scale: 0.7)))
            // Purely decorative: clicks belong to the button underneath.
            .allowsHitTesting(false)
    }

    // MARK: - Tabs

    private var tabList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(session.tabs) { tab in
                    row(for: tab)
                }
                newTabButton
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private func row(for tab: Tab) -> some View {
        let isSelected = tab.id == session.selectedTabID
        let isHovered = hoveredTab == tab.id
        let showsActions = isHovered || copiedTab == tab.id

        return HStack(spacing: 7) {
            statusIcon(for: tab)
                .scaleEffect(isHovered ? 1.12 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.65), value: isHovered)

            Text(tab.displayTitle)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(tab.isAwaitingRestore ? 0.55 : 1)

            Spacer(minLength: 0)

            // Always laid out, faded in on hover. Inserting them on hover
            // instead would resize the title and make rows twitch as the
            // pointer moves down the list.
            HStack(spacing: 1) {
                // Momentary checkmark: copying is invisible otherwise, and a
                // silent copy leaves you unsure it worked.
                IconButton(
                    systemName: copiedTab == tab.id ? "checkmark" : "link",
                    size: 9,
                    weight: .bold,
                    width: 17,
                    height: 17,
                    cornerRadius: 5,
                    tint: copiedTab == tab.id ? .green : nil,
                    help: "Copy Link"
                ) {
                    copyURL(of: tab)
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: copiedTab == tab.id)

                IconButton(
                    systemName: "xmark",
                    size: 9,
                    weight: .bold,
                    width: 17,
                    height: 17,
                    cornerRadius: 5,
                    help: "Close Tab (⌘W)"
                ) {
                    session.close(tab)
                }
            }
            .opacity(showsActions ? 1 : 0)
            .scaleEffect(showsActions ? 1 : 0.7, anchor: .trailing)
            .allowsHitTesting(showsActions)
            .animation(.spring(response: 0.26, dampingFraction: 0.7), value: showsActions)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.14 : (isHovered ? 0.07 : 0)))
                .animation(.easeOut(duration: 0.16), value: isHovered)
                .animation(.easeOut(duration: 0.2), value: isSelected)
        }
        .contentShape(Rectangle())
        .onTapGesture { session.select(tab) }
        .onHover { hovering in
            hoveredTab = hovering ? tab.id : (hoveredTab == tab.id ? nil : hoveredTab)
        }
        .help(tab.displayTitle)
    }

    private var newTabButton: some View {
        Button {
            // A new tab is a request to go somewhere, so ask where immediately
            // rather than presenting a screen that asks the same thing.
            session.openNewTabAndPrompt()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 13, height: 13)
                    .rotationEffect(.degrees(isHoveringNewTab ? 90 : 0))
                    .scaleEffect(isHoveringNewTab ? 1.15 : 1)
                Text("New Tab")
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isHoveringNewTab ? 0.07 : 0))
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.65), value: isHoveringNewTab)
        .onHover { isHoveringNewTab = $0 }
        .help("New Tab (⌘T)")
    }

    // MARK: - Actions

    private func copyURL(of tab: Tab) {
        let url = tab.webView.url?.absoluteString ?? tab.addressText
        guard !url.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)

        copiedTab = tab.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            if copiedTab == tab.id { copiedTab = nil }
        }
    }

    // MARK: - Pieces

    /// Loading spinner > real favicon > generic placeholder. The spinner wins so
    /// a cached icon can't make a loading tab look finished.
    @ViewBuilder
    private func statusIcon(for tab: Tab) -> some View {
        if tab.isLoading {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.5)
                .frame(width: 13, height: 13)
        } else if let favicon = tab.favicon {
            Image(nsImage: favicon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 13, height: 13)
        } else {
            Image(systemName: tab.mode == .home ? "magnifyingglass" : "globe")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 13, height: 13)
        }
    }

}

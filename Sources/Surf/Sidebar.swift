import AppKit
import SurfCore
import SwiftUI

/// The vertical tab list plus the navigation controls.
///
/// Everything that used to sit in a toolbar lives here, so the window itself is
/// nothing but page.
///
/// Every part below is a `View` struct rather than a method or computed
/// property on this one, and that is a performance decision rather than a
/// stylistic one. Under `@Observable`, a dependency read while a body runs is
/// attributed to *that body* — so a helper method returning a row makes the
/// whole sidebar depend on the row's tab. Written that way, one tab reporting
/// load progress re-evaluated the navigation bar, every visible row, both
/// buttons in each of them, and the new-tab button. Split like this, each piece
/// depends only on what it actually reads.
struct Sidebar: View {
    let session: BrowserSession
    @Binding var isPinned: Bool
    /// Floating mode draws its own material panel; pinned sits on the window's
    /// glass. Also shifts the top inset: the floating panel already starts
    /// below the traffic lights' row, so it has less of it left to clear.
    let isFloating: Bool
    /// Whether the traffic lights are currently overlaying the window's corner
    /// — which is this panel's corner too, whenever it's pinned.
    let lightsRevealed: Bool
    /// Lets the sidebar's own transient UI keep it on screen.
    let hold: SidebarHold

    @State private var isHoveringNewTab = false

    /// Wide enough that the roomier rows don't buy their height back out of
    /// the title: taller rows with the same width would just truncate sooner.
    static let width: CGFloat = 264
    /// Two 21pt controls and the gap between them.
    static let actionsWidth: CGFloat = 44

    /// How far the floating panel is held off the top of the window.
    static let floatingTopPadding: CGFloat = 4

    /// Steps out of the traffic lights' way — but only while they're actually
    /// there.
    ///
    /// Holding this space permanently rebuilds, inside the sidebar, exactly the
    /// dead strip that removing the title bar was meant to reclaim: the lights
    /// are hidden almost all of the time, so almost all of the time it reserved
    /// room for nothing.
    ///
    /// A pinned panel is the case that needs it, since it's on screen no matter
    /// what the pointer is doing and the lights can appear right on top of its
    /// back and forward buttons. A floating panel is nearly always spared by
    /// arbitration — it holds the corner while the pointer is inside it, so the
    /// lights don't reveal — and this only covers the moment one is animating
    /// out as the other fades in.
    ///
    /// Measured from the window's top edge, so the floating panel subtracts the
    /// gap it's already sitting below.
    private var topInset: CGFloat {
        guard lightsRevealed else { return 0 }
        return ChromeReveal.lightsRowHeight - (isFloating ? Sidebar.floatingTopPadding : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            SidebarNavigationBar(session: session, isPinned: $isPinned, hold: hold)
            StickerShelf(session: session)
            tabList
            SidebarMediaSection(session: session)
            IslandStrip(session: session, hold: hold)
        }
        .padding(.top, topInset)
        // Matched to the lights' own fade, so the room appears as they do
        // rather than as a separate jolt just after them.
        .animation(.easeOut(duration: 0.18), value: topInset)
        .frame(width: Sidebar.width)
    }

    // MARK: - Tabs

    private var tabList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(session.tabs) { tab in
                    TabRow(
                        tab: tab,
                        isSelected: tab.id == session.selectedTabID,
                        onSelect: { session.select(tab) },
                        onClose: { session.close(tab) },
                        // Wrapped here, at the mutation, because that is what
                        // drives the new tile's slap-on transition.
                        onPin: {
                            withAnimation(StickerShelf.slap) {
                                session.pinSticker(for: tab)
                            }
                        }
                    )
                }
                newTabButton
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private var newTabButton: some View {
        Button {
            // A new tab is a request to go somewhere, so ask where immediately
            // rather than presenting a screen that asks the same thing.
            session.openNewTabAndPrompt()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .rotationEffect(.degrees(isHoveringNewTab ? 90 : 0))
                    .scaleEffect(isHoveringNewTab ? 1.15 : 1)
                Text("New Tab")
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(isHoveringNewTab ? 0.07 : 0))
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.65), value: isHoveringNewTab)
        .onHover { isHoveringNewTab = $0 }
        .help("New Tab (⌘T)")
    }
}

// MARK: - Media

/// Its own view purely so that reading `mediaTabs` — which touches the media
/// state of *every* tab in the session — doesn't make the whole sidebar depend
/// on all of it. A playing tab reports its position about once a second.
private struct SidebarMediaSection: View {
    let session: BrowserSession

    var body: some View {
        let mediaTabs = session.mediaTabs
        Group {
            if !mediaTabs.isEmpty {
                MediaPlayerStack(session: session)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: mediaTabs.count)
    }
}

// MARK: - Navigation

/// The back/forward/reload row. Separated because it reads the selected tab's
/// `progress`, which `WKWebView` reports many times per load.
private struct SidebarNavigationBar: View {
    let session: BrowserSession
    @Binding var isPinned: Bool
    let hold: SidebarHold

    var body: some View {
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
            ReloadControl(tab: tab)

            Spacer()

            // Zoom has no other visible home, and a page stuck at 125% with
            // nothing saying so reads as a rendering bug.
            if tab.isZoomed {
                Button { tab.resetZoom() } label: {
                    Text(tab.zoomLabel)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background { Capsule().fill(Color.primary.opacity(0.09)) }
                }
                .buttonStyle(.plain)
                .help("Reset zoom (⌘0)")
                .transition(.scale(scale: 0.7).combined(with: .opacity))
            }

            BlockButton(session: session, hold: hold)

            DownloadsButton(session: session, hold: hold)

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
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: tab.isZoomed)
    }
}

/// The reload button and its progress ring.
///
/// Split out from the navigation bar for the same reason the bar is split from
/// the sidebar: `progress` changes continuously while a page loads, and this is
/// the only thing that reads it. Now that is all it re-renders.
private struct ReloadControl: View {
    let tab: Tab

    var body: some View {
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
}

// MARK: - Rows

/// One tab in the list.
///
/// Its own struct so that a tab's title arriving, favicon loading, or spinner
/// starting re-renders that row and nothing else. Hover and the momentary
/// "copied" tick are local `@State` for the same reason — held on the sidebar,
/// moving the pointer down the list re-evaluated every row on every row change.
private struct TabRow: View {
    let tab: Tab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onPin: () -> Void

    @State private var isHovered = false
    @State private var didCopy = false

    private var showsActions: Bool { isHovered || didCopy }

    var body: some View {
        HStack(spacing: 10) {
            StatusIcon(tab: tab)
                .scaleEffect(isHovered ? 1.12 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.65), value: isHovered)

            Text(tab.displayTitle)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(tab.isAwaitingRestore ? 0.55 : 1)

            Spacer(minLength: 0)
        }
        // The controls sit on top of the end of the title, so the text is faded
        // out beneath them rather than left to collide with them.
        .mask { titleFade }
        // Selection belongs to the title area, and is attached *before* the
        // controls are overlaid so they sit above it and take their own clicks.
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        // Overlaid rather than laid out, so the title gets the full width of
        // the row until the controls are actually wanted. Reserving their space
        // permanently made every tab name truncate early for the sake of two
        // buttons that are hidden most of the time.
        .overlay(alignment: .trailing) { actions }
        .padding(.horizontal, 9)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.14 : (isHovered ? 0.07 : 0)))
                .animation(.easeOut(duration: 0.16), value: isHovered)
                .animation(.easeOut(duration: 0.2), value: isSelected)
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            // A home tab has no page to pin, so the item would only ever
            // silently do nothing there.
            if tab.mode == .browsing {
                Button(action: onPin) {
                    Label("Add Sticker", systemImage: "star.square.on.square")
                }
                Button(action: copyURL) {
                    Label("Copy Link", systemImage: "link")
                }
                Divider()
            }
            Button(role: .destructive, action: onClose) {
                Label("Close Tab", systemImage: "xmark")
            }
        }
        .help(tab.displayTitle)
    }

    private var actions: some View {
        HStack(spacing: 2) {
            // Momentary checkmark: copying is invisible otherwise, and a
            // silent copy leaves you unsure it worked.
            IconButton(
                systemName: didCopy ? "checkmark" : "link",
                size: 10,
                weight: .bold,
                width: 21,
                height: 21,
                cornerRadius: 6,
                tint: didCopy ? .green : nil,
                help: "Copy Link"
            ) {
                copyURL()
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: didCopy)

            IconButton(
                systemName: "xmark",
                size: 10,
                weight: .bold,
                width: 21,
                height: 21,
                cornerRadius: 6,
                help: "Close Tab (⌘W)"
            ) {
                onClose()
            }
        }
        .opacity(showsActions ? 1 : 0)
        .scaleEffect(showsActions ? 1 : 0.7, anchor: .trailing)
        .allowsHitTesting(showsActions)
        .animation(.spring(response: 0.26, dampingFraction: 0.7), value: showsActions)
    }

    /// Full-width by default; on hover, dissolves the tail of the title into
    /// the space the controls occupy.
    ///
    /// Sized in points rather than as a gradient across the whole row, because
    /// the clear part has to line up exactly with the buttons over it.
    private var titleFade: some View {
        HStack(spacing: 0) {
            Rectangle()
            LinearGradient(
                colors: [.black, .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: showsActions ? 18 : 0)
            Color.clear
                .frame(width: showsActions ? Sidebar.actionsWidth : 0)
        }
        .animation(.easeOut(duration: 0.2), value: showsActions)
    }

    private func copyURL() {
        let url = tab.currentURL ?? tab.addressText
        guard !url.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)

        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            didCopy = false
        }
    }
}

/// Loading spinner > real favicon > generic placeholder. The spinner wins so
/// a cached icon can't make a loading tab look finished.
private struct StatusIcon: View {
    let tab: Tab

    var body: some View {
        if tab.isLoading {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.55)
                .frame(width: 16, height: 16)
        } else if let favicon = tab.favicon {
            Image(nsImage: favicon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: tab.mode == .home ? "magnifyingglass" : "globe")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
    }
}

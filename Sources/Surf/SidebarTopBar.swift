import SurfCore
import SwiftUI

/// The sidebar's head: the window's own row, then the address.
///
/// It replaces a single strip that ran ten controls across 264 points. That
/// strip worked, in the sense that everything fitted, but it read as an
/// instrument panel — ten identical 21pt squares with no grouping and nothing
/// saying which of them were about the window, which about the page, and which
/// about this site in particular. Splitting it in two and letting shape carry
/// the grouping says all three without a word of labelling: the window's row
/// up top, the page's address beneath it, and everything that acts on the page
/// behind one button on the address itself.
///
/// The controls are Liquid Glass, and deliberately the system's own rather
/// than the hand-rolled hover plates `IconButton` draws. This chrome floats
/// over live web pages, where a flat plate has nothing to sample and reads as
/// a sticker; glass picks up the page underneath and separates from it.
struct SidebarTopBar: View {
    let session: BrowserSession
    @Binding var isPinned: Bool
    let isFloating: Bool
    let hold: SidebarHold
    let lightsSpan: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            SidebarWindowRow(session: session, isPinned: $isPinned, lightsSpan: lightsSpan)
            SidebarAddressPill(session: session, hold: hold)
        }
        .padding(.horizontal, Sidebar.horizontalPadding)
        .padding(.top, Sidebar.topBarTopPadding(isFloating: isFloating))
        .padding(.bottom, 10)
    }
}

/// Window controls and history: the row the traffic lights sit in.
///
/// The lights themselves are AppKit's, adopted out of the titlebar and
/// positioned over this row by `TrafficLights`. Nothing here draws them — this
/// only holds their place open, which is why the row starts with a measured
/// piece of nothing.
private struct SidebarWindowRow: View {
    let session: BrowserSession
    @Binding var isPinned: Bool
    let lightsSpan: CGFloat

    var body: some View {
        let tab = session.selectedTab

        return HStack(spacing: 8) {
            Color.clear
                .frame(width: lightsSpan + Sidebar.lightsTrailingGap, height: 1)
                .accessibilityHidden(true)

            SidebarGlassButton(
                systemName: "sidebar.left",
                // The one control in the row with a state rather than an
                // action, and the only one that earns a tint: pinned is a mode
                // you can be in and forget you are in.
                isProminent: isPinned,
                help: isPinned ? "Unpin Sidebar (⌘S)" : "Pin Sidebar (⌘S)"
            ) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    isPinned.toggle()
                }
            }

            Spacer(minLength: 8)

            SidebarHistoryPair(tab: tab)

            SidebarReloadButton(tab: tab)
        }
        .frame(height: Sidebar.topRowHeight)
    }
}

/// Back and forward, as one piece of glass.
///
/// A single capsule rather than two buttons, because they are one control with
/// two directions — and because a merged shape is what the system's own
/// segmented glass does. The halves keep separate hover fills inside it, so
/// the pointer still says which way it is about to go.
private struct SidebarHistoryPair: View {
    let tab: Tab

    var body: some View {
        HStack(spacing: 0) {
            // `canGoBackOrClose`: in a tab a link opened, Back with no history
            // behind it closes the tab and returns you to where the click was.
            SidebarPairHalf(
                symbol: "chevron.left",
                isEnabled: tab.canGoBackOrClose,
                isLeading: true,
                help: "Back (⌘[)"
            ) { tab.goBack() }

            SidebarPairHalf(
                symbol: "chevron.right",
                isEnabled: tab.canGoForward,
                isLeading: false,
                help: "Forward (⌘])"
            ) { tab.goForward() }
        }
        .glassEffect(.regular, in: Capsule())
    }
}

/// One direction of the history control.
///
/// Its own struct for the hover state: held on the pair, moving the pointer
/// from Back to Forward would re-evaluate both halves and the glass behind
/// them on every crossing.
private struct SidebarPairHalf: View {
    let symbol: String
    let isEnabled: Bool
    let isLeading: Bool
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 30, height: Sidebar.topRowHeight)
                .background {
                    // Clipped to the half of the capsule this button occupies,
                    // so the highlight ends on the pill's curve rather than
                    // square across the middle of it.
                    UnevenRoundedRectangle(
                        topLeadingRadius: isLeading ? Sidebar.topRowHeight / 2 : 0,
                        bottomLeadingRadius: isLeading ? Sidebar.topRowHeight / 2 : 0,
                        bottomTrailingRadius: isLeading ? 0 : Sidebar.topRowHeight / 2,
                        topTrailingRadius: isLeading ? 0 : Sidebar.topRowHeight / 2,
                        style: .continuous
                    )
                    .fill(Color.primary.opacity(isHovering && isEnabled ? 0.12 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 && isEnabled }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .help(help)
        // A Mac button doesn't normally change the cursor, but chrome floating
        // over a web page reads as part of the page without it.
        .pointerStyle(.link)
    }
}

/// Reload, which is also stop, and also the progress indicator.
///
/// One control doing three jobs rather than three controls: the symbol says
/// what the page is doing at rest, the ring around it says how far along, and
/// the hover swap offers the only action worth having mid-load.
private struct SidebarReloadButton: View {
    let tab: Tab

    @State private var isHovering = false

    var body: some View {
        Button {
            tab.isLoading ? tab.stop() : tab.reload()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .symbolEffect(.rotate, options: .repeating, isActive: tab.isLoading && !isHovering)
                .contentTransition(.symbolEffect(.replace.downUp))
                .foregroundStyle(
                    tab.mode == .browsing ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
                )
                .frame(width: Sidebar.topRowHeight, height: Sidebar.topRowHeight)
                .glassEffect(.regular.interactive(), in: Circle())
                .overlay { if tab.isLoading { progressRing } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(tab.mode != .browsing)
        .onHover { isHovering = $0 }
        .help(tab.isLoading ? "Stop" : "Reload (⌘R)")
        .pointerStyle(.link)
        .animation(.easeOut(duration: 0.2), value: tab.isLoading)
    }

    private var symbol: String {
        if tab.isLoading { return isHovering ? "xmark" : "arrow.clockwise" }
        return "arrow.clockwise"
    }

    /// Drawn on the button's own rim, so the control is the indicator and no
    /// separate bar is needed. A floor keeps a visible arc at 0%, or the ring
    /// would materialise partway through rather than when loading starts.
    private var progressRing: some View {
        Circle()
            .trim(from: 0, to: max(0.04, tab.progress))
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .padding(1.5)
            .animation(.easeOut(duration: 0.25), value: tab.progress)
            .transition(.opacity.combined(with: .scale(scale: 0.7)))
            .allowsHitTesting(false)
    }
}

/// A round glass button, for the controls in the window row that stand alone.
struct SidebarGlassButton: View {
    let systemName: String
    var size: CGFloat = 12
    var isProminent: Bool = false
    var diameter: CGFloat = Sidebar.topRowHeight
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(width: diameter, height: diameter)
                .glassEffect(
                    isProminent
                        ? .regular.tint(.accentColor).interactive()
                        : .regular.interactive(),
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .pointerStyle(.link)
    }
}

// MARK: - The address

/// Where the page is, and the way into everything you can do to it.
///
/// A label, not a field. Surf already has one address input — the ⌘L palette,
/// with history, completion and search — and a second one would mean two
/// places that answer the same keystroke differently. So the pill shows and
/// the palette edits, and clicking anywhere on the pill opens it.
///
/// It says the host and nothing else; `SiteAddress` has the reasoning. The
/// whole address is on the tooltip for the times the path is the point.
private struct SidebarAddressPill: View {
    let session: BrowserSession
    let hold: SidebarHold

    var body: some View {
        let tab = session.selectedTab
        let address = SiteAddress.reading(tab.currentURL ?? tab.addressText)

        return Button {
            session.requestAddressFocus()
        } label: {
            HStack(spacing: 6) {
                if let address, !address.isSecure {
                    // Not a padlock on everything — https is the floor now and
                    // decorating it says nothing. The exception is what's worth
                    // drawing.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                        .help("This site is not encrypted")
                }

                Text(address?.display ?? "Search or enter address")
                    .font(Typeface.figtree(size: 13, weight: 500))
                    .foregroundStyle(address == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.leading, 12)
            // Room for the tools button sitting over the trailing end.
            .padding(.trailing, Sidebar.addressHeight + 2)
            .frame(height: Sidebar.addressHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .overlay(alignment: .trailing) {
            SiteToolsButton(session: session, hold: hold)
                .padding(.trailing, 3)
        }
        .help(address?.full ?? "Open the address bar (⌘L)")
        .pointerStyle(.link)
    }
}

/// The button on the end of the address, and everything behind it.
///
/// Four controls used to sit in the top strip — zoom, copy link, screenshot,
/// the blocker — and they have one thing in common that the strip never said:
/// each acts on the page in front of you. Gathering them behind the address
/// makes that the grouping, and gives the row above back to the window.
private struct SiteToolsButton: View {
    let session: BrowserSession
    /// Keeps the sidebar revealed while the popover is up — a popover is its
    /// own window, so reaching into it counts as leaving the panel.
    let hold: SidebarHold

    private static let holdReason = "site-tools"

    private var isShowing: Binding<Bool> { hold.binding(for: Self.holdReason) }

    var body: some View {
        Button {
            isShowing.wrappedValue.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: Sidebar.addressHeight - 6, height: Sidebar.addressHeight - 6)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: isShowing, arrowEdge: .bottom) {
            SiteToolsPopover(session: session)
        }
        .help("Page tools")
        .pointerStyle(.link)
        // The popover's anchor can go away — switching to a tab that isn't
        // browsing, say — and a popover whose anchor is gone never reports
        // itself dismissed, which would strand the sidebar open forever.
        .onDisappear { hold.set(Self.holdReason, false) }
    }
}

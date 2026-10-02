import SurfCore
import SwiftUI

/// The foot of the sidebar: who you are, where you are, and what has arrived.
///
/// It replaces a strip of named island chips. Those said everything at once and
/// so said it in 24 points: six chips wide at the sidebar's width, each
/// carrying an emoji, a conditional name, a link marker and a warning badge,
/// with the real explanations hidden in tooltips. Identity and navigation are
/// two jobs, and now two controls do them — the face on the left says which
/// island you are in and what that means, the dots in the middle say how many
/// there are and let you move.
struct SidebarFooter: View {
    let session: BrowserSession
    let hold: SidebarHold

    var body: some View {
        // The dots are centred on the bar itself rather than on the space left
        // over between the two ends, which is the only arrangement that
        // actually holds.
        //
        // The first version gave both ends an equal fixed width and let a pair
        // of spacers split the rest. But the downloads button draws nothing at
        // all until something has been downloaded, and a fixed frame around a
        // view with no content reserves no width — so the surplus split two
        // ways instead of three and the dots sat 13 points right of centre.
        // Measured rather than reasoned: a trailing slot of 32 puts them at
        // 146, a trailing slot of 0 puts them at 161.75, and a screenshot of
        // the real thing put them at 161.75.
        //
        // Stacked, the middle cannot move. Either end may be any width, or
        // absent entirely, and the dots stay on the panel's centre line.
        ZStack {
            HStack(spacing: 0) {
                IslandProfileButton(session: session, hold: hold)
                Spacer(minLength: 0)
                FooterDownloadsButton(session: session, hold: hold)
            }

            // Last, so the island list it grows upward sits above its
            // neighbours rather than behind them.
            IslandDots(session: session)
        }
        .padding(.horizontal, Sidebar.horizontalPadding)
        .padding(.top, 7)
        .padding(.bottom, 9)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }
}

// MARK: - The islands, as dots

/// How many islands there are, which one you're on, and the way to the others.
///
/// Dots at rest, because that is all the information worth spending the middle
/// of the bar on. Hovering is what asks the real question — "which ones?" —
/// and the answer rises out of the dots rather than arriving somewhere else.
private struct IslandDots: View {
    let session: BrowserSession

    @State private var isExpanded = false
    @State private var collapseTask: Task<Void, Never>?

    var body: some View {
        dots
            .overlay(alignment: .bottom) {
                if isExpanded {
                    IslandList(session: session, onHover: hover(_:))
                        // Clear of the dots it grew out of. Padding rather than
                        // an offset: the gap has to be part of the overlay's
                        // own height, or the bottom alignment puts the list
                        // back on top of them.
                        .padding(.bottom, 38)
                        .transition(
                            .scale(scale: 0.92, anchor: .bottom)
                                .combined(with: .opacity)
                                .combined(with: .offset(y: 6))
                        )
                }
            }
            .onHover(perform: hover(_:))
            .animation(.spring(response: 0.3, dampingFraction: 0.78), value: isExpanded)
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(session.islands) { island in
                let isCurrent = island.id == session.currentIsland.id
                Circle()
                    .fill(isCurrent ? AnyShapeStyle(island.tint.color) : AnyShapeStyle(.tertiary))
                    .frame(width: isCurrent ? 7 : 6, height: isCurrent ? 7 : 6)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isCurrent)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background { Capsule().fill(Color.primary.opacity(isExpanded ? 0.10 : 0.06)) }
        .contentShape(Capsule())
        .help("Islands")
    }

    /// Asymmetric, for the same reason the sidebar's own reveal is: opening on
    /// the way past is cheap, and closing while somebody is still reaching for
    /// the thing that opened snatches it away mid-reach.
    private func hover(_ isInside: Bool) {
        collapseTask?.cancel()
        guard !isInside else {
            isExpanded = true
            return
        }
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            isExpanded = false
        }
    }
}

/// The islands, named, while the pointer is on them.
private struct IslandList: View {
    let session: BrowserSession
    let onHover: (Bool) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(session.islands) { island in
                IslandListRow(
                    island: island,
                    isCurrent: island.id == session.currentIsland.id,
                    onSelect: { session.select(island: island) }
                )
            }

            Divider().padding(.vertical, 2)

            SidebarMenuRow(title: "New Island", systemImage: "plus") {
                _ = session.createIslandAndEdit()
            }
        }
        .padding(6)
        .frame(width: Sidebar.width - Sidebar.horizontalPadding * 2 - 16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial)
        }
        .shadow(color: .black.opacity(0.24), radius: 14, y: 4)
        .onHover(perform: onHover)
    }
}

private struct IslandListRow: View {
    let island: Island
    let isCurrent: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 9) {
                Text(island.symbol)
                    .font(.system(size: 13))
                    .frame(width: 22, height: 22)
                    .background { Circle().fill(island.tint.color.opacity(isCurrent ? 0.22 : 0.12)) }

                Text(island.name)
                    .font(Typeface.figtree(size: 12.5, weight: isCurrent ? 600 : 500))
                    .lineLimit(1)

                Spacer(minLength: 0)

                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(island.tint.color)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.09 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .pointerStyle(.link)
    }
}

// MARK: - Downloads

/// Downloads, at the end of the bar.
///
/// It was a square in the top strip, among the window's controls, which is the
/// wrong neighbourhood: a finished download is not a thing about this window or
/// this page. Down here it is the one slot that changes on its own, and the
/// progress still rides the button's own rim rather than needing a bar.
private struct FooterDownloadsButton: View {
    let session: BrowserSession
    let hold: SidebarHold

    private static let holdReason = "downloads"

    private var isShowingList: Binding<Bool> { hold.binding(for: Self.holdReason) }

    private var manager: DownloadManager { DownloadManager.shared }

    var body: some View {
        Group {
            if !manager.items.isEmpty {
                Button {
                    isShowingList.wrappedValue.toggle()
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(
                            manager.activeCount > 0
                                ? AnyShapeStyle(Color.accentColor)
                                : AnyShapeStyle(.primary)
                        )
                        .frame(width: 30, height: 30)
                        .glassEffect(.regular.interactive(), in: Circle())
                        .overlay { if manager.activeCount > 0 { progressRing } }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: isShowingList, arrowEdge: .top) {
                    DownloadsList(session: session)
                }
                .help(
                    manager.activeCount > 0
                        ? "\(manager.activeCount) downloading"
                        : "Downloads"
                )
                .pointerStyle(.link)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                // Clearing the last item takes this button away, and a popover
                // whose anchor is gone never reports itself dismissed — the
                // hold would be stuck on and the sidebar stuck open.
                .onDisappear { hold.set(Self.holdReason, false) }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: manager.items.isEmpty)
    }

    private var progressRing: some View {
        Circle()
            .trim(from: 0, to: max(0.04, manager.activeProgress))
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .padding(1.5)
            .animation(.easeOut(duration: 0.25), value: manager.activeProgress)
            .allowsHitTesting(false)
    }
}

// MARK: - Shared

/// One line in a sidebar popover. Same shape as the page tools' rows, kept
/// separate because these sit in a card with its own padding.
struct SidebarMenuRow: View {
    let title: String
    let systemImage: String
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 16)
                Text(title)
                    .font(Typeface.figtree(size: 12.5, weight: 500))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isDestructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .pointerStyle(.link)
    }
}

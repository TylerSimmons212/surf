import SurfCore
import SwiftUI

/// The island switcher, along the bottom of the sidebar.
///
/// Its own `View` struct, and strictly so — see the note at the top of
/// `Sidebar`. This one has a sharper edge than most: the strip must read an
/// island's *identity* and nothing else. Touching `island.tabs` here would make
/// the whole switcher a dependency of every tab in every island, so one page
/// rewriting its title on a timer would redraw the strip forever.
struct IslandStrip: View {
    let session: BrowserSession
    let hold: SidebarHold

    var body: some View {
        HStack(spacing: 4) {
            ForEach(session.islands) { island in
                IslandChip(
                    island: island,
                    isCurrent: island.id == session.currentIsland.id,
                    onSelect: { session.select(island: island) },
                    onEdit: { session.islandBeingEdited = island },
                    onDelete: island.isHome ? nil : { session.requestDeleteIsland(island) }
                )
            }

            Spacer(minLength: 0)

            IconButton(
                systemName: "plus",
                size: 11,
                width: 24,
                height: 24,
                cornerRadius: 7,
                help: "New Island"
            ) {
                let island = session.createIsland()
                session.select(island: island)
                // Straight into the editor: the moment you make an island is
                // the moment you know what it's for.
                session.islandBeingEdited = island
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }
}

/// One island, as a chip.
///
/// Only the current island spells its name out. Six chips each carrying a word
/// would wrap the strip onto a second line at the sidebar's 264pt, and the
/// name is only ever a reminder of which one you're in — the emoji and the
/// tint are what you actually navigate by.
private struct IslandChip: View {
    let island: Island
    let isCurrent: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 5) {
                Text(island.symbol)
                    .font(.system(size: 13))
                if isCurrent {
                    Text(island.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(island.tint.color)
                }
                if island.isDegraded {
                    // Said out loud rather than discovered on the next launch:
                    // this island failed to get persistent storage, so it will
                    // forget every login when the app quits.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, isCurrent ? 9 : 7)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(island.tint.color.opacity(isCurrent ? 0.18 : (isHovering ? 0.10 : 0)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(island.tint.color.opacity(isCurrent ? 0.45 : 0), lineWidth: 1)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isCurrent)
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .onHover { isHovering = $0 }
        .help(island.isDegraded ? "\(island.name) — storage unavailable" : island.name)
        .contextMenu {
            Button("Rename…", action: onEdit)
            if let onDelete {
                Divider()
                // Named for what it actually does. "Delete Island" reads like
                // closing a window; this throws away every login in it.
                Button("Delete Island and Its Data", role: .destructive, action: onDelete)
            }
        }
    }
}

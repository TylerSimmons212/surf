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

    /// Which island's editor is open, if any. Held here rather than per-chip so
    /// two popovers can't be up at once.
    @State private var editing: Island.ID?

    private static let holdReason = "islands"

    var body: some View {
        HStack(spacing: 4) {
            ForEach(session.islands) { island in
                IslandChip(
                    island: island,
                    isCurrent: island.id == session.currentIsland.id,
                    onSelect: { session.select(island: island) },
                    onEdit: { editing = island.id; hold.set(Self.holdReason, true) },
                    onDelete: island.isHome ? nil : { session.requestDeleteIsland(island) }
                )
                .popover(
                    isPresented: Binding(
                        get: { editing == island.id },
                        set: { presented in
                            if !presented, editing == island.id {
                                editing = nil
                                hold.set(Self.holdReason, false)
                            }
                        }
                    ),
                    arrowEdge: .top
                ) {
                    IslandEditor(session: session, island: island)
                }
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
                editing = island.id
                hold.set(Self.holdReason, true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
        .onDisappear { hold.set(Self.holdReason, false) }
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

/// Rename, re-emoji, re-tint. Opened from the chip's context menu, and
/// automatically for a freshly created island — which is the moment you
/// actually know what you're making it for.
private struct IslandEditor: View {
    let session: BrowserSession
    let island: Island

    @State private var name: String = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Island name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .focused($isNameFocused)
                .onSubmit { commit() }
                .frame(width: 220)

            FlowLayout(spacing: 6) {
                ForEach(IslandSymbols.all, id: \.self) { symbol in
                    Button {
                        island.symbol = symbol
                        session.scheduleSave()
                    } label: {
                        Text(symbol)
                            .font(.system(size: 15))
                            .frame(width: 26, height: 26)
                            .background {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(island.symbol == symbol ? 0.12 : 0))
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 220)

            HStack(spacing: 6) {
                ForEach(IslandTint.allCases, id: \.self) { tint in
                    Button {
                        island.tint = tint
                        session.scheduleSave()
                    } label: {
                        Circle()
                            .fill(tint.color)
                            .frame(width: 18, height: 18)
                            .overlay {
                                Circle().strokeBorder(
                                    Color.primary.opacity(island.tint == tint ? 0.55 : 0),
                                    lineWidth: 2
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .help(tint.label)
                }
            }

            if island.isHome {
                // The one island whose isolation isn't real, said plainly. Its
                // jar is the shared default store — which is exactly why it
                // still has every login from before islands existed.
                Text("Your original browsing data lives here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 220, alignment: .leading)
            }
        }
        .padding(14)
        .onAppear {
            name = island.name
            isNameFocused = true
        }
        .onDisappear(perform: commit)
    }

    private func commit() {
        session.rename(island, to: name)
    }
}

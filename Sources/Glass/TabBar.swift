import SwiftUI

/// The row of tab chips. Only shown when more than one tab is open, so a
/// single-tab window keeps the clean full-bleed look.
struct TabBar: View {
    let session: BrowserSession
    @State private var hoveredTab: Tab.ID?

    var body: some View {
        HStack(spacing: 8) {
            // Clears the traffic lights — this is the topmost row, and the
            // window uses a hidden titlebar with full-size content.
            Spacer().frame(width: 68)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(session.tabs) { tab in
                        chip(for: tab)
                    }
                }
                .padding(.vertical, 1)
            }

            Button {
                session.addTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Tab (⌘T)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func chip(for tab: Tab) -> some View {
        let isSelected = tab.id == session.selectedTabID
        let isHovered = hoveredTab == tab.id

        return HStack(spacing: 6) {
            if tab.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
                    .frame(width: 12, height: 12)
            }

            Text(tab.displayTitle)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            // Revealed on hover or when selected, so idle tabs stay quiet but
            // the close target is always reachable without a menu.
            Button {
                session.close(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovered || isSelected ? 1 : 0)
            .help("Close Tab (⌘W)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 170)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.14 : (isHovered ? 0.07 : 0)))
        }
        .contentShape(Rectangle())
        .onTapGesture { session.select(tab) }
        .onHover { hovering in
            hoveredTab = hovering ? tab.id : (hoveredTab == tab.id ? nil : hoveredTab)
        }
        .help(tab.displayTitle)
    }
}

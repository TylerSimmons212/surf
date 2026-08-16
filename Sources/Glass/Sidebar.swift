import SwiftUI

/// The vertical tab list. Lives either pinned in the layout or floating over
/// the content when revealed by hover.
struct Sidebar: View {
    let session: BrowserSession
    @Binding var isPinned: Bool
    /// Floating mode needs to clear the traffic lights itself; pinned mode sits
    /// under them in the layout and needs the same inset. Both do, in fact —
    /// but the pinned one is flush to the window corner.
    let isFloating: Bool

    @State private var hoveredTab: Tab.ID?
    @State private var isHoveringNewTab = false

    var body: some View {
        VStack(spacing: 0) {
            header
            tabList
        }
        .frame(width: Sidebar.width)
    }

    static let width: CGFloat = 240

    private var header: some View {
        HStack(spacing: 6) {
            // Traffic lights sit at the window's top-left, which is inside the
            // sidebar. Reserve their row.
            Spacer()

            Button {
                isPinned.toggle()
            } label: {
                Image(systemName: isPinned ? "sidebar.left" : "pin")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(isPinned ? "Unpin Sidebar (⌘S)" : "Pin Sidebar (⌘S)")
        }
        .padding(.horizontal, 10)
        .padding(.top, isFloating ? 10 : 30)
        .padding(.bottom, 6)
    }

    private var tabList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(session.tabs) { tab in
                    row(for: tab)
                }
                // Sits directly under the last tab and scrolls with the list, so
                // it reads as "add one more here" rather than a fixed control.
                newTabButton
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private var newTabButton: some View {
        Button {
            session.addTab()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 13, height: 13)
                Text("New Tab")
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }
            // Matches a tab row's metrics exactly, so it lines up with the list.
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
        .onHover { isHoveringNewTab = $0 }
        .help("New Tab (⌘T)")
    }

    private func row(for tab: Tab) -> some View {
        let isSelected = tab.id == session.selectedTabID
        let isHovered = hoveredTab == tab.id

        return HStack(spacing: 7) {
            statusIcon(for: tab)

            Text(tab.displayTitle)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                // Not-yet-restored tabs read as dimmed, so it's obvious they
                // haven't loaded rather than looking broken.
                .opacity(tab.isAwaitingRestore ? 0.55 : 1)

            Spacer(minLength: 0)

            Button {
                session.close(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 15, height: 15)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovered ? 1 : 0)
            .help("Close Tab (⌘W)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
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

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

    var body: some View {
        VStack(spacing: 0) {
            header
            tabList
            footer
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
            }
            .padding(.horizontal, 8)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            Button {
                session.addTab()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("New Tab")
                        .font(.system(size: 12))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New Tab (⌘T)")
        }
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

    @ViewBuilder
    private func statusIcon(for tab: Tab) -> some View {
        if tab.isLoading {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.5)
                .frame(width: 13, height: 13)
        } else {
            Image(systemName: tab.mode == .home ? "magnifyingglass" : "globe")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 13, height: 13)
        }
    }
}

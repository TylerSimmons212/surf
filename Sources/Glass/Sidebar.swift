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
    /// Opens the floating address bar (the magnifying-glass button, ⌘L).
    let onRequestAddressBar: () -> Void

    @State private var hoveredTab: Tab.ID?
    @State private var isHoveringNewTab = false
    @State private var copiedTab: Tab.ID?

    static let width: CGFloat = 240

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            progressLine
            tabList
        }
        .frame(width: Sidebar.width)
    }

    // MARK: - Navigation

    private var navigationBar: some View {
        let tab = session.selectedTab

        return HStack(spacing: 2) {
            navButton("chevron.left", enabled: tab.canGoBack, help: "Back (⌘[)") {
                tab.goBack()
            }
            navButton("chevron.right", enabled: tab.canGoForward, help: "Forward (⌘])") {
                tab.goForward()
            }
            navButton(
                tab.isLoading ? "xmark" : "arrow.clockwise",
                enabled: tab.mode == .browsing,
                help: tab.isLoading ? "Stop" : "Reload (⌘R)"
            ) {
                tab.isLoading ? tab.stop() : tab.reload()
            }

            Spacer()

            navButton("magnifyingglass", enabled: true, help: "Open Address Bar (⌘L)") {
                onRequestAddressBar()
            }
            navButton(
                isPinned ? "sidebar.left" : "pin",
                enabled: true,
                help: isPinned ? "Unpin Sidebar (⌘S)" : "Pin Sidebar (⌘S)"
            ) {
                isPinned.toggle()
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// The only load indicator left now that the toolbar is gone.
    private var progressLine: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: geometry.size.width * session.selectedTab.progress)
                .opacity(session.selectedTab.isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: session.selectedTab.progress)
                .animation(.easeOut(duration: 0.3), value: session.selectedTab.isLoading)
        }
        .frame(height: 2)
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
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

            Text(tab.displayTitle)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(tab.isAwaitingRestore ? 0.55 : 1)

            Spacer(minLength: 0)

            if showsActions {
                // Momentary checkmark: copying is invisible otherwise, and a
                // silent copy leaves you unsure it worked.
                rowButton(
                    copiedTab == tab.id ? "checkmark" : "link",
                    help: "Copy Link"
                ) {
                    copyURL(of: tab)
                }
                .foregroundStyle(copiedTab == tab.id ? Color.green : Color.secondary)

                rowButton("xmark", help: "Close Tab (⌘W)") {
                    session.close(tab)
                }
            }
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

    private func rowButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 15, height: 15)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private func navButton(
        _ symbol: String,
        enabled: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .help(help)
    }
}

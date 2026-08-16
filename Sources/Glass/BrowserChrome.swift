import SwiftUI

/// The toolbar shown while browsing: navigation controls, address field, and a
/// hairline progress indicator.
struct BrowserChrome: View {
    @Bindable var tab: Tab
    let session: BrowserSession

    /// True only when this is the topmost row, i.e. the tab bar is hidden.
    /// Otherwise the tab bar above already cleared the traffic lights.
    let needsTitlebarInset: Bool

    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if needsTitlebarInset {
                    Spacer().frame(width: 68)
                }

                navButton("chevron.left", enabled: tab.canGoBack, help: "Back") {
                    tab.goBack()
                }
                navButton("chevron.right", enabled: tab.canGoForward, help: "Forward") {
                    tab.goForward()
                }
                navButton(
                    tab.isLoading ? "xmark" : "arrow.clockwise",
                    enabled: true,
                    help: tab.isLoading ? "Stop" : "Reload"
                ) {
                    tab.isLoading ? tab.stop() : tab.reload()
                }
                navButton("house", enabled: true, help: "New Search") {
                    tab.goHome()
                }

                addressField
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            progressBar
        }
        .background(.bar)
        // ⌘L: the session bumps a token, and whichever chrome is on screen
        // takes focus. A token rather than a flag so repeats each register.
        .onChange(of: session.focusAddressToken) { _, _ in
            addressFocused = true
        }
    }

    private var addressField: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.lastError == nil ? "magnifyingglass" : "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(tab.lastError == nil ? Color.secondary : Color.orange)

            TextField("Search or enter address", text: $tab.addressText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($addressFocused)
                .onSubmit {
                    tab.submit(tab.addressText)
                    addressFocused = false
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.5))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            addressFocused ? Color.accentColor.opacity(0.7) : .clear,
                            lineWidth: 2
                        )
                }
        }
        // Select-all on focus, so typing replaces the URL like every other browser.
        .onChange(of: addressFocused) { _, focused in
            if focused { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
        }
    }

    /// Only visible mid-load; a persistent 0%-wide bar reads as a broken UI.
    private var progressBar: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: geometry.size.width * tab.progress)
                .opacity(tab.isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: tab.progress)
                .animation(.easeOut(duration: 0.3), value: tab.isLoading)
        }
        .frame(height: 2)
    }

    private func navButton(
        _ symbol: String,
        enabled: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .help(help)
    }
}

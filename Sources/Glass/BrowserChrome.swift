import SwiftUI

/// The toolbar shown while browsing: navigation controls, address field, and a
/// hairline progress indicator.
struct BrowserChrome: View {
    @Bindable var engine: BrowserEngine
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // Leading inset clears the traffic lights, since the window
                // uses a hidden titlebar with full-size content.
                Spacer().frame(width: 68)

                navButton("chevron.left", enabled: engine.canGoBack, help: "Back") {
                    engine.goBack()
                }
                navButton("chevron.right", enabled: engine.canGoForward, help: "Forward") {
                    engine.goForward()
                }
                navButton(
                    engine.isLoading ? "xmark" : "arrow.clockwise",
                    enabled: true,
                    help: engine.isLoading ? "Stop" : "Reload"
                ) {
                    engine.isLoading ? engine.stop() : engine.reload()
                }
                navButton("house", enabled: true, help: "New Search") {
                    engine.goHome()
                }

                addressField
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            progressBar
        }
        .background(.bar)
    }

    private var addressField: some View {
        HStack(spacing: 8) {
            Image(systemName: engine.lastError == nil ? "magnifyingglass" : "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(engine.lastError == nil ? Color.secondary : Color.orange)

            TextField("Search or enter address", text: $engine.addressText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($addressFocused)
                .onSubmit {
                    engine.submit(engine.addressText)
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
                .frame(width: geometry.size.width * engine.progress)
                .opacity(engine.isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: engine.progress)
                .animation(.easeOut(duration: 0.3), value: engine.isLoading)
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

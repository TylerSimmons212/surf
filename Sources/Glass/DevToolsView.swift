import GlassCore
import SwiftUI

/// The dev tools panel's root: a pane switcher, the pane, and a status footer.
struct DevToolsView: View {
    @Bindable var session: DevToolsSession

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                switch session.pane {
                case .elements: ElementsPane(session: session)
                case .console: ConsolePane(session: session)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: $session.pane) {
                ForEach(DevToolsSession.Pane.allCases) { pane in
                    Label(pane.label, systemImage: pane.symbol).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer(minLength: 8)

            // The page being inspected, so two open panels are never ambiguous.
            Text(session.pageURL)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(session.pageURL)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            statusDot
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            // Said plainly and up front rather than discovered as a missing
            // menu: the debugger isn't coming, and this is where it lives.
            Button("Debug in Safari…") {
                if let tab = session.tab {
                    DevToolsController.shared.handOffToSafari(tab)
                }
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 6, height: 6)
    }

    private var statusColor: Color {
        switch session.status {
        case .connecting: .orange
        case .connected: .green
        case .unavailable: .secondary
        }
    }

    private var statusText: String {
        switch session.status {
        case .connecting:
            "Connecting…"
        case .connected(let nodeCount):
            "Connected · \(nodeCount.formatted()) elements"
        case .unavailable(let reason):
            reason
        }
    }
}

/// Placeholder until Phase 3.
struct ElementsPane: View {
    let session: DevToolsSession

    var body: some View {
        DevToolsPlaceholder(
            symbol: "chevron.left.forwardslash.chevron.right",
            title: "Elements",
            detail: "The DOM tree and styles land here."
        )
    }
}

/// Placeholder until Phase 1.
struct ConsolePane: View {
    let session: DevToolsSession

    var body: some View {
        DevToolsPlaceholder(
            symbol: "terminal",
            title: "Console",
            detail: "Page logs and a JavaScript prompt land here."
        )
    }
}

struct DevToolsPlaceholder: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

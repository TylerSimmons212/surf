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
                case .styles: StylesPane(session: session)
                case .network: NetworkPane(session: session)
                case .storage: StoragePane(session: session)
                case .performance: PerformancePane(session: session)
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
            // The stock control, deliberately.
            //
            // There is no glass picker style and no glass toggle style — the
            // system control adopts Liquid Glass on its own when built against
            // the macOS 26 SDK, and supplies the interaction, the metrics, the
            // shape, and "tab, 1 of 2" for VoiceOver. A hand-rolled version
            // hit three things Apple names as anti-patterns: a solid fill
            // behind glass, glass clipped by a shape the container had already
            // resolved, and glass sampling glass across containers — which
            // WWDC25 explicitly says produces inconsistent behaviour.
            //
            // The macOS HIG sanctions a segmented control for exactly this
            // case: switching views in an inspector pane.
            Picker("Pane", selection: $session.pane) {
                ForEach(DevToolsSession.Pane.allCases) { pane in
                    Text(pane.label).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            // Small, not regular: 20pt rather than 24pt, which suits a dense
            // inspector header sitting above monospaced rows.
            //
            // Note the shape needs no help. Measured on macOS 26, a segmented
            // control is a rounded rectangle at mini through medium sizes
            // (r≈4.4pt here) and only rounds into a capsule at large and
            // extra-large. The pill look this replaced came from a hand-rolled
            // control, not from the system.
            .controlSize(.small)
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

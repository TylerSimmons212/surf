import SurfCore
import SwiftUI

/// The dev tools panel's root: a rail of panes, and the pane.
///
/// Everything that used to sit in a header and a footer around this now lives
/// in the title bar (the page and the connection state, set by
/// `DevToolsController`) or in the Develop menu ("Debug in Safari…", which the
/// footer was duplicating). That is roughly 50pt of permanent chrome handed
/// back to the pane, on a window whose whole job is showing you as much as it
/// can at once.
struct DevToolsView: View {
    @Bindable var session: DevToolsSession

    var body: some View {
        HStack(spacing: 0) {
            PaneRail(session: session)
            Divider()

            Group {
                switch session.pane {
                case .elements: ElementsPane(session: session)
                case .styles: StylesPane(session: session)
                case .network: NetworkPane(session: session)
                case .storage: StoragePane(session: session)
                case .tags: TagsPane(session: session)
                case .performance: PerformancePane(session: session)
                case .console: ConsolePane(session: session)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
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

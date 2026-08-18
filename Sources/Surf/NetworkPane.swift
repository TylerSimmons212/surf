import SurfCore
import SwiftUI

/// What the page asked for, and how it went.
///
/// The honesty problem this pane has to solve, and which the shape of it is
/// built around: WebKit exposes no status code for anything that isn't `fetch`
/// or `XMLHttpRequest`. An image that 404s and one that loaded are, as far as
/// any inspector can see, identical. So a statusless row says so — a dash and
/// a muted style — rather than borrowing the look of a success it can't
/// actually vouch for.
struct NetworkPane: View {
    @Bindable var session: DevToolsSession

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            filters
            Divider()

            if session.visibleRequests.isEmpty {
                empty
            } else {
                HSplitView {
                    list.frame(minWidth: 320)
                    if session.selectedRequestDetail != nil {
                        RequestDetail(session: session).frame(minWidth: 260)
                    }
                }
            }

            Divider()
            footer
        }
        .sheet(isPresented: Binding(
            get: { session.replayDraft != nil },
            set: { if !$0 { session.cancelReplay() } }
        )) {
            if session.replayDraft != nil {
                ReplayEditor(
                    session: session,
                    draft: Binding(
                        get: { session.replayDraft ?? ReplayRequest() },
                        set: { session.replayDraft = $0 }
                    )
                )
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            IconButton(
                systemName: "nosign", size: 12, weight: .medium,
                width: 26, height: 22, cornerRadius: DevToolsTheme.corner,
                help: "Clear the list"
            ) {
                session.clearNetwork()
            }

            Toggle("Preserve log", isOn: $session.preservesNetworkOnNavigation)
                .toggleStyle(.checkbox)
                .font(DevToolsTheme.chrome)

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                TextField("Filter URLs", text: $session.networkQuery)
                    .textFieldStyle(.plain)
                    .font(DevToolsTheme.chrome)
                    .frame(width: 150)
                if !session.networkQuery.isEmpty {
                    Button {
                        session.networkQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: DevToolsTheme.corner, style: .continuous)
                    .fill(DevToolsTheme.inputFill)
            }
        }
        .padding(.horizontal, DevToolsTheme.barInset)
        .padding(.vertical, DevToolsTheme.barVertical)
    }

    private var filters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                KindChip(
                    label: "All",
                    count: session.network.count,
                    isOn: session.networkKinds.count == NetworkKind.allCases.count
                ) {
                    session.networkKinds = Set(NetworkKind.allCases)
                }

                ForEach(NetworkKind.allCases) { kind in
                    let count = session.networkCounts[kind] ?? 0
                    if count > 0 {
                        KindChip(
                            label: kind.label,
                            count: count,
                            isOn: session.networkKinds == [kind]
                        ) {
                            // Clicking a chip narrows to just that kind, which
                            // is what people want nine times in ten; All goes
                            // back.
                            session.networkKinds = session.networkKinds == [kind]
                                ? Set(NetworkKind.allCases) : [kind]
                        }
                    }
                }
            }
            .padding(.horizontal, DevToolsTheme.barInset)
            .padding(.vertical, 4)
        }
        .frame(height: 26)
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(session.visibleRequests) { request in
                        RequestRow(
                            request: request,
                            span: session.networkSummary.finishedAt,
                            isSelected: session.selectedRequest == request.id
                        ) {
                            session.selectRequest(
                                session.selectedRequest == request.id ? nil : request.id
                            )
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("Name").frame(width: NetworkColumns.name, alignment: .leading)
            Text("Status").frame(width: NetworkColumns.status, alignment: .leading)
            Text("Type").frame(width: NetworkColumns.kind, alignment: .leading)
            Text("Size").frame(width: NetworkColumns.size, alignment: .trailing)
            Text("Time").frame(width: NetworkColumns.time, alignment: .trailing)
            Text("Waterfall")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, DevToolsTheme.rowInset)
        .padding(.vertical, 4)
    }

    private var empty: some View {
        DevToolsPlaceholder(
            symbol: session.isNetworkFiltered ? "line.3.horizontal.decrease" : "arrow.up.arrow.down",
            title: session.isNetworkFiltered ? "Nothing matches" : "No requests yet",
            detail: session.isNetworkFiltered
                ? "\(session.network.count) recorded, all filtered out."
                : "Requests are recorded from the moment the page starts, so reloading isn't necessary."
        )
        .frame(maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        let summary = session.networkSummary
        return HStack(spacing: 10) {
            Text("\(summary.count) request\(summary.count == 1 ? "" : "s")")

            if summary.problems > 0 {
                Label("\(summary.problems) failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            // Stated as a floor, because a cross-origin response served without
            // Timing-Allow-Origin withholds its size — and a total that quietly
            // omitted them would be wrong rather than approximate.
            Text(
                summary.opaqueCount > 0
                    ? "≥ \(NetworkRequest.formatBytes(summary.transferred)) transferred"
                    : "\(NetworkRequest.formatBytes(summary.transferred)) transferred"
            )
            .help(
                summary.opaqueCount > 0
                    ? "\(summary.opaqueCount) cross-origin responses withheld their size"
                    : "Total transferred"
            )

            Spacer(minLength: 8)

            if session.isNetworkFiltered {
                Text("filtered")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(DevToolsTheme.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, DevToolsTheme.barInset)
        .padding(.vertical, 5)
    }
}

enum NetworkColumns {
    static let name: CGFloat = 170
    static let status: CGFloat = 52
    static let kind: CGFloat = 54
    static let size: CGFloat = 64
    static let time: CGFloat = 62
}

private struct KindChip: View {
    let label: String
    let count: Int
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(label)
                Text("\(count)")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .font(DevToolsTheme.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isOn ? Color.accentColor.opacity(0.18) : DevToolsTheme.hoverFill)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct RequestRow: View {
    let request: NetworkRequest
    let span: Double
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                if request.isReplay {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.accentColor)
                        .help("Replayed")
                }
                Text(request.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if request.isOpaque {
                    // Says why the row is short on detail, rather than letting
                    // it look like a request nothing was recorded for.
                    Image(systemName: "eye.slash")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .help("Cross-origin: this response withheld its timing and size")
                }
            }
            .frame(width: NetworkColumns.name, alignment: .leading)

            Text(request.statusLabel)
                .foregroundStyle(statusColor)
                .frame(width: NetworkColumns.status, alignment: .leading)
                .help(statusHelp)

            Text(request.kind.label)
                .foregroundStyle(.secondary)
                .frame(width: NetworkColumns.kind, alignment: .leading)

            Text(request.sizeLabel)
                .foregroundStyle(request.transferSize == nil ? .tertiary : .secondary)
                .frame(width: NetworkColumns.size, alignment: .trailing)

            Text(request.timeLabel)
                .foregroundStyle(.secondary)
                .frame(width: NetworkColumns.time, alignment: .trailing)

            Waterfall(request: request, span: span)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
        }
        .font(.system(size: 11).monospacedDigit())
        .padding(.horizontal, DevToolsTheme.rowInset)
        .padding(.vertical, 2.5)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.22)
                : (isHovering ? DevToolsTheme.hoverFill : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(request.url, forType: .string)
            }
        }
    }

    private var statusColor: Color {
        switch request.statusClass {
        case .success: NetworkStyle.success
        case .redirect: NetworkStyle.redirect
        case .clientError, .serverError, .failed: NetworkStyle.error
        // Deliberately muted rather than neutral-positive: this row is not
        // claiming the request worked.
        case .unknown, .pending, .informational: .secondary
        }
    }

    private var statusHelp: String {
        switch request.statusClass {
        case .unknown:
            "No status is available — WebKit reports one only for fetch and XHR"
        case .failed:
            request.failure ?? "Request failed"
        default:
            request.statusText.isEmpty ? request.statusLabel : request.statusText
        }
    }
}

/// When the request happened, laid against every other one.
///
/// The single most useful column in a network pane, because "what was waiting
/// on what" is a shape rather than a number.
private struct Waterfall: View {
    let request: NetworkRequest
    let span: Double

    var body: some View {
        GeometryReader { geometry in
            let total = max(span, 1)
            let width = geometry.size.width
            let start = CGFloat(request.startedAt / total) * width
            let length = max(2, CGFloat((request.duration ?? 0) / total) * width)

            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(request.statusClass.isProblem ? NetworkStyle.error : Color.accentColor)
                .opacity(request.duration == nil ? 0.35 : 0.75)
                .frame(width: length, height: 6)
                .offset(x: min(start, max(0, width - length)), y: (geometry.size.height - 6) / 2)
        }
        .frame(height: 14)
    }
}

enum NetworkStyle {
    static let success = DevToolsTheme.adaptive(
        light: (0.14, 0.43, 0.24), dark: (0.60, 0.85, 0.52)
    )
    static let redirect = DevToolsTheme.adaptive(
        light: (0.62, 0.44, 0.10), dark: (0.95, 0.78, 0.40)
    )
    static let error = DevToolsTheme.adaptive(
        light: (0.72, 0.17, 0.17), dark: (1.0, 0.52, 0.48)
    )
}

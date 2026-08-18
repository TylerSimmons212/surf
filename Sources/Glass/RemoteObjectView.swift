import GlassCore
import SwiftUI

/// One expandable value in the console.
///
/// Properties are fetched only when opened. Sending them with every log would
/// be ruinous — a single DOM node has several hundred — which is exactly why
/// values cross the bridge as handles rather than as trees.
struct RemoteObjectView: View {
    let session: DevToolsSession
    let object: RemoteObject
    /// Guards against a cyclic graph walked by hand: `a.b.a.b.a…` is finite
    /// only because this stops it.
    var depth: Int = 0

    @State private var isExpanded = false
    @State private var properties: [ObjectProperty] = []
    @State private var totalProperties = 0
    @State private var isLoading = false
    private static let maximumDepth = 12
    /// Enough to see what an object is in one screen, and cheap enough that
    /// opening it feels instant even on a heavy page.
    private static let pageSize = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            header

            if isExpanded {
                if isLoading && properties.isEmpty {
                    Text("Reading…")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 16)
                } else if properties.isEmpty {
                    Text("No properties")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 16)
                } else {
                    // Paged rather than all at once. These rows sit inside a
                    // `LazyVStack` row, which means they are *not* lazy: opening
                    // a DOM node would otherwise build three hundred views in
                    // one frame and drop it.
                    ForEach(properties) { property in
                        PropertyRow(session: session, property: property, depth: depth + 1)
                    }
                    .padding(.leading, DevToolsTheme.indent)

                    if totalProperties > properties.count {
                        // Never a silent truncation: an object that shows a
                        // hundred properties when it has five thousand is lying
                        // about the thing you opened it to find out.
                        Button(isLoading
                               ? "Reading…"
                               : "Show \((totalProperties - properties.count).formatted()) more of \(totalProperties.formatted())") {
                            loadMore()
                        }
                        .buttonStyle(.plain)
                        .font(DevToolsTheme.chrome)
                        .foregroundStyle(isLoading ? Color.secondary : Color.accentColor)
                        .disabled(isLoading)
                        .padding(.leading, DevToolsTheme.indent * 2)
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if isExpandable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: DevToolsTheme.discloseWidth)
            } else {
                // Keeps values aligned whether or not they can be opened.
                Color.clear.frame(width: DevToolsTheme.discloseWidth, height: 1)
            }

            Text(label)
                .font(DevToolsTheme.mono)
                .foregroundStyle(ConsoleStyle.valueColor(for: object))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .contentShape(Rectangle())
        .onTapGesture { if isExpandable { toggle() } }
        .help(hint)
    }

    /// A backlogged value was serialized before dev tools opened and its
    /// reference dropped, so there is nothing left to expand. Showing a
    /// disclosure arrow that does nothing would be worse than showing none.
    private var isExpandable: Bool {
        object.objectId != nil && depth < Self.maximumDepth
    }

    private var hint: String {
        guard !isExpandable, object.preview != nil else { return "" }
        return "Logged before developer tools were open, so this can't be expanded."
    }

    private var label: String {
        var text = object.description
        if let preview = object.preview, !preview.entries.isEmpty {
            text += " " + ConsoleStyle.previewText(preview, subtype: object.subtype)
        }
        return text
    }

    private func toggle() {
        isExpanded.toggle()
        guard isExpanded, properties.isEmpty, let objectId = object.objectId else { return }
        isLoading = true
        Task { @MainActor in
            let reply = await session.properties(of: objectId, limit: Self.pageSize)
            properties = reply.properties
            totalProperties = reply.total
            isLoading = false
        }
    }

    private func loadMore() {
        guard let objectId = object.objectId, !isLoading else { return }
        isLoading = true
        Task { @MainActor in
            let reply = await session.properties(
                of: objectId, offset: properties.count, limit: Self.pageSize * 4
            )
            properties.append(contentsOf: reply.properties)
            totalProperties = max(totalProperties, reply.total)
            isLoading = false
        }
    }
}

private struct PropertyRow: View {
    let session: DevToolsSession
    let property: ObjectProperty
    let depth: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(property.name + ":")
                .font(DevToolsTheme.mono)
                // Non-enumerable properties are dimmed rather than hidden: they
                // are real, but they aren't what you came to look at.
                .foregroundStyle(property.isEnumerable ? Color.secondary : Color.secondary.opacity(0.55))
                .textSelection(.enabled)

            if property.isAccessor {
                Text("(…)")
                    .font(DevToolsTheme.mono)
                    .foregroundStyle(.tertiary)
                    .help("A getter. Glass won't run it — evaluating it could change the page.")
            } else {
                RemoteObjectView(session: session, object: property.value, depth: depth)
            }
        }
    }
}

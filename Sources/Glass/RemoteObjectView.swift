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
    @State private var isLoading = false

    private static let maximumDepth = 12

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
                    ForEach(properties) { property in
                        PropertyRow(session: session, property: property, depth: depth + 1)
                    }
                    .padding(.leading, 14)
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
                    .frame(width: 10)
            } else {
                // Keeps values aligned whether or not they can be opened.
                Color.clear.frame(width: 10, height: 1)
            }

            Text(label)
                .font(.system(size: 11.5).monospaced())
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
            properties = await session.properties(of: objectId)
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
                .font(.system(size: 11.5).monospaced())
                // Non-enumerable properties are dimmed rather than hidden: they
                // are real, but they aren't what you came to look at.
                .foregroundStyle(property.isEnumerable ? Color.secondary : Color.secondary.opacity(0.55))
                .textSelection(.enabled)

            if property.isAccessor {
                Text("(…)")
                    .font(.system(size: 11.5).monospaced())
                    .foregroundStyle(.tertiary)
                    .help("A getter. Glass won't run it — evaluating it could change the page.")
            } else {
                RemoteObjectView(session: session, object: property.value, depth: depth)
            }
        }
    }
}

import GlassCore
import SwiftUI

/// The selected element, taken apart attribute by attribute.
///
/// The problem this solves is specific and ordinary: a Tailwind element
/// carries forty classes on one line, an inline `style` carries a dozen
/// declarations, a `data-` attribute carries a JSON blob — and every devtools
/// shows each of them as one unbroken string running off the edge of the pane.
/// The information is right there and completely unreadable.
struct ElementDetail: View {
    let session: DevToolsSession

    @State private var expanded: Set<String> = ["class", "style"]
    @State private var filter = ""

    private var node: DOMNode? {
        session.selectedNode.flatMap { session.tree[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if let node {
                Text(node.displayName)
                    .font(DevToolsTheme.mono)
                    .foregroundStyle(ElementsStyle.tagColor)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("\(node.attributes.count) attribute\(node.attributes.count == 1 ? "" : "s")")
                    .font(DevToolsTheme.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            if (node?.attributes.count ?? 0) > 1 || anyExpandable {
                filterField
            }
        }
        .padding(.horizontal, DevToolsTheme.barInset)
        .padding(.vertical, DevToolsTheme.barVertical)
    }

    private var filterField: some View {
        HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            TextField("Filter", text: $filter)
                .textFieldStyle(.plain)
                .font(DevToolsTheme.chrome)
                .frame(width: 110)

            if !filter.isEmpty {
                Button {
                    filter = ""
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

    private var anyExpandable: Bool {
        node?.attributes.contains {
            AttributeBreakdown.isExpandable(name: $0.name, value: $0.value)
        } ?? false
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let node, !node.attributes.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(node.attributes) { attribute in
                        AttributeRow(
                            attribute: attribute,
                            filter: filter,
                            isExpanded: expanded.contains(attribute.name),
                            onToggle: { toggle(attribute.name) }
                        )
                    }
                }
                .padding(.horizontal, DevToolsTheme.unit * 2)
                .padding(.vertical, DevToolsTheme.unit)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if node != nil {
            DevToolsPlaceholder(
                symbol: "tag",
                title: "No attributes",
                detail: "This element carries none."
            )
        } else {
            DevToolsPlaceholder(
                symbol: "hand.point.up.left",
                title: "Nothing selected",
                detail: "Pick an element to break it down."
            )
        }
    }

    private func toggle(_ name: String) {
        withAnimation(.easeOut(duration: 0.14)) {
            if expanded.contains(name) { expanded.remove(name) } else { expanded.insert(name) }
        }
    }
}

// MARK: - One attribute

private struct AttributeRow: View {
    let attribute: DOMAttribute
    let filter: String
    let isExpanded: Bool
    let onToggle: () -> Void

    @State private var isHovering = false

    private var parts: [AttributePart] {
        AttributeBreakdown.parts(of: attribute.name, value: attribute.value)
    }

    private var kind: AttributeValueKind {
        AttributeBreakdown.kind(of: attribute.name, value: attribute.value)
    }

    private var isExpandable: Bool { parts.count > 1 }

    /// Filtering hides pieces, never the attribute itself — an attribute that
    /// vanished because none of its classes matched would look like it wasn't
    /// on the element at all.
    private var visibleParts: [AttributePart] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return parts }
        return parts.filter { $0.text.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            summaryRow
            if isExpanded && isExpandable { expandedBody }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, DevToolsTheme.unit * 1.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DevToolsTheme.corner, style: .continuous)
                .fill(isHovering ? DevToolsTheme.hoverFill : .clear)
        }
        .onHover { isHovering = $0 }
    }

    private var summaryRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if isExpandable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: DevToolsTheme.discloseWidth)
            } else {
                Color.clear.frame(width: DevToolsTheme.discloseWidth, height: 1)
            }

            Text(attribute.name)
                .font(DevToolsTheme.mono)
                .foregroundStyle(ElementsStyle.attributeColor)

            Text(AttributeBreakdown.summary(of: attribute.name, value: attribute.value))
                .font(DevToolsTheme.mono)
                .foregroundStyle(isExpandable ? Color.secondary : ElementsStyle.valueColor)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if isHovering {
                CopyButton(text: attribute.value, help: "Copy \(attribute.name)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if isExpandable { onToggle() } }
    }

    @ViewBuilder
    private var expandedBody: some View {
        let shown = visibleParts

        if shown.isEmpty {
            Text("No matches in this attribute")
                .font(DevToolsTheme.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, DevToolsTheme.indent)
        } else {
            switch kind {
            case .tokenList:
                TokenChips(parts: shown)
                    .padding(.leading, DevToolsTheme.indent)
                    .padding(.top, 2)

            case .styleRules, .json:
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(shown) { part in
                        PairRow(key: part.key ?? "", value: part.value ?? part.text)
                    }
                }
                .padding(.leading, DevToolsTheme.indent)

            case .candidateList:
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(shown) { part in
                        PairRow(key: "\(part.index + 1)", value: part.text)
                    }
                }
                .padding(.leading, DevToolsTheme.indent)

            case .url, .plain:
                Text(shown.first?.text ?? "")
                    .font(DevToolsTheme.mono)
                    .foregroundStyle(ElementsStyle.valueColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, DevToolsTheme.indent)
            }
        }
    }
}

// MARK: - Pieces

/// Classes as chips, grouped by variant.
///
/// The grouping is the whole point: `hover:` styles sitting together, `md:`
/// together, base styles together, instead of forty chips in whatever order
/// the markup happened to list them.
private struct TokenChips: View {
    let parts: [AttributePart]

    private var groups: [(name: String?, parts: [AttributePart])] {
        var order: [String?] = []
        var buckets: [String?: [AttributePart]] = [:]
        for part in parts {
            if buckets[part.group] == nil { order.append(part.group) }
            buckets[part.group, default: []].append(part)
        }
        // Ungrouped first: the base styles are what an element mostly is.
        order.sort { a, b in
            if (a == nil) != (b == nil) { return a == nil }
            return (a ?? "") < (b ?? "")
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 3) {
                    if let name = group.name {
                        HStack(spacing: 4) {
                            Text(name)
                                .font(.system(size: 9, weight: .semibold).monospaced())
                                .foregroundStyle(Color.accentColor)
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.18))
                                .frame(height: 1)
                        }
                    }
                    FlowLayout(spacing: 4, rowSpacing: 4) {
                        ForEach(group.parts) { part in
                            TokenChip(text: part.text, group: part.group)
                        }
                    }
                }
            }
        }
    }
}

private struct TokenChip: View {
    let text: String
    let group: String?

    @State private var isHovering = false
    @State private var justCopied = false

    /// The variant prefix is repeated on every chip in its group, so it's
    /// dimmed — what differs between `md:px-6` and `md:py-3` is the end.
    private var display: (prefix: String, rest: String) {
        guard let group, text.hasPrefix(group + ":") else { return ("", text) }
        return (group + ":", String(text.dropFirst(group.count + 1)))
    }

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(.easeOut(duration: 0.12)) { justCopied = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                withAnimation(.easeOut(duration: 0.2)) { justCopied = false }
            }
        } label: {
            HStack(spacing: 0) {
                if justCopied {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    if !display.prefix.isEmpty {
                        Text(display.prefix)
                            .foregroundStyle(.tertiary)
                    }
                    Text(display.rest)
                        .foregroundStyle(.primary)
                }
            }
            .font(.system(size: 10.5).monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovering ? Color.accentColor.opacity(0.16) : DevToolsTheme.hoverFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        isHovering ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.07),
                        lineWidth: 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Click to copy \(text)")
    }
}

private struct PairRow: View {
    let key: String
    let value: String

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(key)
                .font(DevToolsTheme.mono)
                .foregroundStyle(ElementsStyle.attributeColor)
                // A fixed column so the values line up and can be read down.
                .frame(width: 128, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(value)
                .font(DevToolsTheme.mono)
                .foregroundStyle(ElementsStyle.valueColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            if isHovering {
                CopyButton(text: "\(key): \(value)", help: "Copy declaration")
            }
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 3)
        .background {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isHovering ? DevToolsTheme.hoverFill : .clear)
        }
        .onHover { isHovering = $0 }
    }
}

private struct CopyButton: View {
    let text: String
    let help: String

    @State private var justCopied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            justCopied = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                justCopied = false
            }
        } label: {
            Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(justCopied ? Color.accentColor : Color.secondary)
                .frame(width: 16, height: 14)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

import GlassCore
import SwiftUI

/// The DOM tree, rendered as markup rather than as an outline of labels.
///
/// Reading `<div class="row">` is how anyone who writes HTML already thinks
/// about the document, and syntax colour does more work than an icon column
/// ever could.
struct ElementsPane: View {
    @Bindable var session: DevToolsSession

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            tree
            if !session.breadcrumb.isEmpty { Divider() }
            breadcrumb
        }
        // Escape reaches the page's own handler only while the page has focus.
        // If the panel is what's focused, this is the one that fires.
        .onKeyPress(.escape) {
            guard session.isPicking else { return .ignored }
            session.setPicking(false)
            return .handled
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            IconButton(
                systemName: "cursorarrow.rays",
                size: 12,
                weight: .medium,
                width: 26,
                height: 22,
                cornerRadius: DevToolsTheme.corner,
                tint: session.isPicking ? Color.accentColor : nil,
                help: "Select an element on the page (⌥⌘C)"
            ) {
                session.setPicking(!session.isPicking)
            }

            if session.isPicking {
                Text("Click an element · esc to cancel")
                    .font(DevToolsTheme.chrome)
                    .foregroundStyle(Color.accentColor)
            }

            Spacer(minLength: 8)

            if let box = session.selectedBox {
                // The measurement people actually came for, always on screen
                // rather than behind a tab.
                Text(box.sizeLabel)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Border box, in CSS pixels")
            }

            if session.selectedNode != nil {
                IconButton(
                    systemName: "scope",
                    size: 11, weight: .medium, width: 24, height: 22,
                    cornerRadius: DevToolsTheme.corner,
                    help: "Scroll the page to this element"
                ) {
                    if let id = session.selectedNode { session.scrollPageTo(id) }
                }

                IconButton(
                    systemName: "doc.on.doc",
                    size: 11, weight: .medium, width: 24, height: 22,
                    cornerRadius: DevToolsTheme.corner,
                    help: "Copy selector"
                ) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.selectedSelector, forType: .string)
                }
            }
        }
        .padding(.horizontal, DevToolsTheme.barInset)
        .padding(.vertical, DevToolsTheme.barVertical)
    }

    // MARK: - Tree

    private var tree: some View {
        ScrollViewReader { proxy in
            // Vertical only. A horizontal scroll view proposes an unbounded
            // width to its children, so rows asking for `maxWidth: .infinity`
            // collapsed to nothing — every tag truncated to "<he…" and the
            // whole tree drifted to the centre. Long rows truncate at the
            // right edge instead, which is what a tree wants anyway.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(session.visibleRows) { row in
                        DOMRowView(session: session, row: row)
                            .id(row.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, DevToolsTheme.unit)
            }
            .overlay {
                if session.visibleRows.isEmpty {
                    DevToolsPlaceholder(
                        symbol: "chevron.left.forwardslash.chevron.right",
                        title: "No document",
                        detail: "This page has nothing Glass can inspect."
                    )
                }
            }
            .onChange(of: session.selectedNode) { _, value in
                guard let value else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("\(value).whole", anchor: .center)
                }
            }
        }
    }

    // MARK: - Breadcrumb

    @ViewBuilder
    private var breadcrumb: some View {
        if session.breadcrumb.isEmpty {
            EmptyView()
        } else {
            breadcrumbBar
        }
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 3) {
                ForEach(session.breadcrumb) { node in
                    Button {
                        session.select(node.id)
                    } label: {
                        Text(node.displayName)
                            .font(DevToolsTheme.caption.monospaced())
                            .foregroundStyle(
                                node.id == session.selectedNode ? Color.primary : Color.secondary
                            )
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background {
                                if node.id == session.selectedNode {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(DevToolsTheme.hoverFill)
                                }
                            }
                    }
                    .buttonStyle(.plain)

                    if node.id != session.breadcrumb.last?.id {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, DevToolsTheme.barInset)
            .padding(.vertical, 5)
        }
        .frame(height: 24)
    }
}

// MARK: - Rows

private struct DOMRowView: View {
    let session: DevToolsSession
    let row: DOMRow

    @State private var isHovering = false

    private var node: DOMNode? { session.tree[row.nodeId] }
    private var isSelected: Bool { session.selectedNode == row.nodeId }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            disclosure
            markup
        }
        .padding(.leading, DevToolsTheme.rowInset + indent)
        .padding(.trailing, DevToolsTheme.rowInset)
        .padding(.vertical, 1.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .contentShape(Rectangle())
        .onTapGesture { session.select(row.nodeId) }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy Selector") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    session.tree.selectorPath(to: row.nodeId), forType: .string
                )
            }
            Button("Scroll Into View") { session.scrollPageTo(row.nodeId) }
        }
    }

    @ViewBuilder
    private var disclosure: some View {
        // Only the opening half of a node carries the triangle; the closing
        // tag is punctuation, not a control.
        if let node, node.hasChildren, row.kind != .close, !session.tree.isInlineText(node) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(session.tree.isExpanded(row.nodeId) ? 90 : 0))
                .frame(width: DevToolsTheme.discloseWidth)
                .contentShape(Rectangle())
                .onTapGesture { session.toggle(row.nodeId) }
        } else {
            Color.clear.frame(width: DevToolsTheme.discloseWidth, height: 1)
        }
    }

    /// Indentation stops deepening past a point. A document nested forty
    /// levels down would otherwise push its own markup off the right edge,
    /// which is the one thing a tree must never do.
    private var indent: CGFloat {
        CGFloat(min(row.depth, 16)) * DevToolsTheme.indent
    }

    private var markup: some View {
        Text(attributed)
            .font(DevToolsTheme.mono)
            .lineLimit(1)
            .truncationMode(.tail)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The row as syntax-coloured markup.
    private var attributed: AttributedString {
        guard let node else { return AttributedString("") }

        switch node.nodeType {
        case .text:
            var text = AttributedString(node.value.trimmingCharacters(in: .whitespacesAndNewlines))
            text.foregroundColor = ElementsStyle.text
            return text

        case .comment:
            var text = AttributedString("<!-- \(node.value.trimmingCharacters(in: .whitespacesAndNewlines)) -->")
            text.foregroundColor = ElementsStyle.comment
            return text

        case .doctype:
            var text = AttributedString("<!DOCTYPE html>")
            text.foregroundColor = ElementsStyle.comment
            return text

        case .fragment, .shadowRoot:
            var text = AttributedString("#shadow-root")
            text.foregroundColor = ElementsStyle.comment
            return text

        case .document, .element:
            return elementMarkup(node)
        }
    }

    private func elementMarkup(_ node: DOMNode) -> AttributedString {
        let tag = node.nodeName.lowercased()

        if row.kind == .close {
            return ElementsStyle.punct("</") + ElementsStyle.tag(tag) + ElementsStyle.punct(">")
        }

        var result = ElementsStyle.punct("<") + ElementsStyle.tag(tag)
        for attribute in node.attributes {
            result += ElementsStyle.punct(" ")
            result += ElementsStyle.attributeName(attribute.name)
            if !attribute.value.isEmpty {
                result += ElementsStyle.punct("=")
                result += ElementsStyle.attributeValue("\"\(attribute.value)\"")
            }
        }
        result += ElementsStyle.punct(">")

        guard row.kind == .whole else { return result }

        // A whole row still has to account for what's inside it.
        if session.tree.isInlineText(node),
           let childId = node.childIds?.first,
           let child = session.tree[childId] {
            result += ElementsStyle.plain(child.value.trimmingCharacters(in: .whitespacesAndNewlines))
            result += ElementsStyle.punct("</") + ElementsStyle.tag(tag) + ElementsStyle.punct(">")
        } else if node.hasChildren {
            // Collapsed: an ellipsis stands in for everything hidden, and the
            // closing tag proves the element didn't simply end here.
            result += ElementsStyle.ellipsis("…")
            result += ElementsStyle.punct("</") + ElementsStyle.tag(tag) + ElementsStyle.punct(">")
        }
        return result
    }

    private var background: some View {
        Rectangle().fill(
            isSelected
                ? Color.accentColor.opacity(0.22)
                : (session.hoveredNode == row.nodeId
                    ? Color.accentColor.opacity(0.10)
                    : (isHovering ? DevToolsTheme.hoverFill : .clear))
        )
    }
}

enum ElementsStyle {
    static let tagColor = Color(red: 0.51, green: 0.24, blue: 0.62)
    static let attributeColor = Color(red: 0.76, green: 0.42, blue: 0.16)
    static let valueColor = Color(red: 0.14, green: 0.43, blue: 0.24)
    static let comment = Color.secondary
    static let text = Color.primary

    static func tag(_ value: String) -> AttributedString {
        var text = AttributedString(value)
        text.foregroundColor = tagColor
        return text
    }

    static func attributeName(_ value: String) -> AttributedString {
        var text = AttributedString(value)
        text.foregroundColor = attributeColor
        return text
    }

    static func attributeValue(_ value: String) -> AttributedString {
        var text = AttributedString(value)
        text.foregroundColor = valueColor
        return text
    }

    static func punct(_ value: String) -> AttributedString {
        var text = AttributedString(value)
        text.foregroundColor = .secondary
        return text
    }

    static func plain(_ value: String) -> AttributedString {
        var text = AttributedString(value)
        text.foregroundColor = .primary
        return text
    }

    static func ellipsis(_ value: String) -> AttributedString {
        var text = AttributedString(value)
        text.foregroundColor = Color.secondary.opacity(0.6)
        return text
    }
}

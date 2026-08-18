import SurfCore
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

            // A real split rather than a fixed proportion: how much tree
            // against how much detail depends entirely on what you're doing,
            // and VSplitView gives a draggable divider that remembers itself.
            VSplitView {
                tree
                    .frame(minHeight: 120)
                ElementDetail(session: session)
                    .frame(minHeight: 100)
            }

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
        .onKeyPress(.rightArrow) { session.expandSelection(); return .handled }
        .onKeyPress(.leftArrow) { session.collapseSelection(); return .handled }
        .onKeyPress(.downArrow) { session.moveSelection(by: 1); return .handled }
        .onKeyPress(.upArrow) { session.moveSelection(by: -1); return .handled }
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

                // The element itself, next to the selector for it. Two
                // different answers to "copy this", and which one is wanted
                // isn't guessable — so both are offered rather than one being
                // chosen on the reader's behalf.
                IconButton(
                    systemName: "chevron.left.forwardslash.chevron.right",
                    size: 11, weight: .medium, width: 24, height: 22,
                    cornerRadius: DevToolsTheme.corner,
                    help: "Copy element, including its children"
                ) {
                    guard let id = session.selectedNode else { return }
                    Task { @MainActor in
                        guard let html = await session.outerHTML(of: id) else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(html, forType: .string)
                    }
                }
            }
        }
        .padding(.horizontal, DevToolsTheme.barInset)
        .padding(.vertical, DevToolsTheme.barVertical)
    }

    // MARK: - Tree

    /// The id of the row currently standing for the selection, if it is on
    /// screen at all.
    private var scrollTarget: String? {
        guard let selected = session.selectedNode else { return nil }
        return session.visibleRows.first { $0.nodeId == selected }?.id
    }

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
                        detail: "This page has nothing Surf can inspect."
                    )
                }
            }
            // Keyed on the row that actually exists, not on a guess at its
            // id. A row's identity carries its kind, so an expanded node's row
            // is `<id>.open` and a collapsed one's is `<id>.whole` — scrolling
            // to a hard-coded `.whole` silently did nothing for every node
            // that happened to be open.
            //
            // Watching the resolved target rather than the selection also
            // waits for the row to exist: revealing a picked node fetches its
            // ancestors asynchronously, so at the moment the selection changes
            // there is often nothing to scroll to yet.
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(target, anchor: .center)
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
    @State private var isHoveringDisclosure = false

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
        // Double-click opens, single-click selects — the same as a file list,
        // and a much larger target than the triangle for the common case.
        .onTapGesture(count: 2) { session.toggle(row.nodeId) }
        .onTapGesture { session.select(row.nodeId) }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy Selector") {
                copy(session.tree.selectorPath(to: row.nodeId))
            }
            // The element and everything inside it, which is what "copy this"
            // nearly always means — and the one thing the row itself can't
            // provide, since a row is one line and an element is a subtree.
            Button("Copy Element") {
                Task { @MainActor in
                    guard let html = await session.outerHTML(of: row.nodeId) else { return }
                    copy(html)
                }
            }
            // Just this line, for when the subtree is the part you don't want.
            // Replaces what dragging across the row used to give you.
            Button("Copy Opening Tag") {
                copy(String(attributed.characters))
            }
            if let node, node.nodeType == .text || node.nodeType == .comment {
                Button("Copy Text") { copy(node.value) }
            }
            Divider()
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
                .foregroundStyle(isHoveringDisclosure ? Color.primary : Color.secondary)
                .rotationEffect(.degrees(session.tree.isExpanded(row.nodeId) ? 90 : 0))
                // The glyph stays small; the target does not. At the drawn size
                // this was a 10×8pt hit area, so most attempts to open a node
                // missed it and selected the row instead — which reads as the
                // triangle being broken rather than as having been missed.
                .frame(width: DevToolsTheme.discloseWidth, height: 16)
                .contentShape(Rectangle())
                .onHover { isHoveringDisclosure = $0 }
                .onTapGesture { session.toggle(row.nodeId) }
        } else {
            Color.clear.frame(width: DevToolsTheme.discloseWidth, height: 1)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
            // Deliberately *not* selectable text. `textSelection` installs its
            // own gesture, which swallowed every click that landed on the
            // glyphs — so selecting a node only worked if you happened to hit
            // the empty space beside it. No devtools lets you drag-select in
            // the tree; clicking picks the node, and the context menu covers
            // copying.
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
    static let tagColor = DevToolsTheme.adaptive(
        light: (0.51, 0.24, 0.62), dark: (0.78, 0.57, 0.92)
    )
    static let attributeColor = DevToolsTheme.adaptive(
        light: (0.76, 0.42, 0.16), dark: (0.98, 0.76, 0.42)
    )
    static let valueColor = DevToolsTheme.adaptive(
        light: (0.14, 0.43, 0.24), dark: (0.60, 0.85, 0.52)
    )
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

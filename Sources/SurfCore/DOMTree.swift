import Foundation

public typealias DOMNodeID = Int

public enum DOMNodeType: String, Sendable, Equatable {
    case element, text, comment, document, doctype, fragment, shadowRoot
}

public struct DOMAttribute: Sendable, Equatable, Identifiable {
    public var name: String
    public var value: String

    public var id: String { name }

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// One node in the mirror of the page's DOM.
///
/// A *mirror*, not a copy: the panel never holds the page's nodes, only ids and
/// enough description to draw a row. Children are absent until asked for, which
/// is what makes a fifty-thousand-node document openable at all.
public struct DOMNode: Sendable, Equatable, Identifiable {
    public var id: DOMNodeID
    public var parentId: DOMNodeID?
    public var nodeType: DOMNodeType
    /// `div`, `#text`, `#comment`, `#document`.
    public var nodeName: String
    public var attributes: [DOMAttribute]
    /// Known before the children themselves are, so a disclosure triangle can
    /// be drawn without fetching anything.
    public var childCount: Int
    /// Nil means "not requested yet" — distinct from an empty array, which
    /// means "asked, and there are none".
    public var childIds: [DOMNodeID]?
    /// Text and comment contents.
    public var value: String
    /// "grid" or "flex" when the element is that kind of container, else
    /// empty — the tree's layout badges, decided by the agent at serialize
    /// time from computed display.
    public var layout: String

    public init(
        id: DOMNodeID,
        parentId: DOMNodeID? = nil,
        nodeType: DOMNodeType = .element,
        nodeName: String = "div",
        attributes: [DOMAttribute] = [],
        childCount: Int = 0,
        childIds: [DOMNodeID]? = nil,
        value: String = "",
        layout: String = ""
    ) {
        self.id = id
        self.parentId = parentId
        self.nodeType = nodeType
        self.nodeName = nodeName
        self.attributes = attributes
        self.childCount = childCount
        self.childIds = childIds
        self.value = value
        self.layout = layout
    }

    public var isElement: Bool { nodeType == .element }
    public var hasChildren: Bool { childCount > 0 }

    public func attribute(_ name: String) -> String? {
        attributes.first { $0.name == name }?.value
    }

    /// `div#main.row.wide` — how the node reads in a breadcrumb.
    public var displayName: String {
        switch nodeType {
        case .text: "#text"
        case .comment: "#comment"
        case .document: "#document"
        case .doctype: "<!DOCTYPE>"
        case .fragment, .shadowRoot: "#shadow-root"
        case .element:
            {
                var text = nodeName.lowercased()
                if let id = attribute("id"), !id.isEmpty { text += "#\(id)" }
                if let classes = attribute("class") {
                    for name in classes.split(separator: " ") where !name.isEmpty {
                        text += ".\(name)"
                    }
                }
                return text
            }()
        }
    }

    /// An element holding nothing but a short run of text renders on one line,
    /// the way it would in the source. Expanding `<span>Item 3</span>` into
    /// three rows is noise.
    public var isInlineable: Bool {
        guard nodeType == .element, childCount == 1, let childIds else { return false }
        return childIds.count == 1
    }
}

// MARK: - Mutations

public enum DOMMutation: Sendable, Equatable {
    case attributeChanged(id: DOMNodeID, name: String, value: String?)
    case characterDataChanged(id: DOMNodeID, value: String)
    /// The child list changed. Deliberately *not* a list of insertions and
    /// removals: the panel only mirrors the subtrees it has actually fetched,
    /// so the honest response is to forget this node's children and ask again
    /// if it is open. Trying to patch a list you only partly hold is how a
    /// mirror drifts out of sync with the page.
    case childrenChanged(id: DOMNodeID, childCount: Int)
    case nodeRemoved(id: DOMNodeID)
}

// MARK: - Rows

public enum DOMRowKind: Sendable, Equatable {
    /// An open tag whose children follow: `<div>`
    case open
    /// The matching close: `</div>`
    case close
    /// A whole node on one line — a leaf, a collapsed element, or an element
    /// with a single short text child.
    case whole
}

public struct DOMRow: Sendable, Equatable, Identifiable {
    public var nodeId: DOMNodeID
    public var depth: Int
    public var kind: DOMRowKind

    /// Open and close rows share a node id, so the id alone can't identify a
    /// row in a list.
    public var id: String { "\(nodeId).\(kind)" }

    public init(nodeId: DOMNodeID, depth: Int, kind: DOMRowKind) {
        self.nodeId = nodeId
        self.depth = depth
        self.kind = kind
    }
}

// MARK: - Tree

/// The client-side mirror of the page's DOM.
///
/// Every edit is an idempotent patch keyed by node id, so a duplicated or
/// out-of-order batch converges rather than corrupting the tree. That matters
/// because mutation batches are coalesced and acknowledged asynchronously:
/// "applied twice" is a normal thing to survive, not an error to detect.
public struct DOMTree: Sendable, Equatable {

    public private(set) var root: DOMNodeID?
    public private(set) var nodes: [DOMNodeID: DOMNode] = [:]
    public private(set) var expanded: Set<DOMNodeID> = []

    public init() {}

    public var isEmpty: Bool { nodes.isEmpty }

    public subscript(id: DOMNodeID) -> DOMNode? { nodes[id] }

    // MARK: Building

    public mutating func setRoot(_ node: DOMNode) {
        nodes.removeAll()
        expanded.removeAll()
        root = node.id
        nodes[node.id] = node
        // The document's own children are always worth showing: a tree that
        // opens fully collapsed makes you click before you can see anything.
        expanded.insert(node.id)
    }

    /// Records a fetched batch of children.
    public mutating func setChildren(_ children: [DOMNode], of parent: DOMNodeID) {
        guard var node = nodes[parent] else { return }

        // Anything that used to be a child and isn't any more takes its whole
        // subtree with it, or the map grows forever on a page that re-renders.
        let stale = Set(node.childIds ?? []).subtracting(children.map(\.id))
        for id in stale { removeSubtree(id) }

        node.childIds = children.map(\.id)
        node.childCount = children.count
        nodes[parent] = node

        for var child in children {
            child.parentId = parent
            // A child already known keeps whatever we'd fetched beneath it,
            // so re-reading a level doesn't collapse everything under it.
            if let existing = nodes[child.id], existing.childIds != nil {
                child.childIds = existing.childIds
            }
            nodes[child.id] = child
        }
    }

    // MARK: Expansion

    /// Opens or closes a node. Returns the id whose children need fetching, or
    /// nil when they're already in hand.
    @discardableResult
    public mutating func toggleExpansion(_ id: DOMNodeID) -> DOMNodeID? {
        guard let node = nodes[id], node.hasChildren else { return nil }
        if expanded.contains(id) {
            expanded.remove(id)
            return nil
        }
        expanded.insert(id)
        return node.childIds == nil ? id : nil
    }

    public mutating func expand(_ id: DOMNodeID) {
        guard let node = nodes[id], node.hasChildren else { return }
        expanded.insert(id)
    }

    public mutating func collapse(_ id: DOMNodeID) {
        expanded.remove(id)
    }

    public func isExpanded(_ id: DOMNodeID) -> Bool { expanded.contains(id) }

    /// Opens everything between the root and a node, so selecting something
    /// deep — from the picker, or from a console log — reveals it.
    /// Returns the ids whose children still need fetching.
    @discardableResult
    public mutating func reveal(_ id: DOMNodeID) -> [DOMNodeID] {
        var missing: [DOMNodeID] = []
        for ancestor in ancestors(of: id) {
            expanded.insert(ancestor)
            if nodes[ancestor]?.childIds == nil { missing.append(ancestor) }
        }
        return missing
    }

    // MARK: Mutations

    public mutating func apply(_ mutations: [DOMMutation]) {
        for mutation in mutations { apply(mutation) }
    }

    public mutating func apply(_ mutation: DOMMutation) {
        switch mutation {
        case .attributeChanged(let id, let name, let value):
            // A mutation naming a node we never fetched is not an error: the
            // page is bigger than the mirror. Dropping it is correct.
            guard var node = nodes[id] else { return }
            if let value {
                if let index = node.attributes.firstIndex(where: { $0.name == name }) {
                    node.attributes[index].value = value
                } else {
                    node.attributes.append(DOMAttribute(name: name, value: value))
                }
            } else {
                node.attributes.removeAll { $0.name == name }
            }
            nodes[id] = node

        case .characterDataChanged(let id, let value):
            guard var node = nodes[id] else { return }
            node.value = value
            nodes[id] = node

        case .childrenChanged(let id, let childCount):
            guard var node = nodes[id] else { return }
            node.childCount = childCount
            // Forgotten rather than patched — see `DOMMutation.childrenChanged`.
            for child in node.childIds ?? [] { removeSubtree(child) }
            node.childIds = nil
            nodes[id] = node

        case .nodeRemoved(let id):
            guard let node = nodes[id] else { return }
            if var parent = node.parentId.flatMap({ nodes[$0] }) {
                parent.childIds?.removeAll { $0 == id }
                parent.childCount = max(0, parent.childCount - 1)
                nodes[parent.id] = parent
            }
            removeSubtree(id)
        }
    }

    /// Which nodes still need fetching for the tree to draw what's open.
    public func pendingFetches() -> [DOMNodeID] {
        expanded.filter { nodes[$0]?.childIds == nil && nodes[$0]?.hasChildren == true }
    }

    private mutating func removeSubtree(_ id: DOMNodeID) {
        guard let node = nodes[id] else { return }
        for child in node.childIds ?? [] { removeSubtree(child) }
        nodes.removeValue(forKey: id)
        expanded.remove(id)
    }

    // MARK: Reading

    /// The rows a collapsed tree actually shows, flattened for a list.
    public func visibleRows() -> [DOMRow] {
        guard let root else { return [] }
        var rows: [DOMRow] = []
        appendRows(for: root, depth: 0, into: &rows)
        return rows
    }

    private func appendRows(for id: DOMNodeID, depth: Int, into rows: inout [DOMRow]) {
        guard let node = nodes[id] else { return }

        // Nothing inside, or closed, or inlineable: one row.
        guard node.hasChildren, expanded.contains(id), let childIds = node.childIds else {
            rows.append(DOMRow(nodeId: id, depth: depth, kind: .whole))
            return
        }
        if isInlineText(node) {
            rows.append(DOMRow(nodeId: id, depth: depth, kind: .whole))
            return
        }

        rows.append(DOMRow(nodeId: id, depth: depth, kind: .open))
        for child in childIds {
            appendRows(for: child, depth: depth + 1, into: &rows)
        }
        rows.append(DOMRow(nodeId: id, depth: depth, kind: .close))
    }

    /// `<span>Item 3</span>` stays on one line. Three rows for six characters
    /// of text is how a tree becomes unreadable.
    public func isInlineText(_ node: DOMNode) -> Bool {
        guard node.nodeType == .element, node.childCount == 1,
              let childIds = node.childIds, childIds.count == 1,
              let child = nodes[childIds[0]], child.nodeType == .text
        else { return false }
        return child.value.count <= 80
    }

    /// Root first, excluding the node itself.
    public func ancestors(of id: DOMNodeID) -> [DOMNodeID] {
        var chain: [DOMNodeID] = []
        var cursor = nodes[id]?.parentId
        var guardCount = 0
        while let current = cursor, guardCount < 1000 {
            chain.append(current)
            cursor = nodes[current]?.parentId
            guardCount += 1
        }
        return chain.reversed()
    }

    /// A selector that would find this node again — for "Copy selector", and
    /// for saying where you are without a hundred-level breadcrumb.
    public func selectorPath(to id: DOMNodeID) -> String {
        var parts: [String] = []
        var cursor: DOMNodeID? = id
        var guardCount = 0

        while let current = cursor, let node = nodes[current], guardCount < 1000 {
            guardCount += 1
            guard node.nodeType == .element else {
                cursor = node.parentId
                continue
            }
            // An id is unique in a valid document, so the path can stop there.
            if let identifier = node.attribute("id"), !identifier.isEmpty,
               !identifier.contains(" ") {
                parts.append("#\(identifier)")
                break
            }
            parts.append(segment(for: node))
            cursor = node.parentId
        }
        return parts.reversed().joined(separator: " > ")
    }

    private func segment(for node: DOMNode) -> String {
        let tag = node.nodeName.lowercased()
        guard let parentId = node.parentId, let parent = nodes[parentId],
              let siblings = parent.childIds
        else { return tag }

        let sameTag = siblings.compactMap { nodes[$0] }
            .filter { $0.nodeType == .element && $0.nodeName == node.nodeName }
        // Only disambiguate when it's actually ambiguous.
        guard sameTag.count > 1,
              let index = sameTag.firstIndex(where: { $0.id == node.id })
        else { return tag }
        return "\(tag):nth-of-type(\(index + 1))"
    }
}

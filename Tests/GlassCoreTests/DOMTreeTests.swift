import Testing

@testable import GlassCore

@Suite("DOM tree")
struct DOMTreeTests {

    /// A small document: body > (h1, div > span > #text)
    private func sample() -> DOMTree {
        var tree = DOMTree()
        tree.setRoot(DOMNode(id: 1, nodeType: .element, nodeName: "body", childCount: 2))
        tree.setChildren([
            DOMNode(id: 2, nodeName: "h1", childCount: 0),
            DOMNode(id: 3, nodeName: "div", childCount: 1),
        ], of: 1)
        return tree
    }

    @Test("A fetched level replaces the placeholder count with real children")
    func setChildren() {
        let tree = sample()
        #expect(tree[1]?.childIds == [2, 3])
        #expect(tree[2]?.parentId == 1)
    }

    /// The document opens expanded; a tree that starts fully closed makes you
    /// click before you can see anything at all.
    @Test("The root starts expanded")
    func rootExpanded() {
        #expect(sample().isExpanded(1))
    }

    @Test("Collapsed children are absent from the rows")
    func collapsedRows() {
        var tree = sample()
        tree.collapse(1)
        let rows = tree.visibleRows()
        #expect(rows.count == 1)
        #expect(rows[0].kind == .whole)
    }

    @Test("An expanded element gets an open row, its children, and a close row")
    func expandedRows() {
        let rows = sample().visibleRows()
        #expect(rows.map(\.kind) == [.open, .whole, .whole, .close])
        #expect(rows.map(\.depth) == [0, 1, 1, 0])
        #expect(rows.first?.nodeId == 1)
        #expect(rows.last?.nodeId == 1)
    }

    /// An open and a close row share a node id, so the id alone can't identify
    /// a row — a list keyed on it would render one and drop the other.
    @Test("Open and close rows have distinct identities")
    func rowIdentity() {
        let rows = sample().visibleRows()
        #expect(rows.first?.id != rows.last?.id)
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test("Expanding a node with unfetched children asks for them")
    func expansionRequestsChildren() {
        var tree = sample()
        #expect(tree.toggleExpansion(3) == 3)
        // Asked once; the second open needs no fetch.
        tree.setChildren([DOMNode(id: 4, nodeName: "span", childCount: 1)], of: 3)
        tree.collapse(3)
        #expect(tree.toggleExpansion(3) == nil)
    }

    @Test("A node with no children cannot be expanded")
    func leafDoesNotExpand() {
        var tree = sample()
        #expect(tree.toggleExpansion(2) == nil)
        #expect(!tree.isExpanded(2))
    }

    /// `<span>Item 3</span>` on three rows is how a tree becomes unreadable.
    @Test("An element wrapping one short text node stays on a single row")
    func inlineText() {
        var tree = sample()
        tree.setChildren([DOMNode(id: 4, nodeName: "span", childCount: 1)], of: 3)
        tree.setChildren([DOMNode(id: 5, nodeType: .text, nodeName: "#text", value: "Item 3")], of: 4)
        tree.expand(3)
        tree.expand(4)

        let spanRows = tree.visibleRows().filter { $0.nodeId == 4 }
        #expect(spanRows.count == 1)
        #expect(spanRows.first?.kind == .whole)
    }

    /// Long text is not inlined — it would run off the row and hide the tree.
    @Test("A long text child is not inlined")
    func longTextIsNotInlined() {
        var tree = sample()
        tree.setChildren([DOMNode(id: 4, nodeName: "p", childCount: 1)], of: 3)
        tree.setChildren([
            DOMNode(id: 5, nodeType: .text, nodeName: "#text",
                    value: String(repeating: "x", count: 200))
        ], of: 4)
        tree.expand(3)
        tree.expand(4)
        #expect(tree.visibleRows().filter { $0.nodeId == 4 }.count == 2)
    }

    // MARK: Mutations

    @Test("An attribute change lands on the node")
    func attributeChange() {
        var tree = sample()
        tree.apply(.attributeChanged(id: 2, name: "class", value: "title"))
        #expect(tree[2]?.attribute("class") == "title")

        tree.apply(.attributeChanged(id: 2, name: "class", value: nil))
        #expect(tree[2]?.attribute("class") == nil)
    }

    /// The page is bigger than the mirror: a mutation about a node that was
    /// never fetched is normal, not an error to crash on.
    @Test("A mutation naming an unknown node is dropped, not fatal")
    func unknownNodeMutation() {
        var tree = sample()
        let before = tree
        tree.apply(.attributeChanged(id: 999, name: "class", value: "x"))
        tree.apply(.characterDataChanged(id: 999, value: "x"))
        tree.apply(.nodeRemoved(id: 999))
        #expect(tree == before)
    }

    /// Batches are coalesced and acknowledged asynchronously, so "applied
    /// twice" is a normal thing to survive rather than an error to detect.
    @Test("Applying the same batch twice equals applying it once")
    func idempotent() {
        var once = sample()
        var twice = sample()
        let batch: [DOMMutation] = [
            .attributeChanged(id: 2, name: "class", value: "title"),
            .characterDataChanged(id: 2, value: "hello"),
            .nodeRemoved(id: 2),
        ]
        once.apply(batch)
        twice.apply(batch)
        twice.apply(batch)
        #expect(once == twice)
    }

    /// Without this the node map grows forever on a page that re-renders.
    @Test("Removing a node evicts its whole subtree")
    func removalEvictsSubtree() {
        var tree = sample()
        tree.setChildren([DOMNode(id: 4, nodeName: "span", childCount: 1)], of: 3)
        tree.setChildren([DOMNode(id: 5, nodeType: .text, value: "hi")], of: 4)
        #expect(tree.nodes.count == 5)

        tree.apply(.nodeRemoved(id: 3))
        #expect(tree[3] == nil)
        #expect(tree[4] == nil)
        #expect(tree[5] == nil)
        #expect(tree[1]?.childCount == 1)
    }

    @Test("A changed child list is forgotten rather than half-patched")
    func childrenChangedRefetches() {
        var tree = sample()
        tree.setChildren([DOMNode(id: 4, nodeName: "span")], of: 3)
        tree.expand(3)

        tree.apply(.childrenChanged(id: 3, childCount: 7))
        #expect(tree[3]?.childIds == nil)
        #expect(tree[3]?.childCount == 7)
        #expect(tree[4] == nil)
        // Still open, so the tree knows it owes a fetch.
        #expect(tree.pendingFetches().contains(3))
    }

    /// Re-reading a level must not collapse everything already open beneath it.
    @Test("Refetching a level keeps grandchildren already in hand")
    func refetchKeepsDescendants() {
        var tree = sample()
        tree.setChildren([DOMNode(id: 4, nodeName: "span", childCount: 1)], of: 3)
        tree.setChildren([DOMNode(id: 5, nodeType: .text, value: "hi")], of: 4)

        tree.setChildren([DOMNode(id: 4, nodeName: "span", childCount: 1)], of: 3)
        #expect(tree[5] != nil)
        #expect(tree[4]?.childIds == [5])
    }

    @Test("Children dropped by a refetch take their subtrees with them")
    func refetchEvictsRemoved() {
        var tree = sample()
        tree.setChildren([DOMNode(id: 4, nodeName: "span", childCount: 1)], of: 3)
        tree.setChildren([DOMNode(id: 5, nodeType: .text, value: "hi")], of: 4)

        tree.setChildren([DOMNode(id: 6, nodeName: "em")], of: 3)
        #expect(tree[4] == nil)
        #expect(tree[5] == nil)
        #expect(tree[6] != nil)
    }

    // MARK: Paths

    @Test("Ancestors run root-first and exclude the node itself")
    func ancestors() {
        var tree = sample()
        tree.setChildren([DOMNode(id: 4, nodeName: "span")], of: 3)
        #expect(tree.ancestors(of: 4) == [1, 3])
        #expect(tree.ancestors(of: 1).isEmpty)
    }

    @Test("Revealing a node opens every ancestor")
    func reveal() {
        var tree = sample()
        tree.setChildren([DOMNode(id: 4, nodeName: "span")], of: 3)
        tree.collapse(1)
        tree.reveal(4)
        #expect(tree.isExpanded(1))
        #expect(tree.isExpanded(3))
    }

    /// An id is unique in a valid document, so the path can stop there rather
    /// than reciting the whole chain.
    @Test("A selector stops at the nearest id")
    func selectorStopsAtID() {
        var tree = DOMTree()
        tree.setRoot(DOMNode(id: 1, nodeName: "body", childCount: 1))
        tree.setChildren([
            DOMNode(id: 2, nodeName: "div",
                    attributes: [DOMAttribute(name: "id", value: "main")], childCount: 1)
        ], of: 1)
        tree.setChildren([DOMNode(id: 3, nodeName: "span")], of: 2)

        #expect(tree.selectorPath(to: 3) == "#main > span")
    }

    /// Only disambiguate when it is actually ambiguous — `body > div > span`
    /// reads better than the same path littered with `:nth-of-type(1)`.
    @Test("A selector adds nth-of-type only for repeated siblings")
    func selectorDisambiguates() {
        var tree = DOMTree()
        tree.setRoot(DOMNode(id: 1, nodeName: "body", childCount: 3))
        tree.setChildren([
            DOMNode(id: 2, nodeName: "p"),
            DOMNode(id: 3, nodeName: "p"),
            DOMNode(id: 4, nodeName: "span"),
        ], of: 1)

        #expect(tree.selectorPath(to: 3) == "body > p:nth-of-type(2)")
        #expect(tree.selectorPath(to: 4) == "body > span")
    }

    @Test("A node's display name carries its id and classes")
    func displayName() {
        let node = DOMNode(
            id: 1, nodeName: "DIV",
            attributes: [
                DOMAttribute(name: "id", value: "main"),
                DOMAttribute(name: "class", value: "row wide"),
            ]
        )
        #expect(node.displayName == "div#main.row.wide")
    }

    /// A malformed tree that pointed at itself would otherwise hang the panel.
    @Test("A cycle in parent links terminates instead of hanging")
    func cyclesTerminate() {
        var tree = DOMTree()
        tree.setRoot(DOMNode(id: 1, parentId: 2, nodeName: "a"))
        tree.setChildren([DOMNode(id: 2, parentId: 1, nodeName: "b")], of: 1)
        let chain = tree.ancestors(of: 2)
        #expect(chain.count < 1002)
        _ = tree.selectorPath(to: 2)
    }
}

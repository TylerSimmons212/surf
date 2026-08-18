import Testing
@testable import SurfCore

@Suite("Tab selection")
struct TabSelectionTests {

    // MARK: - Closing

    @Test("Closing a middle tab selects the one that slides into its place")
    func closingMiddle() {
        // [A B C], close B (index 1) -> [A C], C is now at index 1.
        #expect(TabSelection.indexAfterClosing(closedIndex: 1, originalCount: 3) == 1)
    }

    @Test("Closing the last tab falls back to the new last tab")
    func closingLast() {
        // [A B C], close C (index 2) -> [A B], clamp to index 1.
        #expect(TabSelection.indexAfterClosing(closedIndex: 2, originalCount: 3) == 1)
    }

    @Test("Closing the first tab selects the new first tab")
    func closingFirst() {
        #expect(TabSelection.indexAfterClosing(closedIndex: 0, originalCount: 3) == 0)
    }

    @Test("Closing the only tab leaves nothing selected")
    func closingOnly() {
        #expect(TabSelection.indexAfterClosing(closedIndex: 0, originalCount: 1) == nil)
    }

    @Test("Closing down to one tab selects it")
    func closingToOne() {
        #expect(TabSelection.indexAfterClosing(closedIndex: 1, originalCount: 2) == 0)
        #expect(TabSelection.indexAfterClosing(closedIndex: 0, originalCount: 2) == 0)
    }

    // MARK: - Cycling

    @Test("Next wraps past the end", arguments: [
        (0, 1, 3, 1), (1, 1, 3, 2), (2, 1, 3, 0),
    ])
    func cycleForward(_ from: Int, _ offset: Int, _ count: Int, _ expected: Int) {
        #expect(TabSelection.cycled(from: from, by: offset, count: count) == expected)
    }

    @Test("Previous wraps past the start", arguments: [
        (2, -1, 3, 1), (1, -1, 3, 0), (0, -1, 3, 2),
    ])
    func cycleBackward(_ from: Int, _ offset: Int, _ count: Int, _ expected: Int) {
        #expect(TabSelection.cycled(from: from, by: offset, count: count) == expected)
    }

    @Test("Cycling a single tab stays put")
    func cycleSingle() {
        #expect(TabSelection.cycled(from: 0, by: 1, count: 1) == 0)
        #expect(TabSelection.cycled(from: 0, by: -1, count: 1) == 0)
    }

    @Test("Cycling an empty list yields nothing")
    func cycleEmpty() {
        #expect(TabSelection.cycled(from: 0, by: 1, count: 0) == nil)
    }

    // MARK: - Direct selection

    @Test("Command-number selects by position")
    func directSelection() {
        #expect(TabSelection.index(forOneBased: 1, count: 5) == 0)
        #expect(TabSelection.index(forOneBased: 3, count: 5) == 2)
    }

    @Test("Command-9 means last tab, not the ninth")
    func nineIsLast() {
        #expect(TabSelection.index(forOneBased: 9, count: 3) == 2)
        #expect(TabSelection.index(forOneBased: 9, count: 12) == 11)
    }

    @Test("Selecting past the end of the list does nothing")
    func outOfRange() {
        #expect(TabSelection.index(forOneBased: 5, count: 3) == nil)
        #expect(TabSelection.index(forOneBased: 1, count: 0) == nil)
    }
}

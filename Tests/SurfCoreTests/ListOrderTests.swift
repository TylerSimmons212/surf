import Foundation
import Testing
@testable import SurfCore

@Suite("List order")
struct ListOrderTests {

    private let list = ["a", "b", "c", "d", "e"]

    // MARK: - Moving a group

    @Test("A group lands where the target was, in its own order")
    func movesGroupBeforeTarget() {
        #expect(ListOrder.moving(["c", "d"], before: "a", in: list) == ["c", "d", "a", "b", "e"])
    }

    /// The case plain index arithmetic gets wrong: removing the group first
    /// shifts the target's index, so a naive implementation inserts one slot
    /// late whenever the group starts before the target.
    @Test("Moving a group forwards accounts for the hole it leaves")
    func movesGroupForwards() {
        #expect(ListOrder.moving(["a", "b"], before: "d", in: list) == ["c", "a", "b", "d", "e"])
    }

    @Test("A group moved to the end keeps its own order")
    func movesGroupToEnd() {
        #expect(ListOrder.movingToEnd(["a", "b"], in: list) == ["c", "d", "e", "a", "b"])
    }

    @Test("A group already at the end doesn't count as moved")
    func refusesNoOpToEnd() {
        #expect(ListOrder.movingToEnd(["d", "e"], in: list) == nil)
    }

    /// Dragging a group onto itself is the ordinary end of a drag — the slot
    /// under the pointer is the group's own — and must not report a move.
    @Test("Dropping a group on itself is refused")
    func refusesTargetInsideGroup() {
        #expect(ListOrder.moving(["a", "b"], before: "b", in: list) == nil)
        #expect(ListOrder.moving(["a", "b"], before: "a", in: list) == nil)
    }

    @Test("Moving a group where it already is is refused")
    func refusesNoOpMove() {
        #expect(ListOrder.moving(["a", "b"], before: "c", in: list) == nil)
    }

    @Test("Unknown ids are refused rather than partly applied")
    func refusesUnknownIDs() {
        #expect(ListOrder.moving(["a", "z"], before: "c", in: list) == nil)
        #expect(ListOrder.moving(["a"], before: "z", in: list) == nil)
        #expect(ListOrder.movingToEnd(["z"], in: list) == nil)
    }

    @Test("A group given twice is refused")
    func refusesDuplicateGroup() {
        #expect(ListOrder.moving(["a", "a"], before: "c", in: list) == nil)
    }

    @Test("Every id survives a move")
    func preservesMembership() {
        let moved = ListOrder.moving(["b", "c"], before: "e", in: list)
        #expect(moved.map(Set.init) == Set(list))
        #expect(moved?.count == list.count)
    }

    // MARK: - Keeping a pair together

    @Test("A tab can be pulled up to sit right after its partner")
    func placesAfterAnchor() {
        #expect(ListOrder.placing("e", immediatelyAfter: "a", in: list) == ["a", "e", "b", "c", "d"])
    }

    @Test("Placing after an anchor that follows it closes the gap")
    func placesBackwards() {
        #expect(ListOrder.placing("a", immediatelyAfter: "d", in: list) == ["b", "c", "d", "a", "e"])
    }

    @Test("A tab already directly after its anchor is left alone")
    func refusesNoOpPlacement() {
        #expect(ListOrder.placing("b", immediatelyAfter: "a", in: list) == nil)
    }

    @Test("Placing a tab after itself is refused")
    func refusesSelfPlacement() {
        #expect(ListOrder.placing("a", immediatelyAfter: "a", in: list) == nil)
    }

    // MARK: - Back to items

    @Test("Resequencing puts the items into the order the ids give")
    func resequencing() {
        let a = Thing(id: "a"), b = Thing(id: "b"), c = Thing(id: "c")
        #expect(ListOrder.resequencing([a, b, c], into: ["c", "a", "b"]) == [c, a, b])
    }

    @Test("An id naming nothing is skipped, not fatal")
    func resequencingSurvivesAGap() {
        // A reorder and a removal can land in either sequence. A shelf that
        // crashed because a sticker was peeled mid-drag would be the worse
        // answer.
        let a = Thing(id: "a"), b = Thing(id: "b")
        #expect(ListOrder.resequencing([a, b], into: ["a", "gone", "b"]) == [a, b])
    }

    @Test("An item the order never mentions is dropped")
    func resequencingDropsTheUnmentioned() {
        let a = Thing(id: "a"), b = Thing(id: "b")
        #expect(ListOrder.resequencing([a, b], into: ["b"]) == [b])
    }
}

private struct Thing: Identifiable, Equatable {
    let id: String
}

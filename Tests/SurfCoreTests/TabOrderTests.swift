import Foundation
import Testing
@testable import SurfCore

@Suite("Tab order")
struct TabOrderTests {

    private let list = ["a", "b", "c", "d", "e"]

    // MARK: - Moving a group

    @Test("A group lands where the target was, in its own order")
    func movesGroupBeforeTarget() {
        #expect(TabOrder.moving(["c", "d"], before: "a", in: list) == ["c", "d", "a", "b", "e"])
    }

    /// The case plain index arithmetic gets wrong: removing the group first
    /// shifts the target's index, so a naive implementation inserts one slot
    /// late whenever the group starts before the target.
    @Test("Moving a group forwards accounts for the hole it leaves")
    func movesGroupForwards() {
        #expect(TabOrder.moving(["a", "b"], before: "d", in: list) == ["c", "a", "b", "d", "e"])
    }

    @Test("A group moved to the end keeps its own order")
    func movesGroupToEnd() {
        #expect(TabOrder.movingToEnd(["a", "b"], in: list) == ["c", "d", "e", "a", "b"])
    }

    @Test("A group already at the end doesn't count as moved")
    func refusesNoOpToEnd() {
        #expect(TabOrder.movingToEnd(["d", "e"], in: list) == nil)
    }

    /// Dragging a group onto itself is the ordinary end of a drag — the slot
    /// under the pointer is the group's own — and must not report a move.
    @Test("Dropping a group on itself is refused")
    func refusesTargetInsideGroup() {
        #expect(TabOrder.moving(["a", "b"], before: "b", in: list) == nil)
        #expect(TabOrder.moving(["a", "b"], before: "a", in: list) == nil)
    }

    @Test("Moving a group where it already is is refused")
    func refusesNoOpMove() {
        #expect(TabOrder.moving(["a", "b"], before: "c", in: list) == nil)
    }

    @Test("Unknown ids are refused rather than partly applied")
    func refusesUnknownIDs() {
        #expect(TabOrder.moving(["a", "z"], before: "c", in: list) == nil)
        #expect(TabOrder.moving(["a"], before: "z", in: list) == nil)
        #expect(TabOrder.movingToEnd(["z"], in: list) == nil)
    }

    @Test("A group given twice is refused")
    func refusesDuplicateGroup() {
        #expect(TabOrder.moving(["a", "a"], before: "c", in: list) == nil)
    }

    @Test("Every id survives a move")
    func preservesMembership() {
        let moved = TabOrder.moving(["b", "c"], before: "e", in: list)
        #expect(moved.map(Set.init) == Set(list))
        #expect(moved?.count == list.count)
    }

    // MARK: - Keeping a pair together

    @Test("A tab can be pulled up to sit right after its partner")
    func placesAfterAnchor() {
        #expect(TabOrder.placing("e", immediatelyAfter: "a", in: list) == ["a", "e", "b", "c", "d"])
    }

    @Test("Placing after an anchor that follows it closes the gap")
    func placesBackwards() {
        #expect(TabOrder.placing("a", immediatelyAfter: "d", in: list) == ["b", "c", "d", "a", "e"])
    }

    @Test("A tab already directly after its anchor is left alone")
    func refusesNoOpPlacement() {
        #expect(TabOrder.placing("b", immediatelyAfter: "a", in: list) == nil)
    }

    @Test("Placing a tab after itself is refused")
    func refusesSelfPlacement() {
        #expect(TabOrder.placing("a", immediatelyAfter: "a", in: list) == nil)
    }
}
